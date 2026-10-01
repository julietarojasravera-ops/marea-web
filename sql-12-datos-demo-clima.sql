-- =========================================================
-- MAREA · sql-12: DATOS DE DEMOSTRACIÓN para "Clima y personal"
-- Crea 3 meses de historial para ver la relación clima → cubiertos
-- → mozos. Usa el CLIMA REAL de Punta del Este de cada noche.
--
-- Cómo usarlo:
--   1. Correr antes sql-11.
--   2. Entrar al panel de admin > pestaña "Clima y personal".
--      (Al abrirla, el panel trae el clima de los últimos 92 días
--       de Open-Meteo y lo guarda en la base.)
--   3. Supabase > SQL Editor > pegar todo este archivo > Run.
--   4. Volver al panel y tocar "Actualizar".
--
-- Qué crea (todo es de demostración):
--   · 300 clientes ficticios (historial.NNN@demo.marea.test), sin correos
--   · Reservas pasadas de martes a domingo: más gente con calor y en
--     fin de semana, menos con lluvia, frío o mucho viento
--   · Los mozos de cada noche (≈ 1 cada 16 a 24 cubiertos)
--   · Algunas reservas para los próximos 6 días (sin mandar correos)
--
-- Para BORRAR todo esto (correr en el SQL Editor):
--   delete from public.personal_dia where notas = 'demo';
--   delete from public.reserva where id_usuario in
--     (select id_usuario from public.usuario where email like 'historial.%@demo.marea.test');
--   delete from auth.users where email like 'historial.%@demo.marea.test';
-- =========================================================

do $$
declare
  nombres   text[] := array['Lucía','Martín','Valentina','Santiago','Carolina','Pablo','Florencia','Gonzalo',
                            'Victoria','Andrés','Paula','Federico','Inés','Matías','Josefina','Rodrigo',
                            'Camila','Ignacio','Belén','Tomás','Natalia','Facundo','Micaela','Bruno',
                            'Sofía','Gastón','Lorena','Emiliano','Julieta','Sebastián'];
  apellidos text[] := array['Pérez','Rodríguez','González','Fernández','López','Martínez','Sosa','García',
                            'Silva','Pereira','Díaz','Ramos','Olivera','Acosta','Núñez','Méndez',
                            'Cabrera','Suárez','Castro','Vázquez','Rivero','Morales','Ferreira','Romero',
                            'Benítez','Correa','Medina','Álvarez','Techera','Bentancor'];
  clientes  uuid[] := '{}';
  v_id      uuid;
  v_nombre  text;
  n         record;
  base      numeric;
  factor    numeric;
  objetivo  int;
  hechos    int;
  tam       int;
  v_mesa    bigint;
  v_estado  text;
  v_hora    time;
  intentos  int;
  i         int;
begin
  if (select count(*) from public.clima_dia
       where fecha between public.hoy_uy() - 90 and public.hoy_uy() - 1 and not es_pronostico) < 30 then
    raise exception 'Primero abrí la pestaña "Clima y personal" del panel: ahí se guarda el clima de los últimos 90 días. Después volvé a correr este script.';
  end if;
  if exists (select 1 from public.usuario where email like 'historial.%@demo.marea.test') then
    raise exception 'Los datos de demostración ya están cargados. Para volver a crearlos, borralos primero (ver arriba).';
  end if;
  perform setseed(0.42);

  -- 1) Clientes de historial
  for i in 1 .. 300 loop
    v_id := gen_random_uuid();
    v_nombre := nombres[1 + (i * 7) % 30] || ' ' || apellidos[1 + (i * 11) % 30];
    insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at)
    values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
            'historial.' || lpad(i::text, 3, '0') || '@demo.marea.test',
            '{"provider": "email", "providers": ["email"]}'::jsonb,
            jsonb_build_object('nombre', v_nombre, 'acepta_privacidad', 'si'),
            now() - interval '120 days', now());
    clientes := clientes || v_id;
  end loop;

  -- 2) Noches pasadas (martes a domingo) con su clima real
  for n in
    select c.*, extract(isodow from c.fecha)::int as dow
      from public.clima_dia c
     where c.fecha between public.hoy_uy() - 90 and public.hoy_uy() - 1
       and not c.es_pronostico
       and extract(isodow from c.fecha) <> 1
     order by c.fecha
  loop
    base := (array[0, 18, 22, 26, 44, 56, 34])[n.dow];       -- lunes cerrado
    factor := case
      when coalesce(n.lluvia_noche_mm, 0) >= 1 or coalesce(n.codigo, 0) >= 61 then 0.55
      when coalesce(n.temp_noche, 18) >= 22 then 1.25
      when coalesce(n.temp_noche, 18) >= 16 then 1.0
      else 0.8 end
      * case when coalesce(n.viento_max, 0) >= 40 then 0.9 else 1 end;
    objetivo := round(base * factor * (0.88 + random() * 0.24));
    hechos := 0;
    while hechos < objetivo loop
      tam := (array[2, 2, 2, 3, 4, 4, 2, 6])[1 + floor(random() * 8)::int];
      select id_mesa into v_mesa from public.mesa
       where estado = 'activa' and capacidad >= tam and capacidad <= tam + 2
       order by random() limit 1;
      v_estado := case when random() < 0.92 then 'completada'
                       when random() < 0.5 then 'no_asistio' else 'cancelada' end;
      v_hora := time '19:30' + (floor(random() * 7) * 30) * interval '1 minute';
      insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas, estado)
      values (clientes[1 + floor(random() * 300)::int], v_mesa, n.fecha, v_hora, tam, v_estado);
      if v_estado = 'completada' then
        hechos := hechos + tam;
      end if;
    end loop;
    insert into public.personal_dia (fecha, mozos, notas)
    values (n.fecha, greatest(2, round(objetivo / (16 + random() * 8))), 'demo')
    on conflict (fecha) do nothing;
  end loop;

  -- 3) Reservas para los próximos 6 días (sin mandar correos)
  alter table public.reserva disable trigger despues_de_reserva;
  alter table public.reserva disable trigger despues_de_reservar_sin_correos;
  for n in
    select d::date as fecha, extract(isodow from d)::int as dow
      from generate_series(public.hoy_uy() + 1, public.hoy_uy() + 6, interval '1 day') d
     where extract(isodow from d) <> 1
  loop
    objetivo := round((array[0, 8, 10, 12, 24, 30, 16])[n.dow] * (0.8 + random() * 0.4));
    hechos := 0;
    intentos := 0;
    while hechos < objetivo and intentos < 200 loop
      intentos := intentos + 1;
      tam := (array[2, 2, 3, 4, 4, 6])[1 + floor(random() * 6)::int];
      select id_mesa into v_mesa from public.mesa
       where estado = 'activa' and capacidad >= tam and capacidad <= tam + 2
       order by random() limit 1;
      v_hora := time '19:30' + (floor(random() * 7) * 30) * interval '1 minute';
      begin
        insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas, estado)
        values (clientes[1 + floor(random() * 300)::int], v_mesa, n.fecha, v_hora, tam, 'confirmada');
        hechos := hechos + tam;
      exception when exclusion_violation then
        null;   -- la mesa ya estaba ocupada a esa hora: probamos otra
      end;
    end loop;
  end loop;
  alter table public.reserva enable trigger despues_de_reserva;
  alter table public.reserva enable trigger despues_de_reservar_sin_correos;
end $$;

-- Resumen de lo que se creó
select count(*) filter (where fecha < public.hoy_uy()) as noches_con_historial,
       sum(cubiertos) as cubiertos_atendidos,
       round(avg(cubiertos) filter (where cubiertos > 0), 1) as promedio_por_noche
  from (select r.fecha, sum(r.cantidad_personas) filter (where r.estado = 'completada') as cubiertos
          from public.reserva r
          join public.usuario u using (id_usuario)
         where u.email like 'historial.%@demo.marea.test'
         group by r.fecha) x;
