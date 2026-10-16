-- =========================================================
-- PARTE A — Tiempos reales de mesa (como los sistemas profesionales)
-- Cómo usarlo: SQL Editor > New query > pegar todo > Run
-- (correr DESPUÉS de sql-1, sql-2, sql-3 y sql-4)
--
--  1. Duración de la mesa según el tamaño del grupo ("turn time")
--  2. Tiempo de limpieza entre reservas (buffer)
--  3. Horario de apertura y cierre: la cena debe terminar antes del cierre
--  4. Turnos cada 15 minutos
--  5. Ritmo de cocina: máximo de personas que empiezan en el mismo turno
--  6. Estado "sentada", liberar mesa antes y extender tiempo
--  7. Los correos dicen hasta qué hora es la mesa
-- =========================================================

-- ---------------------------------------------------------
-- 1 a 5. AJUSTES (editables por el admin desde el panel)
-- ---------------------------------------------------------
create table if not exists public.ajustes_reserva (
  id                     int  primary key default 1 check (id = 1),   -- una sola fila
  apertura               time not null default '19:00',
  cierre                 time not null default '00:00',               -- 00:00 = medianoche
  intervalo_min          int  not null default 15 check (intervalo_min in (10, 15, 20, 30)),
  limpieza_min           int  not null default 15 check (limpieza_min between 0 and 60),
  max_personas_por_turno int  not null default 12 check (max_personas_por_turno > 0)
);
insert into public.ajustes_reserva (id) values (1) on conflict (id) do nothing;

create table if not exists public.duracion_por_grupo (
  hasta_personas int primary key check (hasta_personas > 0),   -- grupos de hasta N personas
  minutos        int not null check (minutos between 30 and 300)
);
insert into public.duracion_por_grupo (hasta_personas, minutos) values
  (2, 90), (4, 120), (6, 150), (99, 180)
on conflict (hasta_personas) do nothing;

alter table public.ajustes_reserva    enable row level security;
alter table public.duracion_por_grupo enable row level security;

drop policy if exists "todos leen ajustes" on public.ajustes_reserva;
create policy "todos leen ajustes" on public.ajustes_reserva for select to authenticated using (true);
drop policy if exists "admin edita ajustes" on public.ajustes_reserva;
create policy "admin edita ajustes" on public.ajustes_reserva for update to authenticated
  using (public.es_admin()) with check (public.es_admin());

drop policy if exists "todos leen duraciones" on public.duracion_por_grupo;
create policy "todos leen duraciones" on public.duracion_por_grupo for select to authenticated using (true);
drop policy if exists "admin gestiona duraciones" on public.duracion_por_grupo;
create policy "admin gestiona duraciones" on public.duracion_por_grupo for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- Minutos de mesa para un grupo
create or replace function public.duracion_para(p_personas int)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(
    (select minutos from public.duracion_por_grupo
      where hasta_personas >= p_personas order by hasta_personas limit 1),
    (select max(minutos) from public.duracion_por_grupo),
    120);
$$;

-- Momento de cierre para una fecha (si cierra a las 00:00, es el día siguiente)
create or replace function public.cierre_de(p_fecha date)
returns timestamp language sql stable security definer set search_path = public as $$
  select p_fecha + a.cierre + case when a.cierre <= a.apertura then interval '1 day' else interval '0' end
    from public.ajustes_reserva a where a.id = 1;
$$;

-- ---------------------------------------------------------
-- 6. RESERVA: duración propia, limpieza y estado "sentada"
-- ---------------------------------------------------------
-- Las reservas que ya existían quedan con 2 h y sin limpieza (como antes)
alter table public.reserva add column if not exists duracion_min int;
alter table public.reserva add column if not exists limpieza_min int;
update public.reserva set duracion_min = 120 where duracion_min is null;
update public.reserva set limpieza_min = 0   where limpieza_min is null;
alter table public.reserva alter column duracion_min set not null;
alter table public.reserva alter column limpieza_min set not null;
alter table public.reserva drop constraint if exists reserva_duracion_ok;
alter table public.reserva add constraint reserva_duracion_ok check (duracion_min between 30 and 360);

alter table public.reserva drop constraint if exists reserva_estado_check;
alter table public.reserva add constraint reserva_estado_check
  check (estado in ('confirmada', 'sentada', 'completada', 'cancelada', 'no_asistio'));

-- La franja ahora usa la duración de cada reserva + la limpieza.
-- Solo bloquean la mesa las reservas que están por venir o sentadas:
-- si el admin libera la mesa (completada) o no vinieron, la mesa queda libre.
alter table public.reserva drop constraint if exists sin_superposicion;
alter table public.reserva drop column if exists franja;
alter table public.reserva add column franja tsrange generated always as (
  tsrange(fecha + hora, fecha + hora + (duracion_min + limpieza_min) * interval '1 minute')
) stored;
alter table public.reserva add constraint sin_superposicion
  exclude using gist (id_mesa with =, franja with &&)
  where (estado in ('confirmada', 'sentada'));

-- Antes de guardar: completa la duración y valida la mesa
create or replace function public.validar_capacidad()
returns trigger language plpgsql as $$
declare m public.mesa;
begin
  if new.duracion_min is null
     or (tg_op = 'UPDATE' and new.cantidad_personas <> old.cantidad_personas
         and new.duracion_min = old.duracion_min) then
    new.duracion_min := public.duracion_para(new.cantidad_personas);
  end if;
  if new.limpieza_min is null then
    new.limpieza_min := (select limpieza_min from public.ajustes_reserva where id = 1);
  end if;

  if new.estado not in ('confirmada', 'sentada') then
    return new;   -- cancelar, liberar o marcar no asistió siempre se puede
  end if;
  select * into m from public.mesa where id_mesa = new.id_mesa;
  if m.estado <> 'activa' then
    raise exception 'La mesa % no está activa', m.numero;
  end if;
  if new.cantidad_personas > m.capacidad then
    raise exception 'La mesa % es para % personas como máximo', m.numero, m.capacidad;
  end if;
  return new;
end; $$;

-- ---------------------------------------------------------
-- DISPONIBILIDAD
-- ---------------------------------------------------------
-- ¿Se puede empezar una reserva a esa hora? (horario, cierre y ritmo de cocina)
-- Devuelve el motivo si NO se puede, o null si está bien.
create or replace function public.motivo_turno(p_fecha date, p_hora time, p_personas int)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  a        public.ajustes_reserva;
  v_inicio timestamp := p_fecha + p_hora;
  v_dur    int := public.duracion_para(p_personas);
  v_apert  timestamp;
  v_cierre timestamp;
  v_turno  timestamp;
  v_en_turno int;
begin
  select * into a from public.ajustes_reserva where id = 1;
  v_apert  := p_fecha + a.apertura;
  v_cierre := public.cierre_de(p_fecha);

  if v_inicio < v_apert or v_inicio >= v_cierre then
    return format('Atendemos de %s a %s.', to_char(a.apertura, 'HH24:MI'), to_char(a.cierre, 'HH24:MI'));
  end if;
  if (extract(minute from p_hora)::int % a.intervalo_min) <> 0 then
    return format('Las reservas son cada %s minutos.', a.intervalo_min);
  end if;
  if v_inicio + v_dur * interval '1 minute' > v_cierre then
    return format('Para %s personas la última reserva es a las %s (la mesa es por %s y cerramos a las %s).',
                  p_personas,
                  to_char(v_cierre - v_dur * interval '1 minute', 'HH24:MI'),
                  public.texto_duracion(v_dur),
                  to_char(a.cierre, 'HH24:MI'));
  end if;

  -- Ritmo de cocina: personas que empiezan en este mismo turno
  v_turno := p_fecha + a.apertura
             + floor(extract(epoch from (v_inicio - v_apert)) / 60 / a.intervalo_min)
               * a.intervalo_min * interval '1 minute';
  select coalesce(sum(cantidad_personas), 0) into v_en_turno
    from public.reserva
   where estado in ('confirmada', 'sentada', 'completada')
     and (fecha + hora) >= v_turno
     and (fecha + hora) <  v_turno + a.intervalo_min * interval '1 minute';
  if v_en_turno + p_personas > a.max_personas_por_turno then
    return 'A esa hora la cocina ya tiene muchas mesas empezando. Probá 15 minutos antes o después.';
  end if;

  return null;
end; $$;

-- "1 h 30 min", "2 h"
create or replace function public.texto_duracion(p_min int)
returns text language sql immutable as $$
  select case
    when p_min < 60 then p_min || ' min'
    when p_min % 60 = 0 then (p_min / 60) || ' h'
    else (p_min / 60) || ' h ' || (p_min % 60) || ' min'
  end;
$$;

-- Mesas libres para esa hora, considerando la duración del grupo + limpieza
create or replace function public.mesas_disponibles(p_fecha date, p_hora time, p_personas int)
returns setof public.mesa language sql stable security definer set search_path = public as $$
  select m.*
  from public.mesa m
  where m.estado = 'activa'
    and m.capacidad >= p_personas
    and not exists (
      select 1 from public.reserva r
      where r.id_mesa = m.id_mesa
        and r.estado in ('confirmada', 'sentada')
        and r.franja && tsrange(
              p_fecha + p_hora,
              p_fecha + p_hora + (public.duracion_para(p_personas)
                + (select limpieza_min from public.ajustes_reserva where id = 1)) * interval '1 minute')
    )
  order by m.capacidad, m.numero;
$$;

-- Lo que ve el cliente antes de confirmar
create or replace function public.consultar_turno(p_fecha date, p_hora time, p_personas int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_motivo text;
  v_dur    int := public.duracion_para(p_personas);
  v_hasta  time := p_hora + v_dur * interval '1 minute';
begin
  if (p_fecha + p_hora) < (now() at time zone 'America/Montevideo') then
    return jsonb_build_object('disponible', false, 'motivo', 'Ese horario ya pasó.');
  end if;
  v_motivo := public.motivo_turno(p_fecha, p_hora, p_personas);
  if v_motivo is not null then
    return jsonb_build_object('disponible', false, 'motivo', v_motivo);
  end if;
  if not exists (select 1 from public.mesas_disponibles(p_fecha, p_hora, p_personas)) then
    return jsonb_build_object('disponible', false,
      'motivo', 'No hay mesas libres para ese día, hora y cantidad de personas.');
  end if;
  return jsonb_build_object('disponible', true,
    'duracion_min', v_dur,
    'duracion_texto', public.texto_duracion(v_dur),
    'hasta', to_char(v_hasta, 'HH24:MI'));
end; $$;

-- Crear reserva (cliente): valida todo y asigna la mejor mesa
create or replace function public.crear_reserva(p_fecha date, p_hora time, p_personas int)
returns public.reserva language plpgsql security definer set search_path = public as $$
declare
  v_mesa    bigint;
  v_reserva public.reserva;
  v_activas int;
  v_maximo  int := coalesce(public.config('max_reservas_cliente')::int, 3);
  v_motivo  text;
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión para reservar';
  end if;
  if (p_fecha + p_hora) < (now() at time zone 'America/Montevideo') then
    raise exception 'No se puede reservar en una fecha u hora que ya pasó';
  end if;

  select count(*) into v_activas
    from public.reserva
   where id_usuario = auth.uid()
     and estado = 'confirmada'
     and (fecha + hora) >= (now() at time zone 'America/Montevideo');
  if v_activas >= v_maximo then
    raise exception 'Ya tenés % reservas próximas. Cancelá alguna para hacer otra.', v_maximo;
  end if;

  v_motivo := public.motivo_turno(p_fecha, p_hora, p_personas);
  if v_motivo is not null then
    raise exception '%', v_motivo;
  end if;

  select id_mesa into v_mesa
  from public.mesas_disponibles(p_fecha, p_hora, p_personas)
  limit 1;
  if v_mesa is null then
    raise exception 'No hay mesas disponibles para ese día, hora y cantidad de personas';
  end if;

  insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas)
  values (auth.uid(), v_mesa, p_fecha, p_hora, p_personas)
  returning * into v_reserva;
  return v_reserva;
end; $$;

-- Admin: sumar minutos a una reserva (se quedan más tiempo)
create or replace function public.extender_reserva(p_id_reserva bigint, p_minutos int)
returns public.reserva language plpgsql security definer set search_path = public as $$
declare v public.reserva;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede extender reservas';
  end if;
  update public.reserva
     set duracion_min = duracion_min + p_minutos
   where id_reserva = p_id_reserva
  returning * into v;
  return v;
exception when exclusion_violation then
  raise exception 'No se puede extender: la mesa tiene otra reserva después.';
end; $$;

-- ---------------------------------------------------------
-- 7. CORREOS: incluyen hasta qué hora es la mesa
-- ---------------------------------------------------------
create or replace function public.notificar_reserva()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_tipo      text;
  v_cliente   public.usuario;
  v_mesa      public.mesa;
  v_activas   int;
  v_ocupadas  int;
  v_pct       int;
begin
  if tg_op = 'INSERT' and new.estado = 'confirmada' then
    v_tipo := 'confirmacion';
  elsif tg_op = 'UPDATE' and old.estado in ('confirmada', 'sentada') and new.estado = 'cancelada' then
    v_tipo := case when auth.uid() = new.id_usuario then 'cancelacion_cliente'
                   else 'cancelacion_admin' end;
  elsif tg_op = 'UPDATE' and new.estado = 'confirmada' and old.estado = 'confirmada'
        and (old.fecha, old.hora, old.id_mesa, old.cantidad_personas)
            is distinct from (new.fecha, new.hora, new.id_mesa, new.cantidad_personas) then
    v_tipo := 'modificacion';
  else
    return new;   -- sentada, completada, no asistió o extender: no se manda nada
  end if;

  select * into v_cliente from public.usuario where id_usuario = new.id_usuario;
  select * into v_mesa    from public.mesa    where id_mesa    = new.id_mesa;

  perform public.avisar_n8n(jsonb_build_object(
    'tipo',       v_tipo,
    'id_reserva', new.id_reserva,
    'nombre',     v_cliente.nombre,
    'email',      v_cliente.email,
    'fecha',      to_char(new.fecha, 'DD/MM/YYYY'),
    'hora',       to_char(new.hora, 'HH24:MI'),
    'hasta',      to_char(new.hora + new.duracion_min * interval '1 minute', 'HH24:MI'),
    'personas',   new.cantidad_personas,
    'mesa',       v_mesa.numero
  ));

  if v_tipo in ('confirmacion', 'modificacion') then
    select count(*) into v_activas from public.mesa where estado = 'activa';
    select count(distinct id_mesa) into v_ocupadas
      from public.reserva
     where fecha = new.fecha
       and estado in ('confirmada', 'sentada')
       and franja @> (new.fecha + new.hora);
    v_pct := case when v_activas > 0 then round(v_ocupadas * 100.0 / v_activas) else 0 end;

    if v_pct >= coalesce(public.config('umbral_ocupacion')::int, 80) then
      perform public.avisar_n8n(jsonb_build_object(
        'tipo',       'alerta_ocupacion',
        'email',      public.config('email_admin'),
        'fecha',      to_char(new.fecha, 'DD/MM/YYYY'),
        'hora',       to_char(new.hora, 'HH24:MI'),
        'ocupacion',  v_pct,
        'ocupadas',   v_ocupadas,
        'activas',    v_activas
      ));
    end if;
  end if;
  return new;
end; $$;

create or replace function public.avisar_n8n(p_datos jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_url      text := public.config('n8n_webhook_url');
  d          jsonb := p_datos;
  v_nombre   text := split_part(coalesce(p_datos->>'nombre', ''), ' ', 1);
  v_personas text := (p_datos->>'personas') ||
                     case when p_datos->>'personas' = '1' then ' persona' else ' personas' end;
  v_detalle  text;
  v_asunto   text;
  v_titulo   text;
  v_cuerpo   text;
  v_html     text;
begin
  if v_url is null or v_url = '' then
    return;   -- todavía no hay automatización conectada
  end if;

  v_detalle := format(
    '<table style="margin:18px 0;border-collapse:collapse">'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Día</td><td><b>%s</b></td></tr>'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Horario</td><td><b>%s</b></td></tr>'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Personas</td><td><b>%s</b></td></tr>'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Reserva n.º</td><td><b>%s</b></td></tr>'
    '</table>',
    d->>'fecha', (d->>'hora') || coalesce(' a ' || (d->>'hasta') || ' h', ''), v_personas, d->>'id_reserva');

  case d->>'tipo'
    when 'confirmacion' then
      v_asunto := format('Tu mesa en Marea está confirmada · %s %s', d->>'fecha', d->>'hora');
      v_titulo := format('¡Te esperamos, %s!', v_nombre);
      v_cuerpo := 'Tu reserva quedó confirmada.' || v_detalle ||
                  'Si no podés venir, cancelala desde <b>Mis reservas</b> así liberamos la mesa.';
    when 'modificacion' then
      v_asunto := format('Cambiamos tu reserva en Marea · %s %s', d->>'fecha', d->>'hora');
      v_titulo := format('Hola, %s', v_nombre);
      v_cuerpo := 'El restaurante actualizó tu reserva. Estos son los datos nuevos:' || v_detalle ||
                  'Cualquier duda, respondé este correo.';
    when 'cancelacion_admin' then
      v_asunto := 'Tu reserva en Marea fue cancelada';
      v_titulo := format('Hola, %s', v_nombre);
      v_cuerpo := 'Lamentamos avisarte que el restaurante tuvo que cancelar tu reserva:' || v_detalle ||
                  'Podés elegir otro día u horario desde nuestra web. Disculpá las molestias.';
    when 'cancelacion_cliente' then
      v_asunto := 'Cancelaste tu reserva en Marea';
      v_titulo := format('Hola, %s', v_nombre);
      v_cuerpo := 'Recibimos la cancelación de tu reserva:' || v_detalle || '¡Ojalá te veamos pronto!';
    when 'alerta_ocupacion' then
      v_asunto := format('Alerta: ocupación del %s%% · %s %s', d->>'ocupacion', d->>'fecha', d->>'hora');
      v_titulo := 'Ocupación alta';
      v_cuerpo := format('El <b>%s</b> a las <b>%s</b> hay <b>%s de %s</b> mesas reservadas (<b>%s%%</b>).'
                         '<br><br>Quedan %s mesas libres en ese horario.',
                         d->>'fecha', d->>'hora', d->>'ocupadas', d->>'activas', d->>'ocupacion',
                         (d->>'activas')::int - (d->>'ocupadas')::int);
    else
      return;
  end case;

  v_html := format(
    '<div style="background:#f6efe2;padding:32px 12px;font-family:Arial,sans-serif;color:#1b2733">'
    '<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden">'
    '<div style="background:#0e2a47;color:#fff;padding:22px 28px;font-family:Georgia,serif;font-size:22px;letter-spacing:6px">MAREA</div>'
    '<div style="padding:28px"><h2 style="font-family:Georgia,serif;font-weight:normal;color:#0e2a47;margin:0 0 12px">%s</h2>'
    '<div style="line-height:1.55">%s</div></div>'
    '<div style="padding:16px 28px;background:#f6efe2;color:#6b7785;font-size:12px">Marea · Costa atlántica uruguaya · Cenas de 19 a 00 h</div>'
    '</div></div>', v_titulo, v_cuerpo);

  perform net.http_post(
    url     := v_url,
    body    := d || jsonb_build_object('asunto', v_asunto, 'html', v_html,
                                    'secreto', public.config('webhook_secreto')),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
exception when others then
  raise warning 'No se pudo avisar a la automatización: %', sqlerrm;
end; $$;



revoke execute on function public.avisar_n8n(jsonb) from public, anon, authenticated;
revoke execute on function public.motivo_turno(date, time, int) from public, anon;
