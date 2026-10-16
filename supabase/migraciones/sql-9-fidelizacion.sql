-- =========================================================
-- PARTE B — Segmentación de clientes y acciones de fidelización
-- Cómo usarlo: SQL Editor > New query > pegar todo > Run
-- (correr DESPUÉS de sql-1 a sql-8)
--
--  Datos almacenados en Supabase
--          ↓
--  Segmentación de clientes  (recencia + frecuencia de visitas
--                             + preferencias: zona, día, grupo, ocasión)
--          ↓
--  Make (el mismo webhook de la Parte A)
--          ↓
--  Acciones de fidelización: cumpleaños · reactivación ·
--  tarjeta de visitas · promociones según preferencias
--  (con mensajes sugeridos por IA: ver sección 11)
--
--  Todo sale de las reservas: no hay que cargar nada a mano.
--  Se puede volver a correr sin problema (también si ya se había
--  corrido la versión anterior, la que usaba el gasto).
--
--  Los beneficios son cupones con código único que vencen.
--  Los correos de beneficios solo se mandan a quien aceptó
--  recibirlos (Ley 18.331). El cupón igual queda en su cuenta.
-- =========================================================

-- ---------------------------------------------------------
-- 1. DATOS NUEVOS
-- ---------------------------------------------------------

-- La versión anterior usaba el gasto de cada visita: ya no se usa
drop trigger if exists antes_de_anotar_gasto on public.reserva;
drop trigger if exists despues_de_anotar_gasto on public.reserva;
drop function if exists public.validar_gasto();
drop function if exists public.al_anotar_gasto();
drop function if exists public.revisar_meta_gasto(uuid);
alter table public.reserva drop column if exists gasto;

-- Permiso para recibir beneficios y promociones por correo
alter table public.usuario add column if not exists acepta_promociones boolean not null default false;
alter table public.usuario add column if not exists fecha_acepta_promociones timestamptz;

-- Fecha de hoy en Uruguay (Supabase trabaja en hora UTC)
create or replace function public.hoy_uy()
returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date;
$$;

-- Validar la fecha de nacimiento y registrar cuándo aceptó las promociones
create or replace function public.validar_datos_cliente()
returns trigger language plpgsql as $$
begin
  if new.fecha_nacimiento is not null
     and (new.fecha_nacimiento > public.hoy_uy() or new.fecha_nacimiento < date '1900-01-01') then
    raise exception 'La fecha de nacimiento no es válida';
  end if;
  if new.acepta_promociones and (tg_op = 'INSERT' or not old.acepta_promociones) then
    new.fecha_acepta_promociones := now();
  elsif not new.acepta_promociones then
    new.fecha_acepta_promociones := null;
  end if;
  return new;
end; $$;

drop trigger if exists antes_de_guardar_usuario on public.usuario;
create trigger antes_de_guardar_usuario
before insert or update on public.usuario
for each row execute function public.validar_datos_cliente();

-- Al registrarse: nombre, teléfono, cumpleaños (opcional) y permiso de promociones
create or replace function public.crear_usuario_nuevo()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_tel   text := trim(coalesce(new.raw_user_meta_data->>'telefono', ''));
  v_texto text := coalesce(new.raw_user_meta_data->>'fecha_nacimiento', '');
  v_nac   date;
begin
  if v_tel !~ '^[0-9 +()-]{6,20}$' then
    v_tel := null;   -- si viene mal escrito no se guarda (el registro no falla)
  end if;
  if v_texto ~ '^\d{4}-\d{2}-\d{2}$' then
    begin
      v_nac := v_texto::date;
      if v_nac > public.hoy_uy() or v_nac < date '1900-01-01' then v_nac := null; end if;
    exception when others then
      v_nac := null;
    end;
  end if;
  insert into public.usuario (id_usuario, nombre, email, telefono, fecha_nacimiento,
                              fecha_acepta_privacidad, acepta_promociones)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nombre', ''),
    new.email,
    v_tel,
    v_nac,
    case when new.raw_user_meta_data->>'acepta_privacidad' = 'si' then now() end,
    coalesce(new.raw_user_meta_data->>'acepta_promociones', '') = 'si'
  );
  return new;
end; $$;

-- Cada usuario puede cambiar estos datos suyos (nunca el rol)
revoke update on public.usuario from authenticated, anon;
grant update (nombre, fecha_nacimiento, telefono, acepta_promociones) on public.usuario to authenticated;

-- ---------------------------------------------------------
-- 2. REGLAS DE FIDELIZACIÓN (el admin las cambia desde el panel)
-- ---------------------------------------------------------
create table if not exists public.ajustes_fidelizacion (
  id                     int primary key default 1 check (id = 1),
  dias_en_riesgo         int  not null default 60  check (dias_en_riesgo between 15 and 365),
  dias_inactivo          int  not null default 150 check (dias_inactivo between 30 and 730),
  visitas_frecuente      int  not null default 3   check (visitas_frecuente between 2 and 50),
  visitas_vip            int  not null default 6   check (visitas_vip between 3 and 100),
  visitas_meta           int  not null default 5   check (visitas_meta between 2 and 50),
  dias_aviso_cumple      int  not null default 7   check (dias_aviso_cumple between 0 and 30),
  vigencia_dias          int  not null default 30  check (vigencia_dias between 7 and 180),
  beneficio_cumple       text not null default 'Postre de regalo para toda la mesa'
                         check (char_length(beneficio_cumple) between 3 and 120),
  beneficio_reactivacion text not null default '15 % de descuento en tu próxima cena'
                         check (char_length(beneficio_reactivacion) between 3 and 120),
  beneficio_visitas      text not null default 'Una botella de vino de la casa'
                         check (char_length(beneficio_visitas) between 3 and 120),
  automatico             boolean not null default true,
  ultima_ejecucion       timestamptz,
  ultimo_resumen         jsonb,
  constraint riesgo_antes_que_inactivo check (dias_en_riesgo < dias_inactivo),
  constraint frecuente_antes_que_vip   check (visitas_frecuente < visitas_vip)
);
-- Si venía de la versión con gasto: pasamos a la tarjeta de visitas
alter table public.ajustes_fidelizacion drop column if exists gasto_vip;
alter table public.ajustes_fidelizacion drop column if exists meta_gasto;
alter table public.ajustes_fidelizacion drop column if exists beneficio_gasto;
alter table public.ajustes_fidelizacion add column if not exists visitas_meta int not null default 5
  check (visitas_meta between 2 and 50);
alter table public.ajustes_fidelizacion add column if not exists beneficio_visitas text not null
  default 'Una botella de vino de la casa' check (char_length(beneficio_visitas) between 3 and 120);

insert into public.ajustes_fidelizacion (id) values (1) on conflict (id) do nothing;
alter table public.ajustes_fidelizacion enable row level security;

drop policy if exists "admin ve reglas de fidelizacion" on public.ajustes_fidelizacion;
create policy "admin ve reglas de fidelizacion" on public.ajustes_fidelizacion
  for select to authenticated using (public.es_admin());
drop policy if exists "admin cambia reglas de fidelizacion" on public.ajustes_fidelizacion;
create policy "admin cambia reglas de fidelizacion" on public.ajustes_fidelizacion
  for update to authenticated using (public.es_admin()) with check (public.es_admin());
-- La última ejecución la escribe solo el proceso diario
revoke update on public.ajustes_fidelizacion from authenticated, anon;
grant update (dias_en_riesgo, dias_inactivo, visitas_frecuente, visitas_vip, visitas_meta,
              dias_aviso_cumple, vigencia_dias, beneficio_cumple, beneficio_reactivacion,
              beneficio_visitas, automatico) on public.ajustes_fidelizacion to authenticated;

-- ---------------------------------------------------------
-- 3. SEGMENTACIÓN DE CLIENTES (recencia + frecuencia + preferencias)
-- Una visita = reserva sentada o completada, o confirmada de un día
-- que ya pasó (si nadie marcó "No vino", se asume que vino).
-- ---------------------------------------------------------
drop function if exists public.clientes_fidelizacion();
drop function if exists public.datos_clientes();
create or replace function public.datos_clientes()
returns table (
  id_usuario         uuid,
  nombre             text,
  email              text,
  telefono           text,
  fecha_nacimiento   date,
  acepta_promociones boolean,
  cliente_desde      date,
  visitas            int,
  visitas_12m        int,
  ultima_visita      date,
  dias_sin_venir     int,
  proxima_reserva    date,
  cancelaciones      int,
  no_asistio         int,
  zona_favorita      text,
  dia_favorito       int,
  horario_favorito   text,
  grupo_habitual     int,
  ocasiones          text[],
  proximo_cumple     date,
  dias_para_cumple   int,
  segmento           text
) language sql stable security definer set search_path = public as $$
  with a as (select * from public.ajustes_fidelizacion where id = 1),
  v as (   -- visitas
    select r.*, m.zona
      from public.reserva r
      join public.mesa m on m.id_mesa = r.id_mesa
     where r.estado in ('sentada', 'completada')
        or (r.estado = 'confirmada' and r.fecha < public.hoy_uy())
  ),
  base as (
    select
      u.id_usuario, u.nombre, u.email, u.telefono, u.fecha_nacimiento, u.acepta_promociones,
      u.fecha_creacion::date as cliente_desde,
      (select count(*) from v where v.id_usuario = u.id_usuario)::int as visitas,
      (select count(*) from v where v.id_usuario = u.id_usuario
                              and v.fecha > public.hoy_uy() - 365)::int as visitas_12m,
      (select max(v.fecha) from v where v.id_usuario = u.id_usuario) as ultima_visita,
      (select min(r.fecha) from public.reserva r
        where r.id_usuario = u.id_usuario and r.estado = 'confirmada'
          and r.fecha >= public.hoy_uy()) as proxima_reserva,
      (select count(*) from public.reserva r
        where r.id_usuario = u.id_usuario and r.estado = 'cancelada')::int as cancelaciones,
      (select count(*) from public.reserva r
        where r.id_usuario = u.id_usuario and r.estado = 'no_asistio')::int as no_asistio,
      (select mode() within group (order by v.zona) from v where v.id_usuario = u.id_usuario) as zona_favorita,
      (select mode() within group (order by extract(isodow from v.fecha)::int)
         from v where v.id_usuario = u.id_usuario) as dia_favorito,
      (select mode() within group (order by case when v.hora < time '20:30' then 'temprano' else 'tarde' end)
         from v where v.id_usuario = u.id_usuario) as horario_favorito,
      (select mode() within group (order by v.cantidad_personas)
         from v where v.id_usuario = u.id_usuario) as grupo_habitual,
      (select array_agg(distinct r.ocasion) from public.reserva r
        where r.id_usuario = u.id_usuario and r.ocasion is not null
          and r.estado <> 'cancelada') as ocasiones,
      -- próximo cumpleaños (el 29/2 se festeja el 28/2 los años comunes)
      case when u.fecha_nacimiento is not null then
        case when (u.fecha_nacimiento + make_interval(years => extract(year from public.hoy_uy())::int
                    - extract(year from u.fecha_nacimiento)::int))::date >= public.hoy_uy()
             then (u.fecha_nacimiento + make_interval(years => extract(year from public.hoy_uy())::int
                    - extract(year from u.fecha_nacimiento)::int))::date
             else (u.fecha_nacimiento + make_interval(years => extract(year from public.hoy_uy())::int + 1
                    - extract(year from u.fecha_nacimiento)::int))::date
        end
      end as proximo_cumple
    from public.usuario u
    where u.rol = 'cliente'
  )
  select
    b.id_usuario, b.nombre, b.email, b.telefono, b.fecha_nacimiento, b.acepta_promociones,
    b.cliente_desde, b.visitas, b.visitas_12m,
    b.ultima_visita,
    (public.hoy_uy() - b.ultima_visita)::int as dias_sin_venir,
    b.proxima_reserva, b.cancelaciones, b.no_asistio,
    b.zona_favorita, b.dia_favorito, b.horario_favorito, b.grupo_habitual, b.ocasiones,
    b.proximo_cumple,
    (b.proximo_cumple - public.hoy_uy())::int as dias_para_cumple,
    case
      when b.visitas = 0 then 'nuevo'
      when b.proxima_reserva is null and public.hoy_uy() - b.ultima_visita > a.dias_inactivo then 'inactivo'
      when b.proxima_reserva is null and public.hoy_uy() - b.ultima_visita > a.dias_en_riesgo then 'en_riesgo'
      when b.visitas_12m >= a.visitas_vip then 'vip'
      when b.visitas_12m >= a.visitas_frecuente then 'frecuente'
      else 'nuevo'
    end as segmento
  from base b cross join a;
$$;

-- Lo que ve el admin en el panel
create or replace function public.clientes_fidelizacion()
returns table (
  id_usuario uuid, nombre text, email text, telefono text, fecha_nacimiento date,
  acepta_promociones boolean, cliente_desde date, visitas int, visitas_12m int,
  ultima_visita date,
  dias_sin_venir int, proxima_reserva date, cancelaciones int, no_asistio int,
  zona_favorita text, dia_favorito int, horario_favorito text, grupo_habitual int,
  ocasiones text[], proximo_cumple date, dias_para_cumple int, segmento text
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver la segmentación';
  end if;
  return query select * from public.datos_clientes();
end; $$;

-- Lo que ve el cliente: su tarjeta de visitas (sellos) y su próximo regalo
create or replace function public.mi_fidelizacion()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c record;
  a public.ajustes_fidelizacion;
begin
  select * into a from public.ajustes_fidelizacion where id = 1;
  select * into c from public.datos_clientes() d where d.id_usuario = auth.uid();
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

-- ---------------------------------------------------------
-- 4. CAMPAÑAS Y BENEFICIOS (cupones)
-- ---------------------------------------------------------
create table if not exists public.campana (
  id_campana    bigint generated always as identity primary key,
  nombre        text not null check (char_length(nombre) between 3 and 80),
  segmento      text check (segmento in ('nuevo', 'frecuente', 'vip', 'en_riesgo', 'inactivo')),
  zona          text,
  grupo         text check (grupo in ('pareja', 'grupo')),
  asunto        text not null check (char_length(asunto) between 3 and 120),
  mensaje       text not null check (char_length(mensaje) between 3 and 1000),
  beneficio     text check (beneficio is null or char_length(beneficio) between 3 and 120),
  vence_en      date,
  destinatarios int  not null default 0,
  creada_por    uuid references public.usuario(id_usuario),
  creada_en     timestamptz not null default now()
);
alter table public.campana enable row level security;
drop policy if exists "admin ve campanas" on public.campana;
create policy "admin ve campanas" on public.campana
  for select to authenticated using (public.es_admin());

create table if not exists public.beneficio (
  id_beneficio   bigint generated always as identity primary key,
  codigo         text not null unique,
  id_usuario     uuid not null references public.usuario(id_usuario) on delete cascade,
  tipo           text not null,
  descripcion    text not null,
  periodo        text not null,       -- evita repetir: un regalo de cumpleaños por año, etc.
  id_campana     bigint references public.campana(id_campana) on delete set null,
  creado_en      timestamptz not null default now(),
  vence_en       date not null,
  usado_en       timestamptz,
  usado_por      uuid references public.usuario(id_usuario),
  correo_enviado boolean not null default false,
  unique (id_usuario, tipo, periodo)
);
-- Tipos de beneficio (la versión anterior tenía 'gasto': pasa a 'visitas')
alter table public.beneficio drop constraint if exists beneficio_tipo_check;
update public.beneficio set tipo = 'visitas' where tipo = 'gasto';
alter table public.beneficio add constraint beneficio_tipo_check
  check (tipo in ('cumpleanos', 'reactivacion', 'visitas', 'campana'));
alter table public.beneficio enable row level security;
drop policy if exists "ver mis beneficios o admin ve todos" on public.beneficio;
create policy "ver mis beneficios o admin ve todos" on public.beneficio
  for select to authenticated using (id_usuario = auth.uid() or public.es_admin());
-- (no hay políticas para crear ni modificar: solo con las funciones de abajo)

-- Texto seguro para meter dentro de un correo HTML
create or replace function public.html_seguro(p_texto text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(replace(coalesce(p_texto, ''),
         '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;'), E'\n', '<br>');
$$;

-- Código único y fácil de dictar: MAREA-7F3A9C
create or replace function public.generar_codigo()
returns text language plpgsql volatile set search_path = public as $$
declare v text;
begin
  loop
    v := 'MAREA-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (select 1 from public.beneficio where codigo = v);
  end loop;
  return v;
end; $$;

-- Crea el cupón (si no existía) y, si el cliente aceptó, le manda el correo
create or replace function public.dar_beneficio(
  p_usuario uuid, p_tipo text, p_periodo text, p_descripcion text,
  p_vence date, p_campana bigint default null, p_extra jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  b public.beneficio;
  u public.usuario;
begin
  insert into public.beneficio (codigo, id_usuario, tipo, descripcion, periodo, id_campana, vence_en)
  values (public.generar_codigo(), p_usuario, p_tipo, p_descripcion, p_periodo, p_campana, p_vence)
  on conflict (id_usuario, tipo, periodo) do nothing
  returning * into b;
  if b.id_beneficio is null then
    return false;   -- ya lo tenía
  end if;

  select * into u from public.usuario where id_usuario = p_usuario;
  if u.acepta_promociones then
    perform public.avisar_n8n(p_extra || jsonb_build_object(
      'tipo',        case when p_tipo = 'campana' then 'campana' else 'beneficio_' || p_tipo end,
      'nombre',      u.nombre,
      'email',       u.email,
      'codigo',      b.codigo,
      'descripcion', b.descripcion,
      'vence',       to_char(b.vence_en, 'DD/MM/YYYY')
    ));
    update public.beneficio set correo_enviado = true where id_beneficio = b.id_beneficio;
  end if;
  return true;
end; $$;

-- Tarjeta de visitas: cada N visitas (5 al principio), un regalo
create or replace function public.revisar_tarjeta_visitas(p_usuario uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  a     public.ajustes_fidelizacion;
  total int;
  hito  int;
begin
  select * into a from public.ajustes_fidelizacion where id = 1;
  select d.visitas into total from public.datos_clientes() d where d.id_usuario = p_usuario;
  hito := coalesce(total, 0) / a.visitas_meta;
  if hito < 1 then
    return false;
  end if;
  return public.dar_beneficio(p_usuario, 'visitas', 'tarjeta-' || hito, a.beneficio_visitas,
                              public.hoy_uy() + a.vigencia_dias,
                              null, jsonb_build_object('visitas', total));
end; $$;

-- Cada vez que el admin sienta a un grupo o libera la mesa, se suma un sello
create or replace function public.al_sumar_visita()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.estado in ('sentada', 'completada') and old.estado not in ('sentada', 'completada') then
    perform public.revisar_tarjeta_visitas(new.id_usuario);
  end if;
  return new;
end; $$;

drop trigger if exists despues_de_sumar_visita on public.reserva;
create trigger despues_de_sumar_visita
after update of estado on public.reserva
for each row execute function public.al_sumar_visita();

-- ---------------------------------------------------------
-- 5. PROCESO DIARIO: cumpleaños, reactivación y tarjeta de visitas
-- ---------------------------------------------------------
create or replace function public.fidelizacion_diaria(p_forzar boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a        public.ajustes_fidelizacion;
  c        record;
  n_cumple int := 0;
  n_react  int := 0;
  n_visit  int := 0;
  resumen  jsonb;
begin
  select * into a from public.ajustes_fidelizacion where id = 1;
  if not a.automatico and not p_forzar then
    return jsonb_build_object('omitido', 'Las acciones automáticas están apagadas');
  end if;

  for c in select * from public.datos_clientes() loop
    -- Cumpleaños: unos días antes, un regalo por año
    if c.proximo_cumple is not null and c.dias_para_cumple between 0 and a.dias_aviso_cumple then
      if public.dar_beneficio(c.id_usuario, 'cumpleanos', extract(year from c.proximo_cumple)::text,
                              a.beneficio_cumple, c.proximo_cumple + 15,
                              null, jsonb_build_object('cumple', to_char(c.proximo_cumple, 'DD/MM'))) then
        n_cumple := n_cumple + 1;
      end if;
    end if;

    -- Reactivación: clientes que vinieron y hace tiempo que no vuelven (una vez por ausencia)
    if c.segmento in ('en_riesgo', 'inactivo') then
      if public.dar_beneficio(c.id_usuario, 'reactivacion', 'desde-' || c.ultima_visita,
                              a.beneficio_reactivacion, public.hoy_uy() + a.vigencia_dias) then
        n_react := n_react + 1;
      end if;
    end if;

    -- Tarjeta de visitas (también cuenta las reservas pasadas que nadie cerró)
    if c.visitas >= a.visitas_meta and public.revisar_tarjeta_visitas(c.id_usuario) then
      n_visit := n_visit + 1;
    end if;
  end loop;

  resumen := jsonb_build_object('cumpleanos', n_cumple, 'reactivacion', n_react, 'visitas', n_visit);
  update public.ajustes_fidelizacion
     set ultima_ejecucion = now(), ultimo_resumen = resumen
   where id = 1;
  return resumen;
end; $$;

-- Botón "Ejecutar ahora" del panel
create or replace function public.ejecutar_fidelizacion()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ejecutar las acciones';
  end if;
  return public.fidelizacion_diaria(true);
end; $$;

-- ---------------------------------------------------------
-- 6. PROMOCIONES SEGÚN PREFERENCIAS (campañas del admin)
-- ---------------------------------------------------------
create or replace function public.clientes_de_campana(p_segmento text, p_zona text, p_grupo text)
returns setof uuid language sql stable security definer set search_path = public as $$
  select d.id_usuario
    from public.datos_clientes() d
   where (p_segmento is null or d.segmento = p_segmento)
     and (p_zona is null or d.zona_favorita = p_zona)
     and (p_grupo is null
          or (p_grupo = 'pareja' and d.grupo_habitual <= 2)
          or (p_grupo = 'grupo'  and d.grupo_habitual >= 4));
$$;

create or replace function public.vista_previa_campana(p_segmento text, p_zona text, p_grupo text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_total int;
  v_con   int;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede armar campañas';
  end if;
  select count(*), count(*) filter (where u.acepta_promociones)
    into v_total, v_con
    from public.clientes_de_campana(nullif(p_segmento, ''), nullif(p_zona, ''), nullif(p_grupo, '')) c(id)
    join public.usuario u on u.id_usuario = c.id;
  return jsonb_build_object('coinciden', v_total, 'destinatarios', v_con, 'sin_permiso', v_total - v_con);
end; $$;

create or replace function public.lanzar_campana(
  p_nombre text, p_segmento text, p_zona text, p_grupo text,
  p_asunto text, p_mensaje text, p_beneficio text, p_vigencia_dias int default 30)
returns public.campana language plpgsql security definer set search_path = public as $$
declare
  k      public.campana;
  u      public.usuario;
  v_n    int := 0;
  v_seg  text := nullif(trim(p_segmento), '');
  v_zona text := nullif(trim(p_zona), '');
  v_grp  text := nullif(trim(p_grupo), '');
  v_ben  text := nullif(trim(p_beneficio), '');
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede lanzar campañas';
  end if;
  if coalesce(p_vigencia_dias, 0) not between 1 and 180 then
    raise exception 'La vigencia tiene que ser de 1 a 180 días';
  end if;
  if (select count(*) from public.clientes_de_campana(v_seg, v_zona, v_grp) c(id)
        join public.usuario x on x.id_usuario = c.id and x.acepta_promociones) > 300 then
    raise exception 'La campaña llega a más de 300 personas. Elegí un público más chico.';
  end if;

  insert into public.campana (nombre, segmento, zona, grupo, asunto, mensaje, beneficio, vence_en, creada_por)
  values (trim(p_nombre), v_seg, v_zona, v_grp, trim(p_asunto), trim(p_mensaje), v_ben,
          public.hoy_uy() + p_vigencia_dias, auth.uid())
  returning * into k;

  for u in
    select x.* from public.clientes_de_campana(v_seg, v_zona, v_grp) c(id)
      join public.usuario x on x.id_usuario = c.id
     where x.acepta_promociones
  loop
    if v_ben is not null then
      perform public.dar_beneficio(u.id_usuario, 'campana', 'campana-' || k.id_campana, v_ben, k.vence_en,
                                   k.id_campana,
                                   jsonb_build_object('asunto_campana', k.asunto, 'mensaje', k.mensaje));
    else
      perform public.avisar_n8n(jsonb_build_object(
        'tipo', 'campana', 'nombre', u.nombre, 'email', u.email,
        'asunto_campana', k.asunto, 'mensaje', k.mensaje));
    end if;
    v_n := v_n + 1;
  end loop;

  update public.campana set destinatarios = v_n where id_campana = k.id_campana returning * into k;
  return k;
end; $$;

-- ---------------------------------------------------------
-- 7. CANJEAR UN CUPÓN (lo hace el admin cuando el cliente lo muestra)
-- ---------------------------------------------------------
create or replace function public.consultar_beneficio(p_codigo text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  b public.beneficio;
  u public.usuario;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede consultar cupones';
  end if;
  select * into b from public.beneficio where codigo = upper(trim(p_codigo));
  if not found then
    raise exception 'No existe un beneficio con ese código';
  end if;
  select * into u from public.usuario where id_usuario = b.id_usuario;
  return jsonb_build_object(
    'codigo', b.codigo, 'descripcion', b.descripcion, 'tipo', b.tipo,
    'cliente', u.nombre, 'email', u.email,
    'vence', b.vence_en, 'usado_en', b.usado_en,
    'estado', case when b.usado_en is not null then 'usado'
                   when b.vence_en < public.hoy_uy() then 'vencido'
                   else 'vigente' end);
end; $$;

create or replace function public.canjear_beneficio(p_codigo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  b public.beneficio;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede canjear cupones';
  end if;
  select * into b from public.beneficio where codigo = upper(trim(p_codigo)) for update;
  if not found then
    raise exception 'No existe un beneficio con ese código';
  end if;
  if b.usado_en is not null then
    raise exception 'Ese beneficio ya se usó el %', to_char(b.usado_en at time zone 'America/Montevideo', 'DD/MM/YYYY');
  end if;
  if b.vence_en < public.hoy_uy() then
    raise exception 'Ese beneficio venció el %', to_char(b.vence_en, 'DD/MM/YYYY');
  end if;
  update public.beneficio set usado_en = now(), usado_por = auth.uid()
   where id_beneficio = b.id_beneficio;
  return public.consultar_beneficio(p_codigo);
end; $$;

-- ---------------------------------------------------------
-- 8. CORREOS DE FIDELIZACIÓN (se suman al armado de correos)
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
-- 9. PERMISOS: las funciones internas no se pueden llamar desde afuera
-- ---------------------------------------------------------
revoke execute on function public.avisar_n8n(jsonb)                               from public, anon, authenticated;
revoke execute on function public.datos_clientes()                                from public, anon, authenticated;
revoke execute on function public.dar_beneficio(uuid, text, text, text, date, bigint, jsonb) from public, anon, authenticated;
revoke execute on function public.revisar_tarjeta_visitas(uuid)                   from public, anon, authenticated;
revoke execute on function public.al_sumar_visita()                               from public, anon, authenticated;
revoke execute on function public.fidelizacion_diaria(boolean)                    from public, anon, authenticated;
revoke execute on function public.clientes_de_campana(text, text, text)           from public, anon, authenticated;
revoke execute on function public.generar_codigo()                                from public, anon, authenticated;

revoke execute on function public.clientes_fidelizacion()                         from public, anon;
revoke execute on function public.mi_fidelizacion()                               from public, anon;
revoke execute on function public.ejecutar_fidelizacion()                         from public, anon;
revoke execute on function public.vista_previa_campana(text, text, text)          from public, anon;
revoke execute on function public.lanzar_campana(text, text, text, text, text, text, text, int) from public, anon;
revoke execute on function public.consultar_beneficio(text)                       from public, anon;
revoke execute on function public.canjear_beneficio(text)                         from public, anon;
grant execute on function public.clientes_fidelizacion()                          to authenticated;
grant execute on function public.mi_fidelizacion()                                to authenticated;
grant execute on function public.ejecutar_fidelizacion()                          to authenticated;
grant execute on function public.vista_previa_campana(text, text, text)           to authenticated;
grant execute on function public.lanzar_campana(text, text, text, text, text, text, text, int) to authenticated;
grant execute on function public.consultar_beneficio(text)                        to authenticated;
grant execute on function public.canjear_beneficio(text)                          to authenticated;

-- ---------------------------------------------------------
-- 10. TAREA PROGRAMADA: todos los días a las 10:00 de Uruguay (13:00 UTC)
-- Usa Supabase Cron (pg_cron). Si no se puede activar desde acá,
-- activalo en Integrations > Cron y volvé a correr solo este bloque.
-- ---------------------------------------------------------
do $$
begin
  begin
    execute 'create extension if not exists pg_cron with schema pg_catalog';
  exception when others then
    raise notice 'No se pudo activar pg_cron desde el editor: %', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('marea-fidelizacion-diaria', '0 13 * * *',
                          'select public.fidelizacion_diaria(false)');
    raise notice 'Listo: la fidelización corre todos los días a las 10:00 (hora de Uruguay).';
  else
    raise notice 'Falta activar Cron en Supabase (Integrations > Cron). Mientras tanto, usá el botón "Ejecutar ahora" del panel.';
  end if;
end $$;

-- ---------------------------------------------------------
-- 11. IA: RESUMEN ANÓNIMO DE UN PÚBLICO PARA SUGERIR PROMOCIONES
-- La función "sugerir-promocion" (Supabase Edge Function) llama a esto
-- con la sesión del admin y le pasa el resultado a Claude.
-- A la IA NUNCA le llegan nombres, correos ni teléfonos: solo totales.
-- Límite: 30 sugerencias por día, para cuidar el crédito de la API.
-- ---------------------------------------------------------
create table if not exists public.uso_ia (
  id         bigint generated always as identity primary key,
  id_usuario uuid references public.usuario(id_usuario) on delete set null,
  fecha      timestamptz not null default now()
);
alter table public.uso_ia enable row level security;
drop policy if exists "admin ve uso de ia" on public.uso_ia;
create policy "admin ve uso de ia" on public.uso_ia
  for select to authenticated using (public.es_admin());

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
     where c.id_usuario in (select id from public.clientes_de_campana(v_seg, v_zona, v_grp) x(id))
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

revoke execute on function public.resumen_para_ia(text, text, text) from public, anon;
grant execute on function public.resumen_para_ia(text, text, text) to authenticated;
