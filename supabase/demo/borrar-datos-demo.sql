-- =========================================================
-- MAREA · Borrar TODOS los datos de demostración (sql-10 y sql-12)
-- Deja la base solo con los clientes y reservas reales.
-- Cómo usarlo: SQL Editor > New query > pegar todo > Run
-- =========================================================
delete from public.personal_dia where notas = 'demo';
delete from public.reserva where id_usuario in
  (select id_usuario from public.usuario where email like '%@demo.marea.test');
delete from auth.users where email like '%@demo.marea.test';   -- borra también sus cupones
select 'Datos de demostración borrados' as listo,
       (select count(*) from public.usuario where rol = 'cliente') as clientes_que_quedan;
