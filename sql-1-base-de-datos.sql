-- =========================================================
-- Sistema de reservas y fidelización para restaurantes
-- PARTE A (MVP) — Base de datos para Supabase
-- Cómo usarlo: Supabase > SQL Editor > New query > pegar todo > Run
-- Los nombres siguen el MER: USUARIO, MESA, RESERVA
-- =========================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------
-- 1. USUARIO  (se crea solo cuando alguien se registra)
-- ---------------------------------------------------------
create table public.usuario (
  id_usuario       uuid primary key references auth.users(id) on delete cascade,
  nombre           text not null default '',
  email            text not null,
  rol              text not null default 'cliente' check (rol in ('cliente', 'admin')),
  fecha_nacimiento date,                         -- opcional, sirve para la Parte B
  fecha_creacion   timestamptz not null default now()
);

-- Cuando alguien se registra con Supabase Auth, se crea su fila en USUARIO
create function public.crear_usuario_nuevo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.usuario (id_usuario, nombre, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', ''), new.email);
  return new;
end; $$;

create trigger al_registrarse
after insert on auth.users
for each row execute function public.crear_usuario_nuevo();

-- ¿El usuario conectado es administrador?
create function public.es_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.usuario where id_usuario = auth.uid() and rol = 'admin'
  );
$$;

-- ---------------------------------------------------------
-- 2. MESA
-- ---------------------------------------------------------
create table public.mesa (
  id_mesa   bigint generated always as identity primary key,
  numero    int  not null unique,
  capacidad int  not null check (capacidad > 0),
  estado    text not null default 'activa' check (estado in ('activa', 'inactiva'))
);

-- ---------------------------------------------------------
-- 3. RESERVA
-- Se asume que cada reserva ocupa la mesa 2 horas.
-- ---------------------------------------------------------
create table public.reserva (
  id_reserva        bigint generated always as identity primary key,
  id_usuario        uuid   not null references public.usuario(id_usuario),
  id_mesa           bigint not null references public.mesa(id_mesa),
  fecha             date   not null,
  hora              time   not null,
  cantidad_personas int    not null check (cantidad_personas > 0),
  estado            text   not null default 'confirmada'
                    check (estado in ('confirmada', 'cancelada', 'completada', 'no_asistio')),
  fecha_creacion    timestamptz not null default now(),
  -- franja horaria que ocupa la reserva (se calcula sola)
  franja tsrange generated always as
         (tsrange(fecha + hora, fecha + hora + interval '2 hours')) stored,
  -- REGLA: una mesa no puede tener dos reservas activas que se pisen
  constraint sin_superposicion
    exclude using gist (id_mesa with =, franja with &&)
    where (estado <> 'cancelada')
);

-- REGLA: la mesa tiene que estar activa y tener lugar para todos
create function public.validar_capacidad()
returns trigger language plpgsql as $$
declare m public.mesa;
begin
  if new.estado = 'cancelada' then
    return new;
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

create trigger antes_de_guardar_reserva
before insert or update on public.reserva
for each row execute function public.validar_capacidad();

-- ---------------------------------------------------------
-- 4. FUNCIONES QUE USA EL FRONTEND
-- ---------------------------------------------------------

-- Consultar disponibilidad (RF3)
create function public.mesas_disponibles(p_fecha date, p_hora time, p_personas int)
returns setof public.mesa language sql stable security definer set search_path = public as $$
  select m.*
  from public.mesa m
  where m.estado = 'activa'
    and m.capacidad >= p_personas
    and not exists (
      select 1 from public.reserva r
      where r.id_mesa = m.id_mesa
        and r.estado <> 'cancelada'
        and r.franja && tsrange(p_fecha + p_hora, p_fecha + p_hora + interval '2 hours')
    )
  order by m.capacidad, m.numero;   -- primero la mesa más chica que sirva
$$;

-- El cliente reserva: el sistema elige la mesa (RF4 + RF6)
create function public.crear_reserva(p_fecha date, p_hora time, p_personas int)
returns public.reserva language plpgsql security definer set search_path = public as $$
declare
  v_mesa    bigint;
  v_reserva public.reserva;
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión para reservar';
  end if;
  if (p_fecha + p_hora) < (now() at time zone 'America/Montevideo') then
    raise exception 'No se puede reservar en una fecha u hora que ya pasó';
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

-- El cliente cancela una reserva suya
create function public.cancelar_mi_reserva(p_id_reserva bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.reserva
  set estado = 'cancelada'
  where id_reserva = p_id_reserva
    and id_usuario = auth.uid()
    and estado = 'confirmada';
  if not found then
    raise exception 'No se encontró una reserva tuya para cancelar';
  end if;
end; $$;

-- ---------------------------------------------------------
-- 5. SEGURIDAD POR ROL (Row Level Security)
-- Cada cliente ve solo lo suyo; el admin ve y gestiona todo.
-- ---------------------------------------------------------
alter table public.usuario enable row level security;
alter table public.mesa    enable row level security;
alter table public.reserva enable row level security;

-- USUARIO
create policy "ver mi perfil o admin ve todos" on public.usuario
  for select to authenticated
  using (id_usuario = auth.uid() or public.es_admin());

create policy "editar mi perfil" on public.usuario
  for update to authenticated
  using (id_usuario = auth.uid()) with check (id_usuario = auth.uid());

-- Nadie puede cambiarse el rol a sí mismo desde la app
revoke update on public.usuario from authenticated, anon;
grant update (nombre, fecha_nacimiento) on public.usuario to authenticated;

-- MESA
create policy "todos ven las mesas" on public.mesa
  for select to authenticated using (true);

create policy "admin gestiona mesas" on public.mesa
  for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- RESERVA
create policy "ver mis reservas o admin ve todas" on public.reserva
  for select to authenticated
  using (id_usuario = auth.uid() or public.es_admin());

create policy "admin gestiona reservas" on public.reserva
  for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
-- (el cliente crea y cancela solo a través de crear_reserva y cancelar_mi_reserva)

-- ---------------------------------------------------------
-- 6. DATOS DE PRUEBA
-- ---------------------------------------------------------
insert into public.mesa (numero, capacidad) values
  (1, 2), (2, 2), (3, 4), (4, 4), (5, 4), (6, 6), (7, 8);

-- ---------------------------------------------------------
-- 7. PARA HACERTE ADMIN (después de registrarte en la app)
-- Correr esto aparte, cambiando el correo:
--   update public.usuario set rol = 'admin' where email = 'tu@correo.com';
-- ---------------------------------------------------------
