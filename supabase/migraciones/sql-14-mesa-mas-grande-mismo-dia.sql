-- =====================================================================
-- Marea · sql-14 · Mesa más grande cuando es para el mismo día
-- ---------------------------------------------------------------------
-- Regla de siempre: una mesa sirve si sobra como mucho "holgura_mesa"
-- lugares (hoy 1). Así se cuidan las mesas grandes para grupos grandes.
--
-- Nuevo: si la reserva es para HOY y no queda ninguna mesa justa libre,
-- se ofrecen las mesas libres del tamaño más chico que le sirva
-- (por ejemplo, para 4 personas: las de 6; las de 8 solo si tampoco hay de 6).
-- Reservando para otro día, se mantiene la regla de siempre.
--
-- Cambia dos funciones:
--   · mesas_disponibles  → la usan crear_reserva y el panel
--   · estado_mesas       → la usa el plano del cliente
-- =====================================================================

create or replace function public.mesas_disponibles(p_fecha date, p_hora time, p_personas integer)
returns setof public.mesa
language sql stable security definer
set search_path to 'public'
as $function$
  with libres as (
    -- mesas activas donde entra el grupo y que no se pisan con otra reserva
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
  ),
  hay_justa as (
    select exists (select 1 from libres l where public.mesa_sirve(l.capacidad, p_personas)) as si,
           (select min(l.capacidad) from libres l) as la_mas_chica
  )
  select l.*
  from libres l, hay_justa h
  where public.mesa_sirve(l.capacidad, p_personas)
     -- mismo día y sin mesa justa: vale la mesa libre más chica que le sirva (no todas las grandes)
     or (p_fecha = public.hoy_uy() and not h.si and l.capacidad = h.la_mas_chica)
  order by l.capacidad, l.numero;
$function$;

create or replace function public.estado_mesas(p_fecha date, p_hora time, p_personas integer)
returns table(id_mesa bigint, numero integer, capacidad integer, forma text, zona text,
              pos_x numeric, pos_y numeric, estado text, libre_desde text)
language sql stable security definer
set search_path to 'public'
as $function$
  with pedido as (
    select tsrange(
             p_fecha + p_hora,
             p_fecha + p_hora + (public.duracion_para(p_personas)
               + (select limpieza_min from public.ajustes_reserva where id = 1)) * interval '1 minute'
           ) as franja
  ),
  disponibles as (
    select d.id_mesa from public.mesas_disponibles(p_fecha, p_hora, p_personas) d
  )
  select m.id_mesa, m.numero, m.capacidad, m.forma, m.zona, m.pos_x, m.pos_y,
         case
           when m.estado <> 'activa'                         then 'inactiva'
           when m.capacidad < p_personas                     then 'chica'
           when not public.mesa_sirve(m.capacidad, p_personas)
                and m.id_mesa not in (select id_mesa from disponibles) then 'grande'
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
$function$;

insert into public.version_esquema (version, nombre)
values (14, 'mesa mas grande mismo dia')
on conflict do nothing;

select 'sql-14 instalado: el mismo día, si no hay mesa justa, se ofrece una más grande' as listo;
