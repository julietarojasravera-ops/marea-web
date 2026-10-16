-- =========================================================
-- PARTE A — Versión profesional
-- Cómo usarlo: SQL Editor > New query > pegar todo > Run
-- (correr DESPUÉS de sql-1 a sql-6)
--
--  1. 20 mesas de capacidad par, con zonas del local
--  2. Mesa justa para cada grupo: 4 personas -> mesa de 4,
--     5 personas -> mesa de 6, nunca 5 personas en una de 8
--  3. Ocasión especial y comentarios en la reserva
--  4. Teléfono del cliente
-- =========================================================

-- ---------------------------------------------------------
-- 1. MESAS: capacidad par, zonas y plano más grande (120 x 80)
-- ---------------------------------------------------------
alter table public.mesa add column if not exists zona text;

alter table public.mesa drop constraint if exists mesa_posicion_ok;
alter table public.mesa add constraint mesa_posicion_ok
  check ((pos_x is null or pos_x between 0 and 120) and (pos_y is null or pos_y between 0 and 80));

-- Las 20 mesas de Marea (si ya existe el número, se actualiza)
insert into public.mesa (numero, capacidad, forma, zona, pos_x, pos_y, estado) values
  -- Ventanal al mar: 6 mesas de 2
  ( 1, 2, 'redonda',     'Ventanal',  12, 15, 'activa'),
  ( 2, 2, 'redonda',     'Ventanal',  26, 15, 'activa'),
  ( 3, 2, 'redonda',     'Ventanal',  40, 15, 'activa'),
  ( 4, 2, 'redonda',     'Ventanal',  54, 15, 'activa'),
  ( 5, 2, 'redonda',     'Ventanal',  68, 15, 'activa'),
  ( 6, 2, 'redonda',     'Ventanal',  82, 15, 'activa'),
  -- Salón: 8 mesas de 4
  ( 7, 4, 'cuadrada',    'Salón',     14, 34, 'activa'),
  ( 8, 4, 'cuadrada',    'Salón',     31, 34, 'activa'),
  ( 9, 4, 'cuadrada',    'Salón',     48, 34, 'activa'),
  (10, 4, 'cuadrada',    'Salón',     65, 34, 'activa'),
  (11, 4, 'cuadrada',    'Salón',     14, 51, 'activa'),
  (12, 4, 'cuadrada',    'Salón',     31, 51, 'activa'),
  (13, 4, 'cuadrada',    'Salón',     48, 51, 'activa'),
  (14, 4, 'cuadrada',    'Salón',     65, 51, 'activa'),
  -- Junto a la barra: 2 mesas de 8
  (15, 8, 'rectangular', 'Barra',     90, 34, 'activa'),
  (16, 8, 'rectangular', 'Barra',     90, 51, 'activa'),
  -- Fondo: 4 mesas de 6
  (17, 6, 'rectangular', 'Fondo',     18, 69, 'activa'),
  (18, 6, 'rectangular', 'Fondo',     38, 69, 'activa'),
  (19, 6, 'rectangular', 'Fondo',     58, 69, 'activa'),
  (20, 6, 'rectangular', 'Fondo',     78, 69, 'activa')
on conflict (numero) do update
  set capacidad = excluded.capacidad,
      forma     = excluded.forma,
      zona      = excluded.zona,
      pos_x     = excluded.pos_x,
      pos_y     = excluded.pos_y;

-- Todas las mesas tienen capacidad par (2, 4, 6, 8...)
alter table public.mesa drop constraint if exists mesa_capacidad_par;
alter table public.mesa add constraint mesa_capacidad_par check (capacidad % 2 = 0);

-- ---------------------------------------------------------
-- 2. MESA JUSTA PARA CADA GRUPO
-- holgura_mesa = cuántos lugares vacíos se permiten.
-- Con 1: 4 personas -> mesa de 4 · 5 personas -> mesa de 6 · 1 persona -> mesa de 2
-- ---------------------------------------------------------
alter table public.ajustes_reserva add column if not exists holgura_mesa int not null default 1;
alter table public.ajustes_reserva drop constraint if exists ajustes_holgura_ok;
alter table public.ajustes_reserva add constraint ajustes_holgura_ok check (holgura_mesa between 0 and 4);

-- Con 84 lugares, la cocina puede recibir más gente por turno
update public.ajustes_reserva set max_personas_por_turno = 16
 where id = 1 and max_personas_por_turno = 12;

create or replace function public.mesa_sirve(p_capacidad int, p_personas int)
returns boolean language sql stable security definer set search_path = public as $$
  select p_capacidad >= p_personas
     and p_capacidad - p_personas <= (select holgura_mesa from public.ajustes_reserva where id = 1);
$$;

create or replace function public.mesas_disponibles(p_fecha date, p_hora time, p_personas int)
returns setof public.mesa language sql stable security definer set search_path = public as $$
  select m.*
  from public.mesa m
  where m.estado = 'activa'
    and public.mesa_sirve(m.capacidad, p_personas)
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

-- Estado de cada mesa (ahora con "grande" y la zona)
drop function if exists public.estado_mesas(date, time, int);
create or replace function public.estado_mesas(p_fecha date, p_hora time, p_personas int)
returns table (id_mesa bigint, numero int, capacidad int, forma text, zona text,
               pos_x numeric, pos_y numeric, estado text, libre_desde text)
language sql stable security definer set search_path = public as $$
  with pedido as (
    select tsrange(
             p_fecha + p_hora,
             p_fecha + p_hora + (public.duracion_para(p_personas)
               + (select limpieza_min from public.ajustes_reserva where id = 1)) * interval '1 minute'
           ) as franja
  )
  select m.id_mesa, m.numero, m.capacidad, m.forma, m.zona, m.pos_x, m.pos_y,
         case
           when m.estado <> 'activa'                         then 'inactiva'
           when m.capacidad < p_personas                     then 'chica'
           when not public.mesa_sirve(m.capacidad, p_personas) then 'grande'
           when exists (
             select 1 from public.reserva r, pedido
              where r.id_mesa = m.id_mesa
                and r.estado in ('confirmada', 'sentada')
                and r.franja && pedido.franja
           )                                                 then 'ocupada'
           else 'libre'
         end as estado,
         (select to_char(max(upper(r.franja)), 'HH24:MI')
            from public.reserva r, pedido
           where r.id_mesa = m.id_mesa
             and r.estado in ('confirmada', 'sentada')
             and r.franja && pedido.franja) as libre_desde
    from public.mesa m
   order by m.numero;
$$;

-- Consultar: mensajes claros si la mesa elegida no corresponde al grupo
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
  if not exists (select 1 from public.mesa
                  where estado = 'activa' and public.mesa_sirve(capacidad, p_personas)) then
    return jsonb_build_object('disponible', false, 'grupo_grande', true,
      'motivo', format('No tenemos mesas para %s personas. Para grupos grandes escribinos a mareareservasuy@gmail.com.', p_personas));
  end if;
  v_motivo := public.motivo_turno(p_fecha, p_hora, p_personas);
  if v_motivo is not null then
    return jsonb_build_object('disponible', false, 'motivo', v_motivo);
  end if;

  if p_id_mesa is not null then
    select * into v_mesa from public.mesa where id_mesa = p_id_mesa;
    if not public.mesa_sirve(v_mesa.capacidad, p_personas) then
      return jsonb_build_object('disponible', false,
        'motivo', format('La mesa %s es para %s personas. Para %s te damos una mesa más justa: elegí otra.',
                         v_mesa.numero, v_mesa.capacidad, p_personas));
    end if;
    if not exists (select 1 from public.mesas_disponibles(p_fecha, p_hora, p_personas) d
                    where d.id_mesa = p_id_mesa) then
      return jsonb_build_object('disponible', false,
        'motivo', format('La mesa %s no está libre a esa hora.', v_mesa.numero));
    end if;
  elsif not exists (select 1 from public.mesas_disponibles(p_fecha, p_hora, p_personas)) then
    return jsonb_build_object('disponible', false,
      'motivo', format('No quedan mesas para %s personas a esa hora.', p_personas));
  end if;

  return jsonb_build_object('disponible', true,
    'duracion_min', v_dur,
    'duracion_texto', public.texto_duracion(v_dur),
    'hasta', to_char(v_hasta, 'HH24:MI'),
    'mesa', v_mesa.numero,
    'zona', v_mesa.zona);
end; $$;

-- ---------------------------------------------------------
-- 3. OCASIÓN ESPECIAL Y COMENTARIOS
-- ---------------------------------------------------------
alter table public.reserva add column if not exists ocasion text;
alter table public.reserva add column if not exists comentarios text;
alter table public.reserva drop constraint if exists reserva_ocasion_ok;
alter table public.reserva add constraint reserva_ocasion_ok
  check (ocasion is null or ocasion in ('cumpleaños', 'aniversario', 'negocios', 'cita', 'celebración', 'otra'));
alter table public.reserva drop constraint if exists reserva_comentarios_ok;
alter table public.reserva add constraint reserva_comentarios_ok
  check (comentarios is null or char_length(comentarios) <= 300);

drop function if exists public.crear_reserva(date, time, int, bigint);
create or replace function public.crear_reserva(p_fecha date, p_hora time, p_personas int,
                                                p_id_mesa bigint default null,
                                                p_ocasion text default null,
                                                p_comentarios text default null)
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
      raise exception 'Esa mesa no está disponible para tu grupo a esa hora. Elegí otra o cambiá el horario.';
    end if;
  else
    select id_mesa into v_mesa
      from public.mesas_disponibles(p_fecha, p_hora, p_personas)
     limit 1;
    if v_mesa is null then
      raise exception 'No quedan mesas para % personas a esa hora', p_personas;
    end if;
  end if;

  insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas, ocasion, comentarios)
  values (auth.uid(), v_mesa, p_fecha, p_hora, p_personas,
          nullif(p_ocasion, ''), nullif(left(trim(coalesce(p_comentarios, '')), 300), ''))
  returning * into v_reserva;
  return v_reserva;
end; $$;

-- ---------------------------------------------------------
-- 4. TELÉFONO DEL CLIENTE
-- ---------------------------------------------------------
alter table public.usuario add column if not exists telefono text;

create or replace function public.crear_usuario_nuevo()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_tel text := trim(coalesce(new.raw_user_meta_data->>'telefono', ''));
begin
  if v_tel !~ '^[0-9 +()-]{6,20}$' then
    v_tel := null;   -- si viene mal escrito no se guarda (el registro no falla)
  end if;
  insert into public.usuario (id_usuario, nombre, email, telefono, fecha_acepta_privacidad)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nombre', ''),
    new.email,
    v_tel,
    case when new.raw_user_meta_data->>'acepta_privacidad' = 'si' then now() end
  );
  return new;
end; $$;

-- Cada usuario puede actualizar su nombre, fecha de nacimiento y teléfono (nunca el rol)
revoke update on public.usuario from authenticated, anon;
grant update (nombre, fecha_nacimiento, telefono) on public.usuario to authenticated;

-- ---------------------------------------------------------
-- OPCIONAL: borrar las reservas de prueba antes de la demo
-- (quitar los guiones para usarlo)
-- delete from public.reserva;
-- ---------------------------------------------------------
