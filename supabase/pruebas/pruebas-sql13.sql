-- Pruebas automáticas de la versión 13 (47 comprobaciones). Se corren en una base de PRUEBA
-- armada con simulador-supabase.sql + instalación + carga-masiva.sql. NO correr en Supabase.
-- Pruebas de sql-13 (se corren sobre una base con sql-1..13 + datos de carga)
\set ON_ERROR_STOP 0
\pset pager off
create table if not exists public.z_res (n serial, prueba text, ok boolean, detalle text);
create or replace function public.z_ok(p text, c boolean, d text default null) returns void language sql as
$$ insert into public.z_res (prueba, ok, detalle) values (p, coalesce(c, false), d) $$;
-- funciones de error esperado
create or replace function public.z_falla(p text, q text, esperado text) returns void language plpgsql as $$
begin
  execute q;
  perform public.z_ok(p, false, 'no falló');
exception when others then
  perform public.z_ok(p, sqlerrm ilike '%' || esperado || '%', sqlerrm);
end $$;
grant all on public.z_res to anon, authenticated; grant usage on sequence z_res_n_seq to anon, authenticated;
grant execute on function public.z_ok(text, boolean, text) to anon, authenticated;
grant execute on function public.z_falla(text, text, text) to anon, authenticated;

insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000a1','admin13@m.com','{"nombre":"Admin Trece"}'),
 ('00000000-0000-0000-0000-0000000000c1','zoe13@m.com','{"nombre":"Zoe Trece","telefono":"099 123 456","acepta_promociones":"si"}'),
 ('00000000-0000-0000-0000-0000000000c2','yago13@m.com','{"nombre":"Yago Trece"}')
on conflict do nothing;
update public.usuario set rol='admin' where email='admin13@m.com';

-- 1. Versión
select z_ok('1. versión 13 registrada', exists (select 1 from version_esquema where version = 13));

-- 2. Índices clave
select z_ok('2. índice reserva por cliente', exists (select 1 from pg_indexes where indexname='reserva_usuario_fecha_idx'));
select z_ok('2b. índice búsqueda', exists (select 1 from pg_indexes where indexname='usuario_buscar_idx'));
select z_ok('2c. FK sin índice = 0', not exists (
  select 1 from pg_constraint c
   where c.contype='f' and c.connamespace='public'::regnamespace
     and not exists (select 1 from pg_index i where i.indrelid=c.conrelid and i.indkey[0] = c.conkey[1])),
  (select string_agg(conname, ', ') from pg_constraint c where c.contype='f' and c.connamespace='public'::regnamespace
     and not exists (select 1 from pg_index i where i.indrelid=c.conrelid and i.indkey[0] = c.conkey[1])));

-- 3. Uno vs todos: datos_clientes_de(u) = fila de datos_clientes()
select z_ok('3. un cliente = su fila en la lista completa',
  (select count(*) from (
     select d.* from datos_clientes() d
     except
     select x.* from (select id_usuario from usuario where rol='cliente' order by id_usuario limit 300) u,
                     lateral datos_clientes_de(u.id_usuario) x
   ) q where q.id_usuario in (select id_usuario from usuario where rol='cliente' order by id_usuario limit 300)) = 0);
select z_ok('3b. admin no aparece como cliente', not exists (select 1 from datos_clientes_de('00000000-0000-0000-0000-0000000000a1')));

-- 4. Permisos: cliente común
set role authenticated; set test.uid='00000000-0000-0000-0000-0000000000c1';
select z_falla('4. cliente no ve la página de fidelización', 'select * from clientes_fidelizacion_pagina()', 'administrador');
select z_falla('4b. cliente no ve el resumen', 'select resumen_fidelizacion()', 'administrador');
select z_falla('4c. cliente no ve clientes_panel', 'select * from clientes_panel()', 'administrador');
select z_falla('4d. cliente no busca clientes', 'select * from buscar_clientes(''a'')', 'administrador');
select z_falla('4e. cliente no ve destinatarios', 'select * from destinatarios_campana(null,null,null)', 'administrador');
select z_falla('4f. cliente no llama datos_clientes', 'select * from datos_clientes()', 'permission denied');
select z_falla('4g. cliente no corre el proceso diario', 'select fidelizacion_diaria(true)', 'permission denied');
select z_falla('4h. cliente no llama triggers', 'select notificar_reserva()', 'permission denied');
select z_ok('4i. mi_fidelizacion funciona', (mi_fidelizacion()->>'visitas_meta') is not null);
select z_ok('4j. cliente ve solo sus reservas', (select count(*) from reserva where id_usuario <> auth.uid()) = 0);
select z_ok('4k. cliente ve solo su usuario', (select count(*) from usuario) = 1);
reset role;
set role anon; set test.uid='';
select z_falla('5. anónimo no reserva', 'select crear_reserva(hoy_uy()+1, ''21:00'', 2, null, null, null)', 'permission denied');
select z_ok('5b. anónimo consulta disponibilidad', (select count(*) from estado_mesas(hoy_uy()+1, '21:00', 2)) > 0);
reset role;

-- 6. Límite de reservas (ya existía en crear_reserva: config max_reservas_cliente, 3)
set role authenticated; set test.uid='00000000-0000-0000-0000-0000000000c2';
select crear_reserva(hoy_uy()+70+g, '20:00', 2, null, null, null) from generate_series(1,3) g;
select z_falla('6. la cuarta se rechaza', 'select crear_reserva(hoy_uy()+80, ''20:00'', 2, null, null, null)', 'Ya tenés 3 reservas');
reset role;
set role authenticated; set test.uid='00000000-0000-0000-0000-0000000000a1';
insert into reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas)
  select '00000000-0000-0000-0000-0000000000c2', (select id_mesa from mesa where estado='activa' and capacidad>=2 order by numero limit 1), hoy_uy()+90, '20:00', 2;
select z_ok('6b. el admin le carga una más', (select count(*) from reserva where id_usuario='00000000-0000-0000-0000-0000000000c2' and estado='confirmada' and fecha>=hoy_uy()) = 4);

-- 7. Panel admin: listas paginadas
select z_ok('7. página de 50', (select count(*) from clientes_fidelizacion_pagina(null, null, 50, 0)) = least(50, (select count(*) from usuario where rol='cliente')));
select z_ok('7b. total_filas = clientes', (select max(total_filas) from clientes_fidelizacion_pagina(null, null, 5, 0)) = (select count(*) from usuario where rol='cliente'));
select z_ok('7c. páginas no se repiten', (select count(distinct id_usuario) from (
   select id_usuario from clientes_fidelizacion_pagina(null, null, 40, 0)
   union all select id_usuario from clientes_fidelizacion_pagina(null, null, 40, 40)) x) = least(80, (select count(*) from usuario where rol='cliente')));
select z_ok('7d. filtro segmento',
  (select coalesce(max(total_filas),0) from clientes_fidelizacion_pagina('inactivo', null, 1, 0))
   = ((resumen_fidelizacion()->'segmentos'->>'inactivo')::int));
select z_ok('7e. filtro sin correos',
  (select coalesce(max(total_filas),0) from clientes_fidelizacion_pagina('sin_correos', null, 1, 0))
   = ((resumen_fidelizacion()->>'sin_correos')::int));
select z_ok('7f. búsqueda por nombre', (select count(*) from clientes_fidelizacion_pagina(null, 'zoe tre', 10, 0)) = 1);
select z_ok('7g. límite máximo 200', (select count(*) from clientes_fidelizacion_pagina(null, null, 100000, 0)) <= 200);
select z_ok('7h. resumen: suma de segmentos = total',
  (select sum(value::int) from jsonb_each_text(resumen_fidelizacion()->'segmentos')) = (resumen_fidelizacion()->>'total')::int);
select z_ok('7i. cupones vigentes = conteo directo',
  (resumen_fidelizacion()->'cupones'->>'vigentes')::int = (select count(*) from beneficio where usado_en is null and vence_en >= hoy_uy()));

-- 8. Pestaña Clientes
select z_ok('8. clientes_panel trae números correctos', not exists (
  select 1 from clientes_panel(null, 200, 0) p
   where p.total   <> (select count(*) from reserva r where r.id_usuario=p.id_usuario and r.estado<>'cancelada')
      or p.asistio <> (select count(*) from reserva r where r.id_usuario=p.id_usuario and r.estado='completada')
      or p.fallas  <> (select count(*) from reserva r where r.id_usuario=p.id_usuario and r.estado in ('cancelada','no_asistio'))
      or p.ultima is distinct from (select max(fecha) from reserva r where r.id_usuario=p.id_usuario and r.estado='completada')
      or p.proxima is distinct from (select min(fecha) from reserva r where r.id_usuario=p.id_usuario and r.estado='confirmada' and r.fecha>=hoy_uy())));
select z_ok('8b. total_clientes', (select max(total_clientes) from clientes_panel(null, 1, 0)) = (select count(*) from usuario where rol='cliente'));
select z_ok('8c. total_filas incluye admins', (select max(total_filas) from clientes_panel(null, 1, 0)) = (select count(*) from usuario));
select z_ok('8d. buscar por correo', (select count(*) from buscar_clientes('zoe13@')) = 1);
select z_ok('8e. buscar por teléfono', exists (select 1 from buscar_clientes('099123456') where email = 'zoe13@m.com'));
select z_ok('8f. buscar devuelve 20 como mucho', (select count(*) from buscar_clientes('')) <= 20);

-- 9. Destinatarios = vista previa
select z_ok('9. destinatarios coinciden con la vista previa',
  (select count(*) from destinatarios_campana('inactivo', null, null, 300))
   = least(300, (vista_previa_campana('inactivo', null, null)->>'destinatarios')::int));
select z_ok('9b. destinatarios: todos aceptaron correos', not exists (
  select 1 from destinatarios_campana(null, null, null, 300) d join usuario u using (email) where not u.acepta_promociones));
reset role;

-- 10. Proceso diario con tope
update ajustes_fidelizacion set tope_diario = 10, dias_aviso_cumple = 30;
select z_ok('10. primer día: respeta el tope', (select ((r->>'cumpleanos')::int + (r->>'reactivacion')::int + (r->>'visitas')::int) <= 12
   and (r->>'pendientes')::int > 0 from (select fidelizacion_diaria(true) r) x),
   (select ultimo_resumen::text from ajustes_fidelizacion));
update ajustes_fidelizacion set tope_diario = 5000;
do $$ declare i int := 0; begin
  loop
    i := i + 1;
    exit when (public.fidelizacion_diaria(true)->>'pendientes')::int = 0 or i > 40;
  end loop;
end $$;
select z_ok('10b. al día siguiente se entregan los pendientes', ((select ultimo_resumen from ajustes_fidelizacion)->>'pendientes')::int = 0);
select z_ok('10c. repetir no duplica', (select (r->>'cumpleanos')::int + (r->>'reactivacion')::int + (r->>'visitas')::int from (select fidelizacion_diaria(true) r) x) = 0);
select z_ok('10d. sin cupones repetidos', not exists (select 1 from beneficio group by id_usuario, tipo, periodo having count(*) > 1));

-- 11. Tarjeta de visitas al sentar
do $$ declare u uuid; m bigint; i int; begin
  select id_usuario into u from usuario where email='zoe13@m.com';
  select id_mesa into m from mesa where estado='activa' and capacidad>=2 order by numero limit 1;
  delete from reserva where id_usuario = u;
  for i in 1..5 loop
    insert into reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas, estado) values (u, m, hoy_uy()-400-i, '20:00', 2, 'completada');
  end loop;
end $$;
delete from beneficio where id_usuario=(select id_usuario from usuario where email='zoe13@m.com') and tipo='visitas';
select z_ok('11. contar_visitas', contar_visitas((select id_usuario from usuario where email='zoe13@m.com')) = 5);
select z_ok('11b. revisar_tarjeta da el premio', revisar_tarjeta_visitas((select id_usuario from usuario where email='zoe13@m.com')));
select z_ok('11c. y no lo repite', not revisar_tarjeta_visitas((select id_usuario from usuario where email='zoe13@m.com')));

-- 12. Mantenimiento
insert into uso_ia (id_usuario, fecha) values (null, now() - interval '500 days');
select z_ok('12. mantenimiento limpia', (mantenimiento()->>'uso_ia')::int >= 1);

-- 13. Funciones SECURITY DEFINER sin search_path = 0
select z_ok('13. todas las funciones con search_path fijo', not exists (
  select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname not like 'z\_%'
     and p.prokind='f' and p.proconfig is null
     and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')),
  (select string_agg(proname, ', ') from pg_proc p where p.pronamespace='public'::regnamespace and p.proname not like 'z\_%'
     and p.prokind='f' and p.proconfig is null and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')));

select z_ok('Z. se corrieron todas las pruebas (ninguna se cortó por error)', (select count(*) from z_res) = 47, (select count(*) from z_res)::text || ' de 47');
\echo
\echo '===== RESULTADO ====='
select n, case when ok then 'OK   ' else 'FALLA' end as r, prueba, case when not ok then detalle end as detalle from z_res order by n;
select count(*) filter (where ok) as ok, count(*) filter (where not ok) as fallas from z_res;
drop table z_res; drop function z_ok(text, boolean, text); drop function z_falla(text, text, text);
