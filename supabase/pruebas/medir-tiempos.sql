-- Mide cuánto tarda cada operación del panel. Base de PRUEBA (no Supabase).
\set QUIET on
\pset pager off
\pset tuples_only on
do $$ begin
  if not exists (select 1 from public.usuario where email='admin.bench@prueba.test') then
    set local session_replication_role = replica;
    insert into public.usuario (id_usuario, nombre, email, rol) values ('00000000-0000-0000-0000-00000000ad01','Admin','admin.bench@prueba.test','admin');
  end if; end $$;
set statement_timeout = '60s';
create temp table t (n serial, que text, ms numeric);
create or replace function pg_temp.medir(p text, q text, veces int default 3) returns void language plpgsql as $$
declare t0 timestamptz; mejor numeric := 1e12; i int; x numeric;
begin
  for i in 1..veces loop
    t0 := clock_timestamp(); execute q; x := extract(epoch from clock_timestamp() - t0) * 1000;
    mejor := least(mejor, x);
  end loop;
  insert into t (que, ms) values (p, round(mejor, 1));
exception when others then insert into t (que, ms) values (p || ' [' || left(sqlerrm, 40) || ']', -1);
end $$;
select set_config('test.uid', '00000000-0000-0000-0000-00000000ad01', false);
select pg_temp.medir('Segmentación completa (datos_clientes)', 'select count(*) from public.datos_clientes()');
select pg_temp.medir('Fidelización: resumen de segmentos', 'select public.resumen_fidelizacion()');
select pg_temp.medir('Fidelización: página de 50 (todos)', 'select count(*) from public.clientes_fidelizacion_pagina(null, null, 50, 0)');
select pg_temp.medir('Fidelización: página 50 de VIP', 'select count(*) from public.clientes_fidelizacion_pagina(''vip'', null, 50, 0)');
select pg_temp.medir('Vista previa de campaña', 'select public.vista_previa_campana(null, null, null)');
select pg_temp.medir('Destinatarios (100)', 'select count(*) from public.destinatarios_campana(''inactivo'', null, null, 100)');
select pg_temp.medir('Resumen para la IA', 'select public.resumen_para_ia(null, null, null)', 1);
select pg_temp.medir('Clientes: página de 50', 'select count(*) from public.clientes_panel(null, 50, 0)');
select pg_temp.medir('Clientes: búsqueda "cliente 77"', 'select count(*) from public.clientes_panel(''cliente 77'', 50, 0)');
select pg_temp.medir('Nueva reserva: buscar cliente', 'select count(*) from public.buscar_clientes(''cliente 123'')');
select pg_temp.medir('Clima: historial 107 noches', 'select count(*) from public.historial_noches(public.hoy_uy() - 91, public.hoy_uy() + 15)');
select pg_temp.medir('Disponibilidad (estado_mesas)', 'select count(*) from public.estado_mesas(public.hoy_uy() + 3, ''21:00'', 4)');
select set_config('test.uid', (select id_usuario::text from public.usuario where email='carga.77@prueba.test'), false);
select pg_temp.medir('Cliente: Mis reservas (mi_fidelizacion)', 'select public.mi_fidelizacion()');
select pg_temp.medir('Al sentar: tarjeta de visitas', 'select public.revisar_tarjeta_visitas((select id_usuario from public.usuario where email=''carga.78@prueba.test''))');
select set_config('test.uid', '', false);
update public.ajustes_fidelizacion set tope_diario = 5000;
select pg_temp.medir('Proceso diario (primera vez, tope 5000)', 'select public.fidelizacion_diaria(true)', 1);
select pg_temp.medir('Proceso diario (día siguiente)', 'select public.fidelizacion_diaria(true)', 1);
\pset tuples_only off
select que as "operación", ms as "ms" from t order by n;
