-- =========================================================
-- MAREA · sql-13: ESCALA Y ORDEN (etapa final)
-- Cómo usarlo: Supabase > SQL Editor > New query > pegar todo > Run
-- (correr DESPUÉS de sql-1 a sql-12). Se puede correr más de una vez.
--
-- Qué cambia (lo que ve el usuario sigue igual, pero aguanta miles):
--   1. Registro de versiones de la base
--   2. Índices: las búsquedas dejan de recorrer tablas enteras
--   3. Segmentación en una sola pasada (antes: 1 consulta por cliente)
--   4. Proceso diario: solo revisa a quien le toca algo + tope de correos
--   5. Listas paginadas para el panel (antes se bajaba todo al navegador)
--   6. Permisos y reglas de seguridad más eficientes (avisos de Supabase)
--   7. Mantenimiento semanal automático
--
-- Prueba de carga (20.000 clientes y 120.000 reservas):
--   antes: la lista de clientes tardaba más de 60 s (el panel se corta a los 8 s)
--   después: ver README, sección "Escalabilidad"
-- =========================================================

-- ---------------------------------------------------------
-- 1. REGISTRO DE VERSIONES
-- Cada script deja anotado que se instaló. Así se sabe en qué
-- versión está una base sin adivinar.
-- ---------------------------------------------------------
create table if not exists public.version_esquema (
  version     int primary key,
  nombre      text not null,
  aplicada_en timestamptz not null default now()
);
alter table public.version_esquema enable row level security;
drop policy if exists "admin ve versiones" on public.version_esquema;
create policy "admin ve versiones" on public.version_esquema
  for select to authenticated using ((select public.es_admin()));

insert into public.version_esquema (version, nombre) values
  (1,  'base de datos'),            (2,  'correos y alerta'),
  (3,  'correos armados'),          (4,  'seguridad'),
  (5,  'tiempos de mesa'),          (6,  'plano y alternativas'),
  (7,  'profesional'),              (8,  'invitaciones admin'),
  (9,  'fidelizacion'),             (11, 'correos y clima'),
  (13, 'escala y orden')
on conflict (version) do nothing;
-- (10 y 12 son datos de demostración: no cambian la estructura)

-- La configuración (webhook, correo del admin) no se lee desde la app
drop policy if exists "nadie lee la configuracion" on public.config_app;
create policy "nadie lee la configuracion" on public.config_app
  for select to authenticated using (false);

-- ---------------------------------------------------------
-- 2. ÍNDICES
-- Un índice es como el índice de un libro: la base va directo a
-- las filas que necesita en vez de leer la tabla entera.
-- ---------------------------------------------------------
create extension if not exists pg_trgm with schema extensions;   -- búsqueda por texto

create index if not exists reserva_usuario_fecha_idx  on public.reserva (id_usuario, fecha);
create index if not exists reserva_fecha_hora_idx     on public.reserva (fecha, hora);
create index if not exists usuario_rol_nombre_idx     on public.usuario (rol, nombre);
create index if not exists usuario_email_idx          on public.usuario (lower(email));
create index if not exists usuario_buscar_idx         on public.usuario
  using gin ((lower(nombre || ' ' || email)) extensions.gin_trgm_ops);
create index if not exists beneficio_creado_idx       on public.beneficio (creado_en desc);
create index if not exists beneficio_campana_idx      on public.beneficio (id_campana);
create index if not exists beneficio_usado_por_idx    on public.beneficio (usado_por);
create index if not exists campana_creada_en_idx      on public.campana (creada_en desc);
create index if not exists campana_creada_por_idx     on public.campana (creada_por);
create index if not exists invitacion_creada_por_idx  on public.invitacion_admin (creada_por);
create index if not exists invitacion_usada_por_idx   on public.invitacion_admin (usada_por);
create index if not exists personal_cargado_por_idx   on public.personal_dia (cargado_por);
create index if not exists registro_roles_usuario_idx on public.registro_roles (id_usuario);
create index if not exists uso_ia_usuario_idx         on public.uso_ia (id_usuario);
create index if not exists uso_ia_fecha_idx           on public.uso_ia (fecha);

-- ---------------------------------------------------------
-- 3. SEGMENTACIÓN EN UNA SOLA PASADA
-- Antes: por cada cliente se hacían ~10 consultas sobre todas las
-- reservas (con 20.000 clientes, más de un minuto).
-- Ahora: se leen las reservas una sola vez y se agrupan por cliente.
-- Mismo resultado, mismas columnas.
-- datos_clientes_de(p_usuario): si se pasa un cliente, calcula solo
-- ese (lo usan "Mis reservas" y la tarjeta de visitas).
-- ---------------------------------------------------------
create or replace function public.datos_clientes_de(p_usuario uuid)
returns table (
  id_usuario uuid, nombre text, email text, telefono text, fecha_nacimiento date,
  acepta_promociones boolean, cliente_desde date, visitas int, visitas_12m int,
  ultima_visita date, dias_sin_venir int, proxima_reserva date, cancelaciones int,
  no_asistio int, zona_favorita text, dia_favorito int, horario_favorito text,
  grupo_habitual int, ocasiones text[], proximo_cumple date, dias_para_cumple int,
  segmento text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_hoy date := public.hoy_uy();
  a     public.ajustes_fidelizacion;
begin
  select * into a from public.ajustes_fidelizacion where id = 1;
  return query
  with r as (
    select x.id_usuario, x.fecha, x.hora, x.cantidad_personas, x.estado, x.ocasion, m.zona,
           -- visita = sentada o completada, o confirmada de un día que ya pasó
           (x.estado in ('sentada', 'completada')
            or (x.estado = 'confirmada' and x.fecha < v_hoy)) as es_visita
      from public.reserva x
      join public.mesa m on m.id_mesa = x.id_mesa
     where p_usuario is null or x.id_usuario = p_usuario
  ),
  agg as (
    select r.id_usuario,
      count(*) filter (where r.es_visita)::int                              as visitas,
      count(*) filter (where r.es_visita and r.fecha > v_hoy - 365)::int    as visitas_12m,
      max(r.fecha) filter (where r.es_visita)                               as ultima_visita,
      min(r.fecha) filter (where r.estado = 'confirmada' and r.fecha >= v_hoy) as proxima_reserva,
      count(*) filter (where r.estado = 'cancelada')::int                   as cancelaciones,
      count(*) filter (where r.estado = 'no_asistio')::int                  as no_asistio,
      mode() within group (order by r.zona) filter (where r.es_visita)      as zona_favorita,
      mode() within group (order by extract(isodow from r.fecha)::int)
        filter (where r.es_visita)                                          as dia_favorito,
      mode() within group (order by case when r.hora < time '20:30' then 'temprano' else 'tarde' end)
        filter (where r.es_visita)                                          as horario_favorito,
      mode() within group (order by r.cantidad_personas) filter (where r.es_visita) as grupo_habitual,
      array_agg(distinct r.ocasion) filter (where r.ocasion is not null and r.estado <> 'cancelada') as ocasiones
    from r
    group by r.id_usuario
  ),
  base as (
    select u.id_usuario, u.nombre, u.email, u.telefono, u.fecha_nacimiento, u.acepta_promociones,
           u.fecha_creacion::date as cliente_desde,
           coalesce(g.visitas, 0) as visitas, coalesce(g.visitas_12m, 0) as visitas_12m,
           g.ultima_visita, g.proxima_reserva,
           coalesce(g.cancelaciones, 0) as cancelaciones, coalesce(g.no_asistio, 0) as no_asistio,
           g.zona_favorita, g.dia_favorito, g.horario_favorito, g.grupo_habitual, g.ocasiones,
           -- próximo cumpleaños (el 29/2 se festeja el 28/2 los años comunes)
           case when u.fecha_nacimiento is not null then
             case when (u.fecha_nacimiento + make_interval(years => extract(year from v_hoy)::int
                         - extract(year from u.fecha_nacimiento)::int))::date >= v_hoy
                  then (u.fecha_nacimiento + make_interval(years => extract(year from v_hoy)::int
                         - extract(year from u.fecha_nacimiento)::int))::date
                  else (u.fecha_nacimiento + make_interval(years => extract(year from v_hoy)::int + 1
                         - extract(year from u.fecha_nacimiento)::int))::date
             end
           end as proximo_cumple
      from public.usuario u
      left join agg g on g.id_usuario = u.id_usuario
     where u.rol = 'cliente'
       and (p_usuario is null or u.id_usuario = p_usuario)
  )
  select b.id_usuario, b.nombre, b.email, b.telefono, b.fecha_nacimiento, b.acepta_promociones,
         b.cliente_desde, b.visitas, b.visitas_12m, b.ultima_visita,
         (v_hoy - b.ultima_visita)::int,
         b.proxima_reserva, b.cancelaciones, b.no_asistio,
         b.zona_favorita, b.dia_favorito, b.horario_favorito, b.grupo_habitual, b.ocasiones,
         b.proximo_cumple, (b.proximo_cumple - v_hoy)::int,
         case
           when b.visitas = 0 then 'nuevo'
           when b.proxima_reserva is null and v_hoy - b.ultima_visita > a.dias_inactivo then 'inactivo'
           when b.proxima_reserva is null and v_hoy - b.ultima_visita > a.dias_en_riesgo then 'en_riesgo'
           when b.visitas_12m >= a.visitas_vip then 'vip'
           when b.visitas_12m >= a.visitas_frecuente then 'frecuente'
           else 'nuevo'
         end
    from base b;
end; $$;

-- La de siempre (todos los clientes), ahora apoyada en la nueva
create or replace function public.datos_clientes()
returns table (
  id_usuario uuid, nombre text, email text, telefono text, fecha_nacimiento date,
  acepta_promociones boolean, cliente_desde date, visitas int, visitas_12m int,
  ultima_visita date, dias_sin_venir int, proxima_reserva date, cancelaciones int,
  no_asistio int, zona_favorita text, dia_favorito int, horario_favorito text,
  grupo_habitual int, ocasiones text[], proximo_cumple date, dias_para_cumple int,
  segmento text
) language sql stable security definer set search_path = public as $$
  select * from public.datos_clientes_de(null);
$$;

-- "Mis reservas": calcula solo al cliente conectado
create or replace function public.mi_fidelizacion()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c record;
  a public.ajustes_fidelizacion;
begin
  if auth.uid() is null then
    return null;
  end if;
  select * into a from public.ajustes_fidelizacion where id = 1;
  select * into c from public.datos_clientes_de(auth.uid());
  if not found then
    return null;
  end if;
  return jsonb_build_object(
    'visitas',      c.visitas,
    'visitas_meta', a.visitas_meta,
    'sellos',       c.visitas % a.visitas_meta,
    'faltan',       a.visitas_meta - (c.visitas % a.visitas_meta),
    'beneficio_visitas', a.beneficio_visitas,
    'beneficio_cumple', a.beneficio_cumple,
    'proximo_cumple', c.proximo_cumple
  );
end; $$;

-- Tarjeta de visitas: cuenta solo las visitas de ese cliente
create or replace function public.contar_visitas(p_usuario uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.reserva
   where id_usuario = p_usuario
     and (estado in ('sentada', 'completada')
          or (estado = 'confirmada' and fecha < public.hoy_uy()));
$$;

create or replace function public.revisar_tarjeta_visitas(p_usuario uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  a     public.ajustes_fidelizacion;
  total int := public.contar_visitas(p_usuario);
  hito  int;
begin
  select * into a from public.ajustes_fidelizacion where id = 1;
  hito := total / a.visitas_meta;
  if hito < 1 or not exists (select 1 from public.usuario where id_usuario = p_usuario and rol = 'cliente') then
    return false;
  end if;
  return public.dar_beneficio(p_usuario, 'visitas', 'tarjeta-' || hito, a.beneficio_visitas,
                              public.hoy_uy() + a.vigencia_dias,
                              null, jsonb_build_object('visitas', total));
end; $$;

-- ---------------------------------------------------------
-- 4. PROCESO DIARIO QUE ESCALA
-- · Calcula los segmentos UNA vez.
-- · Solo recorre a los clientes a los que les toca algo y todavía
--   no lo recibieron (antes probaba con todos, todos los días).
-- · Tope de beneficios por día: si un día hay muchísimos (por
--   ejemplo, la primera vez con 10.000 inactivos), se reparten en
--   los días siguientes y no se satura el envío de correos.
--   Orden: cumpleaños, tarjeta de visitas, reactivación.
-- ---------------------------------------------------------
alter table public.ajustes_fidelizacion add column if not exists tope_diario int not null default 200
  check (tope_diario between 10 and 5000);
grant update (tope_diario) on public.ajustes_fidelizacion to authenticated;

create or replace function public.fidelizacion_diaria(p_forzar boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a        public.ajustes_fidelizacion;
  c        record;
  n_cumple int := 0;
  n_react  int := 0;
  n_visit  int := 0;
  n_total  int := 0;
  pendientes int := 0;
  resumen  jsonb;
begin
  select * into a from public.ajustes_fidelizacion where id = 1;
  if not a.automatico and not p_forzar then
    return jsonb_build_object('omitido', 'Las acciones automáticas están apagadas');
  end if;

  for c in
    with d as (select * from public.datos_clientes()),
    t as (
      select d.*,
             (d.proximo_cumple is not null and d.dias_para_cumple between 0 and a.dias_aviso_cumple
              and not exists (select 1 from public.beneficio b
                               where b.id_usuario = d.id_usuario and b.tipo = 'cumpleanos'
                                 and b.periodo = extract(year from d.proximo_cumple)::text)) as toca_cumple,
             (d.visitas >= a.visitas_meta
              and not exists (select 1 from public.beneficio b
                               where b.id_usuario = d.id_usuario and b.tipo = 'visitas'
                                 and b.periodo = 'tarjeta-' || (d.visitas / a.visitas_meta)))   as toca_tarjeta,
             (d.segmento in ('en_riesgo', 'inactivo')
              and not exists (select 1 from public.beneficio b
                               where b.id_usuario = d.id_usuario and b.tipo = 'reactivacion'
                                 and b.periodo = 'desde-' || d.ultima_visita))                   as toca_react
        from d
    )
    select * from t
     where toca_cumple or toca_tarjeta or toca_react
     order by toca_cumple desc, toca_tarjeta desc, ultima_visita desc nulls last
  loop
    if n_total >= a.tope_diario then
      pendientes := pendientes + 1;
      continue;
    end if;
    if c.toca_cumple and public.dar_beneficio(c.id_usuario, 'cumpleanos', extract(year from c.proximo_cumple)::text,
                            a.beneficio_cumple, c.proximo_cumple + 15,
                            null, jsonb_build_object('cumple', to_char(c.proximo_cumple, 'DD/MM'))) then
      n_cumple := n_cumple + 1;
      n_total := n_total + 1;
    end if;
    if c.toca_tarjeta and public.dar_beneficio(c.id_usuario, 'visitas', 'tarjeta-' || (c.visitas / a.visitas_meta),
                            a.beneficio_visitas, public.hoy_uy() + a.vigencia_dias,
                            null, jsonb_build_object('visitas', c.visitas)) then
      n_visit := n_visit + 1;
      n_total := n_total + 1;
    end if;
    if c.toca_react and public.dar_beneficio(c.id_usuario, 'reactivacion', 'desde-' || c.ultima_visita,
                            a.beneficio_reactivacion, public.hoy_uy() + a.vigencia_dias) then
      n_react := n_react + 1;
      n_total := n_total + 1;
    end if;
  end loop;

  resumen := jsonb_build_object('cumpleanos', n_cumple, 'reactivacion', n_react, 'visitas', n_visit,
                                'pendientes', pendientes);
  update public.ajustes_fidelizacion
     set ultima_ejecucion = now(), ultimo_resumen = resumen
   where id = 1;
  return resumen;
end; $$;

-- ---------------------------------------------------------
-- 5. LISTAS PARA EL PANEL (paginadas y resumidas en la base)
-- El navegador recibe de a 50 filas y los totales ya contados,
-- en vez de bajar todos los clientes y todas las reservas.
-- ---------------------------------------------------------

-- 5a. Totales de la pestaña Fidelización
create or replace function public.resumen_fidelizacion()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_hoy date := public.hoy_uy();
  r     jsonb;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver la segmentación';
  end if;
  with d as (select segmento, acepta_promociones from public.datos_clientes())
  select jsonb_build_object(
    'total',       (select count(*) from d),
    'segmentos',   coalesce((select jsonb_object_agg(segmento, n)
                               from (select segmento, count(*) n from d group by 1) s), '{}'::jsonb),
    'sin_correos', (select count(*) from d where not acepta_promociones),
    'cupones', jsonb_build_object(
       'vigentes',     (select count(*) from public.beneficio where usado_en is null and vence_en >= v_hoy),
       'creados_30',   (select count(*) from public.beneficio where creado_en >= now() - interval '30 days'),
       'usados_30',    (select count(*) from public.beneficio where creado_en >= now() - interval '30 days'
                                                               and usado_en is not null)),
    'canjes_campana', coalesce((select jsonb_object_agg(id_campana, n) from
                       (select b.id_campana, count(*) n from public.beneficio b
                         where b.id_campana in (select id_campana from public.campana
                                                 order by creada_en desc limit 8)
                           and b.usado_en is not null
                         group by 1) k), '{}'::jsonb)
  ) into r;
  return r;
end; $$;

-- 5b. Lista de clientes de Fidelización, de a una página
--     p_segmento: vip, frecuente, nuevo, en_riesgo, inactivo, sin_correos o null (todos)
create or replace function public.clientes_fidelizacion_pagina(
  p_segmento text default null, p_buscar text default null,
  p_limite int default 50, p_desde int default 0)
returns table (
  id_usuario uuid, nombre text, email text, telefono text, fecha_nacimiento date,
  acepta_promociones boolean, cliente_desde date, visitas int, visitas_12m int,
  ultima_visita date, dias_sin_venir int, proxima_reserva date, cancelaciones int,
  no_asistio int, zona_favorita text, dia_favorito int, horario_favorito text,
  grupo_habitual int, ocasiones text[], proximo_cumple date, dias_para_cumple int,
  segmento text, total_filas bigint
) language plpgsql stable security definer set search_path = public as $$
declare
  v_seg    text := nullif(trim(p_segmento), '');
  v_buscar text := '%' || lower(coalesce(trim(p_buscar), '')) || '%';
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver la segmentación';
  end if;
  return query
    select d.*, count(*) over ()
      from public.datos_clientes() d
     where (v_seg is null
            or (v_seg = 'sin_correos' and not d.acepta_promociones)
            or d.segmento = v_seg)
       and lower(coalesce(d.nombre, '') || ' ' || d.email) like v_buscar
     order by d.visitas_12m desc, d.visitas desc, d.nombre
     limit least(greatest(coalesce(p_limite, 50), 1), 200)
    offset greatest(coalesce(p_desde, 0), 0);
end; $$;

-- 5c. Quiénes reciben una promoción (solo los que aceptaron correos)
create or replace function public.destinatarios_campana(
  p_segmento text, p_zona text, p_grupo text, p_limite int default 100)
returns table (nombre text, email text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede armar campañas';
  end if;
  return query
    select u.nombre, u.email
      from public.clientes_de_campana(nullif(trim(p_segmento), ''), nullif(trim(p_zona), ''),
                                      nullif(trim(p_grupo), '')) c(id)
      join public.usuario u on u.id_usuario = c.id
     where u.acepta_promociones
     order by u.nombre
     limit least(greatest(coalesce(p_limite, 100), 1), 300);
end; $$;

-- 5c-bis. Resumen anónimo para la IA: misma respuesta, una sola pasada
create or replace function public.resumen_para_ia(p_segmento text, p_zona text, p_grupo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_seg  text := nullif(trim(p_segmento), '');
  v_zona text := nullif(trim(p_zona), '');
  v_grp  text := nullif(trim(p_grupo), '');
  v_hoy  int;
  r      jsonb;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede usar la IA';
  end if;
  select count(*) into v_hoy from public.uso_ia
   where fecha >= (public.hoy_uy()::timestamp at time zone 'America/Montevideo');
  if v_hoy >= 30 then
    raise exception 'Se llegó al límite de 30 sugerencias de IA por hoy. Probá mañana.';
  end if;
  insert into public.uso_ia (id_usuario) values (auth.uid());

  with d as (
    select c.* from public.datos_clientes() c
     where (v_seg is null or c.segmento = v_seg)
       and (v_zona is null or c.zona_favorita = v_zona)
       and (v_grp is null
            or (v_grp = 'pareja' and c.grupo_habitual <= 2)
            or (v_grp = 'grupo'  and c.grupo_habitual >= 4))
  )
  select jsonb_build_object(
    'segmento',           coalesce(v_seg, 'todos'),
    'zona_elegida',       coalesce(v_zona, 'cualquiera'),
    'grupo_elegido',      coalesce(v_grp, 'cualquiera'),
    'clientes',           (select count(*) from d),
    'aceptan_correos',    (select count(*) from d where acepta_promociones),
    'visitas_promedio',   (select round(avg(visitas), 1) from d),
    'dias_sin_venir_promedio', (select round(avg(dias_sin_venir)) from d),
    'zonas_favoritas',    (select jsonb_object_agg(zona_favorita, n) from
                            (select zona_favorita, count(*) n from d where zona_favorita is not null group by 1) z),
    'dias_favoritos',     (select jsonb_object_agg(dia, n) from
                            (select (array['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])[dia_favorito] dia,
                                    count(*) n from d where dia_favorito is not null group by 1) z),
    'horario',            (select jsonb_object_agg(horario_favorito, n) from
                            (select horario_favorito, count(*) n from d where horario_favorito is not null group by 1) z),
    'en_pareja',          (select count(*) from d where grupo_habitual <= 2),
    'en_grupo',           (select count(*) from d where grupo_habitual >= 4),
    'ocasiones',          (select jsonb_object_agg(o, n) from
                            (select o, count(*) n from d, unnest(d.ocasiones) o group by 1) z),
    'cumplen_en_30_dias', (select count(*) from d where dias_para_cumple <= 30),
    'beneficios_actuales', (select jsonb_build_object('cumpleanos', beneficio_cumple,
                              'reactivacion', beneficio_reactivacion, 'tarjeta_visitas', beneficio_visitas)
                              from public.ajustes_fidelizacion where id = 1)
  ) into r;
  return r;
end; $$;

-- 5d. Pestaña Clientes: cada usuario con sus números, de a una página
create or replace function public.clientes_panel(
  p_buscar text default null, p_limite int default 50, p_desde int default 0)
returns table (
  id_usuario uuid, nombre text, email text, telefono text, rol text,
  fecha_creacion timestamptz, total int, asistio int, fallas int,
  ultima date, proxima date, total_filas bigint, total_clientes bigint
) language plpgsql stable security definer set search_path = public as $$
declare
  v_hoy    date := public.hoy_uy();
  v_buscar text := lower(coalesce(trim(p_buscar), ''));
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver los clientes';
  end if;
  return query
    with elegidos as (
      select u.*, count(*) over () as total_filas
        from public.usuario u
       where v_buscar = '' or lower(u.nombre || ' ' || u.email) like '%' || v_buscar || '%'
       order by u.nombre, u.email
       limit least(greatest(coalesce(p_limite, 50), 1), 200)
      offset greatest(coalesce(p_desde, 0), 0)
    )
    select e.id_usuario, e.nombre, e.email, e.telefono, e.rol, e.fecha_creacion,
           coalesce(x.total, 0), coalesce(x.asistio, 0), coalesce(x.fallas, 0),
           x.ultima, x.proxima, e.total_filas,
           (select count(*) from public.usuario c where c.rol = 'cliente')
      from elegidos e
      left join lateral (
        select count(*) filter (where r.estado <> 'cancelada')::int                    as total,
               count(*) filter (where r.estado = 'completada')::int                    as asistio,
               count(*) filter (where r.estado in ('cancelada', 'no_asistio'))::int    as fallas,
               max(r.fecha) filter (where r.estado = 'completada')                     as ultima,
               min(r.fecha) filter (where r.estado = 'confirmada' and r.fecha >= v_hoy) as proxima
          from public.reserva r
         where r.id_usuario = e.id_usuario
      ) x on true
     order by e.nombre, e.email;
end; $$;

-- 5e. Buscador de clientes para "Nueva reserva" (en vez de una lista con todos)
create or replace function public.buscar_clientes(p_texto text, p_limite int default 20)
returns table (id_usuario uuid, nombre text, email text, telefono text)
language plpgsql stable security definer set search_path = public as $$
declare
  v text := lower(trim(coalesce(p_texto, '')));
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede buscar clientes';
  end if;
  return query
    select u.id_usuario, u.nombre, u.email, u.telefono
      from public.usuario u
     where v = ''
        or lower(u.nombre || ' ' || u.email) like '%' || v || '%'
        -- si escribió solo números, busca también por teléfono
        or (v ~ '^[0-9 +()-]{4,}$'
            and regexp_replace(coalesce(u.telefono, ''), '\D', '', 'g') like '%' || regexp_replace(v, '\D', '', 'g') || '%')
     order by u.nombre, u.email
     limit least(greatest(coalesce(p_limite, 20), 1), 50);
end; $$;

-- ---------------------------------------------------------
-- 6. SEGURIDAD MÁS EFICIENTE (avisos del asesor de Supabase)
-- ---------------------------------------------------------

-- 6a. Las reglas de acceso calculan "quién sos" una vez por consulta,
--     no una vez por fila: (select auth.uid()) en vez de auth.uid().
--     Y una sola regla de lectura por tabla.
drop policy if exists "ver mi perfil o admin ve todos" on public.usuario;
create policy "ver mi perfil o admin ve todos" on public.usuario
  for select to authenticated
  using (id_usuario = (select auth.uid()) or (select public.es_admin()));
drop policy if exists "editar mi perfil" on public.usuario;
create policy "editar mi perfil" on public.usuario
  for update to authenticated
  using (id_usuario = (select auth.uid())) with check (id_usuario = (select auth.uid()));

drop policy if exists "ver mis reservas o admin ve todas" on public.reserva;
create policy "ver mis reservas o admin ve todas" on public.reserva
  for select to authenticated
  using (id_usuario = (select auth.uid()) or (select public.es_admin()));
drop policy if exists "admin gestiona reservas" on public.reserva;
drop policy if exists "admin crea reservas" on public.reserva;
drop policy if exists "admin modifica reservas" on public.reserva;
drop policy if exists "admin borra reservas" on public.reserva;
create policy "admin crea reservas" on public.reserva
  for insert to authenticated with check ((select public.es_admin()));
create policy "admin modifica reservas" on public.reserva
  for update to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
create policy "admin borra reservas" on public.reserva
  for delete to authenticated using ((select public.es_admin()));

drop policy if exists "admin gestiona mesas" on public.mesa;
drop policy if exists "admin crea mesas" on public.mesa;
drop policy if exists "admin modifica mesas" on public.mesa;
drop policy if exists "admin borra mesas" on public.mesa;
create policy "admin crea mesas" on public.mesa
  for insert to authenticated with check ((select public.es_admin()));
create policy "admin modifica mesas" on public.mesa
  for update to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
create policy "admin borra mesas" on public.mesa
  for delete to authenticated using ((select public.es_admin()));

drop policy if exists "admin gestiona duraciones" on public.duracion_por_grupo;
drop policy if exists "admin crea duraciones" on public.duracion_por_grupo;
drop policy if exists "admin modifica duraciones" on public.duracion_por_grupo;
drop policy if exists "admin borra duraciones" on public.duracion_por_grupo;
create policy "admin crea duraciones" on public.duracion_por_grupo
  for insert to authenticated with check ((select public.es_admin()));
create policy "admin modifica duraciones" on public.duracion_por_grupo
  for update to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
create policy "admin borra duraciones" on public.duracion_por_grupo
  for delete to authenticated using ((select public.es_admin()));

drop policy if exists "ver mis beneficios o admin ve todos" on public.beneficio;
create policy "ver mis beneficios o admin ve todos" on public.beneficio
  for select to authenticated
  using (id_usuario = (select auth.uid()) or (select public.es_admin()));

-- Las demás reglas "solo admin": misma idea
drop policy if exists "admin ve reglas de fidelizacion" on public.ajustes_fidelizacion;
create policy "admin ve reglas de fidelizacion" on public.ajustes_fidelizacion
  for select to authenticated using ((select public.es_admin()));
drop policy if exists "admin cambia reglas de fidelizacion" on public.ajustes_fidelizacion;
create policy "admin cambia reglas de fidelizacion" on public.ajustes_fidelizacion
  for update to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
drop policy if exists "admin ve campanas" on public.campana;
create policy "admin ve campanas" on public.campana
  for select to authenticated using ((select public.es_admin()));
drop policy if exists "admin ve uso de ia" on public.uso_ia;
create policy "admin ve uso de ia" on public.uso_ia
  for select to authenticated using ((select public.es_admin()));
drop policy if exists "admin ve invitaciones" on public.invitacion_admin;
create policy "admin ve invitaciones" on public.invitacion_admin
  for select to authenticated using ((select public.es_admin()));
drop policy if exists "admin ve registro de roles" on public.registro_roles;
create policy "admin ve registro de roles" on public.registro_roles
  for select to authenticated using ((select public.es_admin()));
drop policy if exists "admin edita ajustes" on public.ajustes_reserva;
create policy "admin edita ajustes" on public.ajustes_reserva
  for update to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
drop policy if exists "admin ve el clima" on public.clima_dia;
create policy "admin ve el clima" on public.clima_dia
  for select to authenticated using ((select public.es_admin()));
drop policy if exists "admin gestiona el personal" on public.personal_dia;
create policy "admin gestiona el personal" on public.personal_dia
  for all to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
drop policy if exists "admin ve ajustes de personal" on public.ajustes_personal;
create policy "admin ve ajustes de personal" on public.ajustes_personal
  for select to authenticated using ((select public.es_admin()));
drop policy if exists "admin cambia ajustes de personal" on public.ajustes_personal;
create policy "admin cambia ajustes de personal" on public.ajustes_personal
  for update to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));

-- 6b. Funciones auxiliares con search_path fijo
alter function public.hoy_uy()                  set search_path = public;
alter function public.html_seguro(text)         set search_path = public;
alter function public.texto_duracion(int)       set search_path = public;
alter function public.validar_capacidad()       set search_path = public;
alter function public.validar_datos_cliente()   set search_path = public;

-- 6c. Las funciones internas (triggers y procesos) no se pueden
--     llamar desde la web: solo las usa la base.
revoke execute on function public.crear_usuario_nuevo()            from public, anon, authenticated;
revoke execute on function public.auditar_rol()                    from public, anon, authenticated;
revoke execute on function public.notificar_reserva()              from public, anon, authenticated;
revoke execute on function public.validar_capacidad()              from public, anon, authenticated;
revoke execute on function public.validar_datos_cliente()          from public, anon, authenticated;
revoke execute on function public.al_sumar_visita()                from public, anon, authenticated;
revoke execute on function public.al_aceptar_correos()             from public, anon, authenticated;
revoke execute on function public.avisar_cliente_sin_correos()     from public, anon, authenticated;
revoke execute on function public.datos_clientes()                 from public, anon, authenticated;
revoke execute on function public.datos_clientes_de(uuid)          from public, anon, authenticated;
revoke execute on function public.contar_visitas(uuid)             from public, anon, authenticated;
revoke execute on function public.revisar_tarjeta_visitas(uuid)    from public, anon, authenticated;
revoke execute on function public.fidelizacion_diaria(boolean)     from public, anon, authenticated;
revoke execute on function public.clientes_de_campana(text, text, text) from public, anon, authenticated;
revoke execute on function public.dar_beneficio(uuid, text, text, text, date, bigint, jsonb) from public, anon, authenticated;
revoke execute on function public.generar_codigo()                 from public, anon, authenticated;
revoke execute on function public.config(text)                     from public, anon, authenticated;
revoke execute on function public.avisar_n8n(jsonb)                from public, anon, authenticated;

-- Reservar, cancelar y extender exigen sesión iniciada
revoke execute on function public.crear_reserva(date, time, int, bigint, text, text) from public, anon;
revoke execute on function public.cancelar_mi_reserva(bigint)                       from public, anon;
revoke execute on function public.extender_reserva(bigint, int)                     from public, anon;
grant  execute on function public.crear_reserva(date, time, int, bigint, text, text) to authenticated;
grant  execute on function public.cancelar_mi_reserva(bigint)                       to authenticated;
grant  execute on function public.extender_reserva(bigint, int)                     to authenticated;

-- Las nuevas funciones del panel: solo con sesión (y adentro se exige admin)
revoke execute on function public.resumen_fidelizacion()                          from public, anon;
revoke execute on function public.clientes_fidelizacion_pagina(text, text, int, int) from public, anon;
revoke execute on function public.destinatarios_campana(text, text, text, int)    from public, anon;
revoke execute on function public.clientes_panel(text, int, int)                  from public, anon;
revoke execute on function public.buscar_clientes(text, int)                      from public, anon;
grant execute on function public.resumen_fidelizacion()                           to authenticated;
grant execute on function public.clientes_fidelizacion_pagina(text, text, int, int) to authenticated;
grant execute on function public.destinatarios_campana(text, text, text, int)     to authenticated;
grant execute on function public.clientes_panel(text, int, int)                   to authenticated;
grant execute on function public.buscar_clientes(text, int)                       to authenticated;

-- ---------------------------------------------------------
-- 7. MANTENIMIENTO SEMANAL
-- Borra lo que ya no sirve para que las tablas no crezcan sin fin.
-- (Las reservas, clientes y cupones NO se borran: son el historial.)
-- ---------------------------------------------------------
create or replace function public.mantenimiento()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  n_ia   int;
  n_inv  int;
  n_pron int;
begin
  delete from public.uso_ia where fecha < now() - interval '400 days';
  get diagnostics n_ia = row_count;
  delete from public.invitacion_admin
   where usada_en is null and vence_en < now() - interval '90 days';
  get diagnostics n_inv = row_count;
  -- pronósticos viejos que nunca se reemplazaron por el dato real
  delete from public.clima_dia where es_pronostico and fecha < public.hoy_uy() - 30;
  get diagnostics n_pron = row_count;
  return jsonb_build_object('uso_ia', n_ia, 'invitaciones', n_inv, 'pronosticos', n_pron);
end; $$;
revoke execute on function public.mantenimiento() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('marea-mantenimiento-semanal', '30 6 * * 1', 'select public.mantenimiento()');
  else
    raise notice 'Sin Cron: el mantenimiento se puede correr a mano con  select public.mantenimiento();';
  end if;
end $$;

-- Estadísticas al día para que la base elija bien los índices
analyze public.reserva;
analyze public.usuario;
analyze public.beneficio;

select 'sql-13 instalado: la base quedó lista para escalar' as listo;
