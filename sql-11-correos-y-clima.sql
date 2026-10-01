-- =========================================================
-- MAREA · sql-11: clientes sin correos + clima y personal
-- Cómo usarlo: Supabase > SQL Editor > New query > pegar todo > Run
-- (correr DESPUÉS de sql-1 a sql-10). Se puede correr más de una vez.
--
--  A. CLIENTES QUE NO ACEPTARON CORREOS
--     1. Regalo de bienvenida para quien se suma a los beneficios
--     2. Aviso al admin cuando reserva alguien sin correos
--     3. Lista de "invitar hoy" para el Dashboard
--  B. CLIMA Y PERSONAL
--     4. Clima de cada noche (lo guarda el panel desde Open-Meteo)
--     5. Mozos de cada noche y reglas de personal
--     6. Historial: clima + cubiertos + mozos, para la correlación
-- =========================================================

-- ---------------------------------------------------------
-- 1. REGALO DE BIENVENIDA AL SUMARSE A LOS CORREOS
-- ---------------------------------------------------------
alter table public.ajustes_fidelizacion add column if not exists beneficio_bienvenida text not null
  default 'Una copa de bienvenida en tu próxima visita'
  check (char_length(beneficio_bienvenida) between 3 and 120);
alter table public.ajustes_fidelizacion add column if not exists aviso_sin_correos boolean not null default true;
grant update (beneficio_bienvenida, aviso_sin_correos) on public.ajustes_fidelizacion to authenticated;

-- nuevo tipo de beneficio: bienvenida
alter table public.beneficio drop constraint if exists beneficio_tipo_check;
alter table public.beneficio add constraint beneficio_tipo_check
  check (tipo in ('cumpleanos', 'reactivacion', 'visitas', 'campana', 'bienvenida'));

-- Cuando un cliente acepta recibir correos (al registrarse o después,
-- desde la web), recibe una sola vez el regalo de bienvenida.
create or replace function public.al_aceptar_correos()
returns trigger language plpgsql security definer set search_path = public as $$
declare a public.ajustes_fidelizacion;
begin
  if new.rol = 'cliente' and new.acepta_promociones
     and (tg_op = 'INSERT' or not coalesce(old.acepta_promociones, false)) then
    select * into a from public.ajustes_fidelizacion where id = 1;
    perform public.dar_beneficio(new.id_usuario, 'bienvenida', 'unica', a.beneficio_bienvenida,
                                 public.hoy_uy() + a.vigencia_dias);
  end if;
  return new;
end; $$;

drop trigger if exists despues_de_aceptar_correos on public.usuario;
create trigger despues_de_aceptar_correos
after insert or update of acepta_promociones on public.usuario
for each row execute function public.al_aceptar_correos();

-- Texto del regalo, para mostrarlo en la web (también a visitantes sin cuenta)
create or replace function public.texto_bienvenida()
returns text language sql stable security definer set search_path = public as $$
  select beneficio_bienvenida from public.ajustes_fidelizacion where id = 1;
$$;

-- ---------------------------------------------------------
-- 2. AVISO AL ADMIN: RESERVÓ ALGUIEN QUE NO RECIBE CORREOS
-- Así el equipo lo invita en el local a sumarse a los beneficios.
-- ---------------------------------------------------------
create or replace function public.avisar_cliente_sin_correos()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  u public.usuario;
  a public.ajustes_fidelizacion;
begin
  if new.estado <> 'confirmada' or new.fecha < public.hoy_uy() then
    return new;
  end if;
  select * into u from public.usuario where id_usuario = new.id_usuario;
  select * into a from public.ajustes_fidelizacion where id = 1;
  if u.rol = 'cliente' and not u.acepta_promociones and a.aviso_sin_correos then
    perform public.avisar_n8n(jsonb_build_object(
      'tipo',                 'cliente_sin_correos',
      'email',                public.config('email_admin'),
      'cliente',              u.nombre,
      'id_reserva',           new.id_reserva,
      'fecha',                to_char(new.fecha, 'DD/MM/YYYY'),
      'hora',                 to_char(new.hora, 'HH24:MI'),
      'personas',             new.cantidad_personas,
      'beneficio_bienvenida', a.beneficio_bienvenida
    ));
  end if;
  return new;
end; $$;

drop trigger if exists despues_de_reservar_sin_correos on public.reserva;
create trigger despues_de_reservar_sin_correos
after insert on public.reserva
for each row execute function public.avisar_cliente_sin_correos();

-- ---------------------------------------------------------
-- 3. "INVITAR HOY": reservas del día de clientes sin correos
-- ---------------------------------------------------------
create or replace function public.invitar_a_sumarse(p_fecha date)
returns table (id_reserva bigint, nombre text, hora time, personas int, mesa int, visitas int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver esta lista';
  end if;
  return query
    select r.id_reserva, u.nombre, r.hora, r.cantidad_personas, m.numero,
           (select count(*) from public.reserva x
             where x.id_usuario = u.id_usuario
               and (x.estado in ('sentada', 'completada')
                    or (x.estado = 'confirmada' and x.fecha < public.hoy_uy())))::int
      from public.reserva r
      join public.usuario u on u.id_usuario = r.id_usuario
      join public.mesa m on m.id_mesa = r.id_mesa
     where r.fecha = p_fecha
       and r.estado in ('confirmada', 'sentada')
       and u.rol = 'cliente'
       and not u.acepta_promociones
     order by r.hora;
end; $$;

-- ---------------------------------------------------------
-- Correos: se agregan 'beneficio_bienvenida' y 'cliente_sin_correos'
-- (misma función de sql-9, con dos casos nuevos)
-- ---------------------------------------------------------
create or replace function public.avisar_n8n(p_datos jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_url      text := public.config('n8n_webhook_url');
  v_sitio    text := coalesce(public.config('sitio_url'), '');
  d          jsonb := p_datos;
  v_nombre   text := public.html_seguro(split_part(coalesce(p_datos->>'nombre', ''), ' ', 1));
  v_personas text := (p_datos->>'personas') ||
                     case when p_datos->>'personas' = '1' then ' persona' else ' personas' end;
  v_detalle  text;
  v_cupon    text := '';
  v_boton    text;
  v_pie      text := 'Marea · Costa atlántica uruguaya · Cenas de 19 a 00 h';
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

  if d ? 'codigo' then
    v_cupon := format(
      '<div style="margin:22px 0;padding:20px;border:2px dashed #b08d57;border-radius:14px;text-align:center">'
      '<div style="font-size:12px;color:#6b7785;letter-spacing:3px">TU BENEFICIO</div>'
      '<div style="font-family:Georgia,serif;font-size:21px;color:#0e2a47;margin:8px 0 12px">%s</div>'
      '<div style="font-family:monospace;font-size:22px;letter-spacing:3px;color:#0e2a47;background:#f6efe2;'
      'display:inline-block;padding:8px 16px;border-radius:8px">%s</div>'
      '<div style="font-size:13px;color:#6b7785;margin-top:10px">Válido hasta el %s · Mostrá el código al llegar</div>'
      '</div>',
      public.html_seguro(d->>'descripcion'), public.html_seguro(d->>'codigo'), d->>'vence');
  end if;
  v_boton := format(
    '<a href="%s/reservar.html" style="display:inline-block;background:#0e2a47;color:#ffffff;'
    'text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:bold">Reservar mi mesa</a>',
    v_sitio);

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
    when 'invitacion_admin' then
      v_asunto := 'Te invitaron a administrar Marea';
      v_titulo := format('Hola, %s', coalesce(nullif(v_nombre, ''), 'equipo'));
      v_cuerpo := format(
        '%s te invitó a ser <b>administrador/a</b> del sistema de reservas de Marea.'
        '<br><br><a href="%s" style="display:inline-block;background:#0e2a47;color:#ffffff;'
        'text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:bold">Aceptar invitación</a>'
        '<br><br><span style="color:#6b7785;font-size:13px">El enlace sirve una sola vez, vence el %s '
        'y solo funciona con esta dirección de correo. Si no esperabas esta invitación, ignorá este correo.</span>',
        public.html_seguro(d->>'invitado_por'), d->>'enlace', d->>'vence');
    when 'beneficio_cumpleanos' then
      v_asunto := format('¡Feliz cumpleaños, %s! Tenés un regalo en Marea', split_part(coalesce(d->>'nombre', ''), ' ', 1));
      v_titulo := 'Se viene tu cumpleaños';
      v_cuerpo := format('Hola, %s. Sabemos que el <b>%s</b> es tu día y queremos festejarlo con vos. '
                         'Reservá tu mesa para esa semana y te esperamos con:', v_nombre, d->>'cumple')
                  || v_cupon || v_boton;
    when 'beneficio_reactivacion' then
      v_asunto := format('%s, te extrañamos en Marea', split_part(coalesce(d->>'nombre', ''), ' ', 1));
      v_titulo := 'Hace rato que no te vemos';
      v_cuerpo := format('Hola, %s. El mar sigue ahí, la parrilla también, y tu mesa te está esperando. '
                         'Para que vuelvas, te guardamos esto:', v_nombre)
                  || v_cupon || v_boton;
    when 'beneficio_visitas' then
      v_asunto := 'Completaste tu tarjeta de visitas: tenés un regalo en Marea';
      v_titulo := format('Gracias, %s', v_nombre);
      v_cuerpo := format('Ya son <b>%s visitas</b> a Marea y queremos agradecértelo. '
                         'En tu próxima cena te espera:', coalesce(d->>'visitas', 'varias'))
                  || v_cupon || v_boton;
    when 'beneficio_bienvenida' then
      v_asunto := format('Bienvenido/a a los beneficios de Marea, %s', split_part(coalesce(d->>'nombre', ''), ' ', 1));
      v_titulo := format('¡Gracias por sumarte, %s!', v_nombre);
      v_cuerpo := 'Desde ahora te vamos a avisar las novedades de la semana, las promociones exclusivas '
                  'y los regalos que te esperan. Para empezar, te guardamos esto:'
                  || v_cupon || v_boton;
    when 'cliente_sin_correos' then
      v_asunto := format('Reservó %s y todavía no recibe beneficios · %s %s',
                         coalesce(d->>'cliente', 'un cliente'), d->>'fecha', d->>'hora');
      v_titulo := 'Invitalo a sumarse a los beneficios';
      v_cuerpo := format('<b>%s</b> reservó y todavía <b>no aceptó recibir correos</b> de Marea.',
                         public.html_seguro(d->>'cliente'))
                  || v_detalle ||
                  format('Cuando llegue, contale lo que gana si se suma: <b>%s</b>, promociones exclusivas '
                         'y las novedades de la semana. Lo activa en un toque desde <b>Mi perfil</b> en la web.',
                         public.html_seguro(d->>'beneficio_bienvenida'));
    when 'campana' then
      v_asunto := coalesce(d->>'asunto_campana', 'Novedades de Marea');
      v_titulo := format('Hola, %s', coalesce(nullif(v_nombre, ''), 'amigo de Marea'));
      v_cuerpo := public.html_seguro(d->>'mensaje') || v_cupon || '<br>' || v_boton;
    else
      return;
  end case;

  if d->>'tipo' like 'beneficio_%' or d->>'tipo' = 'campana' then
    v_pie := v_pie || '<br>Recibís este correo porque aceptaste recibir beneficios de Marea. '
             || format('Podés desactivarlo cuando quieras desde <a href="%s/perfil.html" style="color:#6b7785">Mi perfil</a>.', v_sitio);
  end if;

  v_html := format(
    '<div style="background:#f6efe2;padding:32px 12px;font-family:Arial,sans-serif;color:#1b2733">'
    '<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden">'
    '<div style="background:#0e2a47;color:#fff;padding:22px 28px;font-family:Georgia,serif;font-size:22px;letter-spacing:6px">MAREA</div>'
    '<div style="padding:28px"><h2 style="font-family:Georgia,serif;font-weight:normal;color:#0e2a47;margin:0 0 12px">%s</h2>'
    '<div style="line-height:1.55">%s</div></div>'
    '<div style="padding:16px 28px;background:#f6efe2;color:#6b7785;font-size:12px;line-height:1.5">%s</div>'
    '</div></div>', v_titulo, v_cuerpo, v_pie);

  perform net.http_post(
    url     := v_url,
    body    := d || jsonb_build_object('asunto', v_asunto, 'html', v_html,
                                    'secreto', public.config('webhook_secreto')),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
exception when others then
  raise warning 'No se pudo avisar a la automatización: %', sqlerrm;
end; $$;


-- ---------------------------------------------------------
-- 4. CLIMA DE CADA NOCHE
-- El panel lo trae de Open-Meteo (últimos 92 días + próximos 16)
-- y lo guarda acá. "Noche" = de 19 a 23 h, que es cuando se cena.
-- ---------------------------------------------------------
create table if not exists public.clima_dia (
  fecha            date primary key,
  temp_max         numeric(4,1),            -- máxima del día (°C)
  temp_noche       numeric(4,1),            -- promedio de 19 a 23 h (°C)
  lluvia_mm        numeric(5,1),            -- lluvia de todo el día (mm)
  lluvia_noche_mm  numeric(5,1),            -- lluvia de 19 a 23 h (mm)
  prob_lluvia      int check (prob_lluvia between 0 and 100),
  codigo           int,                     -- código del tiempo (OMM) de la noche
  viento_max       numeric(4,1),            -- km/h
  es_pronostico    boolean not null default false,
  actualizado      timestamptz not null default now()
);
alter table public.clima_dia enable row level security;
drop policy if exists "admin ve el clima" on public.clima_dia;
create policy "admin ve el clima" on public.clima_dia
  for select to authenticated using (public.es_admin());
-- (se escribe solo con guardar_clima)

create or replace function public.guardar_clima(p_dias jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  n int;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede guardar el clima';
  end if;
  insert into public.clima_dia as c (fecha, temp_max, temp_noche, lluvia_mm, lluvia_noche_mm,
                                     prob_lluvia, codigo, viento_max, es_pronostico, actualizado)
  select (d->>'fecha')::date, (d->>'temp_max')::numeric, (d->>'temp_noche')::numeric,
         (d->>'lluvia_mm')::numeric, (d->>'lluvia_noche_mm')::numeric,
         least(100, greatest(0, (d->>'prob_lluvia')::int)), (d->>'codigo')::int,
         (d->>'viento_max')::numeric,
         (d->>'fecha')::date >= public.hoy_uy(), now()
    from jsonb_array_elements(p_dias) d
   where (d->>'fecha') ~ '^\d{4}-\d{2}-\d{2}$'
  on conflict (fecha) do update
     set temp_max = excluded.temp_max, temp_noche = excluded.temp_noche,
         lluvia_mm = excluded.lluvia_mm, lluvia_noche_mm = excluded.lluvia_noche_mm,
         prob_lluvia = excluded.prob_lluvia, codigo = excluded.codigo,
         viento_max = excluded.viento_max, es_pronostico = excluded.es_pronostico,
         actualizado = now()
   -- lo que ya pasó y quedó como dato real no se pisa con un pronóstico
   where not (c.es_pronostico = false and excluded.es_pronostico = true);
  get diagnostics n = row_count;
  return n;
end; $$;

-- ---------------------------------------------------------
-- 5. PERSONAL: mozos de cada noche + reglas
-- ---------------------------------------------------------
create table if not exists public.personal_dia (
  fecha       date primary key,
  mozos       int not null check (mozos between 0 and 60),
  notas       text check (char_length(notas) <= 200),
  cargado_por uuid references public.usuario(id_usuario) default auth.uid(),
  actualizado timestamptz not null default now()
);
alter table public.personal_dia enable row level security;
drop policy if exists "admin gestiona el personal" on public.personal_dia;
create policy "admin gestiona el personal" on public.personal_dia
  for all to authenticated using (public.es_admin()) with check (public.es_admin());

create table if not exists public.ajustes_personal (
  id                 int primary key default 1 check (id = 1),
  cubiertos_por_mozo int not null default 20 check (cubiertos_por_mozo between 5 and 60),
  mozos_minimos      int not null default 2  check (mozos_minimos between 1 and 20)
);
insert into public.ajustes_personal (id) values (1) on conflict (id) do nothing;
alter table public.ajustes_personal enable row level security;
drop policy if exists "admin ve ajustes de personal" on public.ajustes_personal;
create policy "admin ve ajustes de personal" on public.ajustes_personal
  for select to authenticated using (public.es_admin());
drop policy if exists "admin cambia ajustes de personal" on public.ajustes_personal;
create policy "admin cambia ajustes de personal" on public.ajustes_personal
  for update to authenticated using (public.es_admin()) with check (public.es_admin());

-- ---------------------------------------------------------
-- 6. HISTORIAL POR NOCHE: clima + cubiertos + mozos
-- "Cubiertos" = personas atendidas (no registramos montos de venta,
-- así que los cubiertos son la medida de cuánto se vendió esa noche).
-- Para días que vienen: cubiertos ya reservados.
-- ---------------------------------------------------------
create or replace function public.historial_noches(p_desde date, p_hasta date)
returns table (
  fecha            date,
  dia_semana       int,       -- 1 = lunes … 7 = domingo
  reservas         int,
  cubiertos        int,       -- atendidos (días pasados)
  reservados       int,       -- confirmados o sentados (hoy y días que vienen)
  cancelaciones    int,
  no_vinieron      int,
  mozos            int,
  temp_max         numeric,
  temp_noche       numeric,
  lluvia_mm        numeric,
  lluvia_noche_mm  numeric,
  prob_lluvia      int,
  codigo           int,
  viento_max       numeric,
  es_pronostico    boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver el historial';
  end if;
  if p_hasta - p_desde > 400 then
    raise exception 'Elegí un período de hasta 400 días';
  end if;
  return query
    with dias as (select generate_series(p_desde, p_hasta, interval '1 day')::date as f),
    r as (
      select r.fecha,
             count(*) filter (where r.estado <> 'cancelada')::int as reservas,
             coalesce(sum(r.cantidad_personas) filter (
               where r.estado in ('sentada', 'completada')
                  or (r.estado = 'confirmada' and r.fecha < public.hoy_uy())), 0)::int as cubiertos,
             coalesce(sum(r.cantidad_personas) filter (
               where r.estado in ('confirmada', 'sentada')), 0)::int as reservados,
             count(*) filter (where r.estado = 'cancelada')::int as cancelaciones,
             count(*) filter (where r.estado = 'no_asistio')::int as no_vinieron
        from public.reserva r
       where r.fecha between p_desde and p_hasta
       group by r.fecha
    )
    select d.f, extract(isodow from d.f)::int,
           coalesce(r.reservas, 0), coalesce(r.cubiertos, 0), coalesce(r.reservados, 0),
           coalesce(r.cancelaciones, 0), coalesce(r.no_vinieron, 0),
           p.mozos,
           c.temp_max, c.temp_noche, c.lluvia_mm, c.lluvia_noche_mm, c.prob_lluvia, c.codigo,
           c.viento_max, c.es_pronostico
      from dias d
      left join r on r.fecha = d.f
      left join public.clima_dia c on c.fecha = d.f
      left join public.personal_dia p on p.fecha = d.f
     order by d.f;
end; $$;

-- ---------------------------------------------------------
-- 7. PERMISOS
-- ---------------------------------------------------------
revoke execute on function public.al_aceptar_correos()            from public, anon, authenticated;
revoke execute on function public.avisar_cliente_sin_correos()    from public, anon, authenticated;
revoke execute on function public.invitar_a_sumarse(date)         from public, anon;
revoke execute on function public.guardar_clima(jsonb)            from public, anon;
revoke execute on function public.historial_noches(date, date)    from public, anon;
grant execute on function public.invitar_a_sumarse(date)          to authenticated;
grant execute on function public.guardar_clima(jsonb)             to authenticated;
grant execute on function public.historial_noches(date, date)     to authenticated;
grant execute on function public.texto_bienvenida()               to anon, authenticated;
revoke execute on function public.avisar_n8n(jsonb)               from public, anon, authenticated;

select 'sql-11 instalado: clientes sin correos + clima y personal' as listo;
