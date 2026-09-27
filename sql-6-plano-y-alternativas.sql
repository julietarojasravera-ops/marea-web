-- =========================================================
-- PARTE A — Plano del local y horarios alternativos
-- Cómo usarlo: SQL Editor > New query > pegar todo > Run
-- (correr DESPUÉS de sql-1 a sql-5)
--
--  1. Cada mesa tiene forma y ubicación en el plano del local
--  2. estado_mesas: cómo está cada mesa para un día, hora y grupo
--  3. El cliente puede elegir la mesa (crear_reserva / consultar_turno)
--  4. horarios_alternativos: si no hay lugar, sugiere horarios cercanos
--     ese día o el próximo día con lugar
-- =========================================================

-- ---------------------------------------------------------
-- 1. FORMA Y UBICACIÓN DE CADA MESA
-- Coordenadas del plano: x de 0 a 100 (izquierda a derecha),
-- y de 0 a 64 (del ventanal al mar hacia la entrada)
-- ---------------------------------------------------------
alter table public.mesa add column if not exists forma text;
alter table public.mesa add column if not exists pos_x numeric(5,1);
alter table public.mesa add column if not exists pos_y numeric(5,1);

alter table public.mesa drop constraint if exists mesa_forma_ok;
alter table public.mesa add constraint mesa_forma_ok
  check (forma is null or forma in ('redonda', 'cuadrada', 'rectangular'));
alter table public.mesa drop constraint if exists mesa_posicion_ok;
alter table public.mesa add constraint mesa_posicion_ok
  check ((pos_x is null or pos_x between 0 and 100) and (pos_y is null or pos_y between 0 and 64));

-- Plano inicial de Marea (el admin lo puede reacomodar arrastrando)
update public.mesa set forma = 'redonda',     pos_x = 14, pos_y = 14 where numero = 1 and pos_x is null;
update public.mesa set forma = 'redonda',     pos_x = 30, pos_y = 14 where numero = 2 and pos_x is null;
update public.mesa set forma = 'cuadrada',    pos_x = 48, pos_y = 14 where numero = 3 and pos_x is null;
update public.mesa set forma = 'cuadrada',    pos_x = 66, pos_y = 14 where numero = 4 and pos_x is null;
update public.mesa set forma = 'cuadrada',    pos_x = 16, pos_y = 36 where numero = 5 and pos_x is null;
update public.mesa set forma = 'rectangular', pos_x = 40, pos_y = 36 where numero = 6 and pos_x is null;
update public.mesa set forma = 'rectangular', pos_x = 56, pos_y = 53 where numero = 7 and pos_x is null;

-- Forma automática para las mesas que no tengan
update public.mesa
   set forma = case when capacidad <= 2 then 'redonda'
                    when capacidad <= 4 then 'cuadrada'
                    else 'rectangular' end
 where forma is null;

-- ---------------------------------------------------------
-- 2. ESTADO DE CADA MESA para un día, hora y grupo
--    libre · ocupada · chica (no entra el grupo) · inactiva
--    No muestra quién reservó: solo si la mesa está libre.
-- ---------------------------------------------------------
create or replace function public.estado_mesas(p_fecha date, p_hora time, p_personas int)
returns table (id_mesa bigint, numero int, capacidad int, forma text,
               pos_x numeric, pos_y numeric, estado text, libre_desde text)
language sql stable security definer set search_path = public as $$
  with pedido as (
    select tsrange(
             p_fecha + p_hora,
             p_fecha + p_hora + (public.duracion_para(p_personas)
               + (select limpieza_min from public.ajustes_reserva where id = 1)) * interval '1 minute'
           ) as franja
  )
  select m.id_mesa, m.numero, m.capacidad, m.forma, m.pos_x, m.pos_y,
         case
           when m.estado <> 'activa'        then 'inactiva'
           when m.capacidad < p_personas    then 'chica'
           when exists (
             select 1 from public.reserva r, pedido
              where r.id_mesa = m.id_mesa
                and r.estado in ('confirmada', 'sentada')
                and r.franja && pedido.franja
           )                                then 'ocupada'
           else 'libre'
         end as estado,
         -- si está ocupada, desde qué hora vuelve a estar libre
         (select to_char(max(upper(r.franja)), 'HH24:MI')
            from public.reserva r, pedido
           where r.id_mesa = m.id_mesa
             and r.estado in ('confirmada', 'sentada')
             and r.franja && pedido.franja) as libre_desde
    from public.mesa m
   order by m.numero;
$$;

-- ---------------------------------------------------------
-- 3. CONSULTAR Y RESERVAR con mesa elegida (opcional)
-- ---------------------------------------------------------
drop function if exists public.consultar_turno(date, time, int);
create or replace function public.consultar_turno(p_fecha date, p_hora time, p_personas int,
                                                  p_id_mesa bigint default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_motivo text;
  v_dur    int := public.duracion_para(p_personas);
  v_hasta  time := p_hora + v_dur * interval '1 minute';
  v_mesa   public.mesa;
begin
  if (p_fecha + p_hora) < (now() at time zone 'America/Montevideo') then
    return jsonb_build_object('disponible', false, 'motivo', 'Ese horario ya pasó.');
  end if;
  if p_personas > (select coalesce(max(capacidad), 0) from public.mesa where estado = 'activa') then
    return jsonb_build_object('disponible', false, 'grupo_grande', true,
      'motivo', format('No tenemos mesas para %s personas. Para grupos grandes escribinos a mareareservasuy@gmail.com.', p_personas));
  end if;
  v_motivo := public.motivo_turno(p_fecha, p_hora, p_personas);
  if v_motivo is not null then
    return jsonb_build_object('disponible', false, 'motivo', v_motivo);
  end if;

  if p_id_mesa is not null then
    select * into v_mesa from public.mesa where id_mesa = p_id_mesa;
    if not exists (select 1 from public.mesas_disponibles(p_fecha, p_hora, p_personas) d
                    where d.id_mesa = p_id_mesa) then
      return jsonb_build_object('disponible', false,
        'motivo', format('La mesa %s no está libre a esa hora para %s personas.', v_mesa.numero, p_personas));
    end if;
  elsif not exists (select 1 from public.mesas_disponibles(p_fecha, p_hora, p_personas)) then
    return jsonb_build_object('disponible', false,
      'motivo', 'No hay mesas libres para ese día, hora y cantidad de personas.');
  end if;

  return jsonb_build_object('disponible', true,
    'duracion_min', v_dur,
    'duracion_texto', public.texto_duracion(v_dur),
    'hasta', to_char(v_hasta, 'HH24:MI'),
    'mesa', v_mesa.numero);
end; $$;

drop function if exists public.crear_reserva(date, time, int);
create or replace function public.crear_reserva(p_fecha date, p_hora time, p_personas int,
                                                p_id_mesa bigint default null)
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

  if p_id_mesa is not null then
    select d.id_mesa into v_mesa
      from public.mesas_disponibles(p_fecha, p_hora, p_personas) d
     where d.id_mesa = p_id_mesa;
    if v_mesa is null then
      raise exception 'Esa mesa ya no está libre a esa hora. Elegí otra o cambiá el horario.';
    end if;
  else
    select id_mesa into v_mesa
      from public.mesas_disponibles(p_fecha, p_hora, p_personas)
     limit 1;
    if v_mesa is null then
      raise exception 'No hay mesas disponibles para ese día, hora y cantidad de personas';
    end if;
  end if;

  insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas)
  values (auth.uid(), v_mesa, p_fecha, p_hora, p_personas)
  returning * into v_reserva;
  return v_reserva;
end; $$;

-- ---------------------------------------------------------
-- 4. HORARIOS ALTERNATIVOS
-- Devuelve los 4 horarios libres más cercanos ese día y, si ese día
-- está completo, el próximo día (dentro de 14) con lugar a una hora parecida.
-- ---------------------------------------------------------
create or replace function public.horarios_alternativos(p_fecha date, p_hora time, p_personas int,
                                                        p_id_mesa bigint default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  a        public.ajustes_reserva;
  v_dur    int := public.duracion_para(p_personas);
  v_ahora  timestamp := now() at time zone 'America/Montevideo';
  v_pedido timestamp := p_fecha + p_hora;
  v_mismo  jsonb;
  v_dia    date;
  v_otro   jsonb := null;
begin
  select * into a from public.ajustes_reserva where id = 1;

  -- Horarios del mismo día, ordenados por cercanía a la hora pedida
  with turnos as (
    select t as inicio
      from generate_series(p_fecha + a.apertura,
                           public.cierre_de(p_fecha) - v_dur * interval '1 minute',
                           a.intervalo_min * interval '1 minute') t
  ), libres as (
    select inicio
      from turnos
     where inicio > v_ahora
       and inicio <> v_pedido
       and public.motivo_turno(inicio::date, inicio::time, p_personas) is null
       and exists (select 1 from public.mesas_disponibles(inicio::date, inicio::time, p_personas) d
                    where p_id_mesa is null or d.id_mesa = p_id_mesa)
     order by abs(extract(epoch from (inicio - v_pedido)))
     limit 4
  )
  select coalesce(jsonb_agg(to_char(inicio, 'HH24:MI') order by inicio), '[]'::jsonb)
    into v_mismo from libres;

  -- Si ese día no hay nada, buscamos el próximo día con lugar
  if jsonb_array_length(v_mismo) = 0 then
    for i in 1..14 loop
      v_dia := p_fecha + i;
      select jsonb_build_object('fecha', v_dia, 'hora', to_char(t, 'HH24:MI'))
        into v_otro
        from generate_series(v_dia + a.apertura,
                             public.cierre_de(v_dia) - v_dur * interval '1 minute',
                             a.intervalo_min * interval '1 minute') t
       where public.motivo_turno(t::date, t::time, p_personas) is null
         and exists (select 1 from public.mesas_disponibles(t::date, t::time, p_personas) d
                      where p_id_mesa is null or d.id_mesa = p_id_mesa)
       order by abs(extract(epoch from (t::time - p_hora)))
       limit 1;
      exit when v_otro is not null;
    end loop;
  end if;

  return jsonb_build_object('mismo_dia', v_mismo, 'otro_dia', v_otro);
end; $$;
