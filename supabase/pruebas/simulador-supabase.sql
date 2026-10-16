-- Simula lo mínimo de Supabase en un PostgreSQL común (para probar sin tocar el proyecto real):
-- roles anon/authenticated/service_role, auth.users, auth.uid(), net.http_post y los permisos por defecto.
-- NO correr en Supabase.
do $$ begin create role anon; exception when others then null; end $$; do $$ begin create role authenticated; exception when others then null; end $$; do $$ begin create role service_role; exception when others then null; end $$;
create schema auth;
create table auth.users (instance_id uuid, id uuid primary key, aud text, role text, email text, raw_app_meta_data jsonb, raw_user_meta_data jsonb default '{}', created_at timestamptz default now(), updated_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true),'')::uuid $$;
create schema extensions; create extension pgcrypto schema extensions;
create schema net;
create table net.log (id serial, url text, body jsonb);
create function net.http_post(url text, body jsonb, headers jsonb default '{}') returns bigint language sql as $$ insert into net.log(url,body) values (url,body) returning id $$;
grant usage on schema public, auth, net, extensions to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant all on all tables in schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
