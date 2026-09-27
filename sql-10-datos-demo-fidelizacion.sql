-- =========================================================
-- PARTE B — Datos de DEMOSTRACIÓN (opcional)
-- Crea 13 clientes de prueba con historial de visitas y gastos,
-- para que la segmentación tenga datos el día de la presentación.
-- Cómo usarlo: SQL Editor > New query > pegar todo > Run
-- (correr DESPUÉS de sql-9)
--
--  - Los clientes demo usan correos @demo.marea.test (no existen).
--  - NO aceptan promociones: nunca se les manda un correo.
--  - No pueden iniciar sesión (no tienen contraseña).
--  - Para borrarlos, ver el bloque del final.
-- =========================================================

do $$
declare
  c        record;
  v_id     uuid;
  v_mesa   bigint;
  i        int;
  v_fecha  date;
begin
  for c in
    select * from (values
      -- nombre,                 mesa, personas, visitas, cada (días), última (hace días), $ por persona, cumple en (días)
      ('Martina Castro',          1,    2,        9,       30,          8,                  2400,          5),
      ('Federico Méndez',        15,    8,        5,       50,         12,                  2200,        140),
      ('Lucía Fernández',         7,    4,        4,       45,         20,                  2100,         20),
      ('Santiago Silva',          3,    2,        3,       60,         15,                  2600,         80),
      ('Valentina Rodríguez',    18,    6,        3,       40,         25,                  1900,        200),
      ('Joaquín Pereira',         9,    3,        1,       30,         10,                  2000,        300),
      ('Mateo González',         11,    4,        1,       30,         30,                  1800,         45),
      ('Camila López',            2,    2,        0,       30,          0,                     0,         60),
      ('Sofía Martínez',          4,    2,        4,       30,         75,                  2300,        110),
      ('Diego Suárez',           12,    4,        2,       40,         95,                  2000,        250),
      ('Florencia Díaz',         19,    6,        3,       60,        200,                  1700,         15),
      ('Nicolás Romero',         16,    8,        1,       30,        260,                  2100,        330),
      ('Agustina Torres',         5,    2,        2,       50,        170,                  2500,         95)
    ) as t(nombre, mesa, personas, visitas, cada, ultima, pp, cumple_en)
  loop
    v_id := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at)
    values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
            lower(translate(replace(c.nombre, ' ', '.'), 'áéíóúñ', 'aeioun')) || '@demo.marea.test',
            '{"provider": "email", "providers": ["email"]}'::jsonb,
            jsonb_build_object('nombre', c.nombre, 'acepta_privacidad', 'si',
                               'telefono', '099 ' || (100 + c.mesa * 7) || ' ' || (200 + c.visitas * 11)),
            now() - interval '400 days', now());

    -- cumpleaños: dentro de "cumple_en" días, con una edad entre 25 y 55 años
    update public.usuario
       set fecha_nacimiento = (public.hoy_uy() + c.cumple_en) - make_interval(years => 25 + (c.mesa * 3) % 30),
           acepta_promociones = false
     where id_usuario = v_id;

    select id_mesa into v_mesa from public.mesa where numero = c.mesa;
    for i in 0 .. c.visitas - 1 loop
      v_fecha := public.hoy_uy() - c.ultima - i * c.cada;
      insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas, estado, gasto, ocasion)
      values (v_id, v_mesa, v_fecha,
              case when i % 2 = 0 then time '20:00' else time '21:30' end,
              c.personas, 'completada',
              c.personas * c.pp + ((i * 37) % 9 - 4) * 150,
              case when i = 0 and c.cumple_en < 30 then 'cumpleaños'
                   when i = 1 and c.personas = 2 then 'aniversario'
                   when i = 0 and c.personas = 8 then 'celebración' end);
    end loop;
  end loop;
end $$;

-- Ver cómo quedaron segmentados (desde el SQL Editor)
select nombre, segmento, visitas, gasto_total, dias_sin_venir, zona_favorita
  from public.datos_clientes()
 where email like '%@demo.marea.test'
 order by segmento, nombre;

-- ---------------------------------------------------------
-- PARA BORRAR LOS DATOS DEMO (quitar los guiones y correr solo esto)
-- delete from public.reserva where id_usuario in
--   (select id_usuario from public.usuario where email like '%@demo.marea.test');
-- delete from auth.users where email like '%@demo.marea.test';
-- ---------------------------------------------------------
