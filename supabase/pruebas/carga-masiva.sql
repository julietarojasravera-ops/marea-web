-- Carga masiva para prueba de escala: :clientes clientes, ~:reservas reservas pasadas
set session_replication_role = replica;  -- sin triggers (no manda correos)
select setseed(0.7);
insert into public.usuario (id_usuario, nombre, email, rol, fecha_nacimiento, fecha_creacion, acepta_promociones, telefono)
select gen_random_uuid(), 'Cliente ' || g, 'carga.' || g || '@prueba.test', 'cliente',
       date '1960-01-01' + (random() * 15000)::int, now() - (random() * 1000) * interval '1 day',
       random() < 0.6, '09' || lpad((random()*9999999)::int::text, 7, '0')
  from generate_series(1, :clientes) g;
create temp table ids as select id_usuario, row_number() over () as n from public.usuario where email like 'carga.%';
create temp table m as select id_mesa, capacidad, row_number() over (order by id_mesa) n from public.mesa;
insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas, estado, duracion_min, limpieza_min, ocasion)
select i.id_usuario, mm.id_mesa, public.hoy_uy() - 1 - (random() * 1095)::int,
       time '19:30' + (floor(random() * 7) * 30) * interval '1 minute', least(mm.capacidad, 2 + (random()*3)::int),
       (array['completada','completada','completada','completada','completada','completada','completada','cancelada','no_asistio'])[1 + floor(random()*9)::int],
       120, 15, case when random() < 0.1 then 'cumpleaños' end
  from (select g, 1 + floor(random() * :clientes)::int as k from generate_series(1, :reservas) g) gg
  join ids i on i.n = gg.k
  join m mm on mm.n = 1 + (gg.g % 20);
set session_replication_role = origin;
analyze;
select (select count(*) from public.usuario) usuarios, (select count(*) from public.reserva) reservas;
-- confirmadas pasadas (nadie las cerró) y futuras, en franjas que no se pisan
set session_replication_role = replica;
insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas, estado, duracion_min, limpieza_min)
select i.id_usuario, s.id_mesa, s.fecha, time '21:00', 2, 'confirmada', 120, 15
  from (select d, mm.id_mesa, public.hoy_uy() + d as fecha, 1 + floor(random() * :clientes)::int as k
          from generate_series(-200, 60) d cross join m mm
         where d <> 0 order by random() limit (:clientes / 10)) s
  join ids i on i.n = s.k;
set session_replication_role = origin;
analyze;
select estado, count(*) from public.reserva group by 1 order by 1;
