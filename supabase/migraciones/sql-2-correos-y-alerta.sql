-- =========================================================
-- PARTE A — Correos automáticos (RF5, RF7) y alerta de ocupación (RF8)
-- Cómo usarlo: Supabase > SQL Editor > New query > pegar todo > Run
-- Correrlo UNA sola vez. Después solo se cambian los valores del paso 1.
--
-- Qué hace: cada vez que pasa algo con una reserva, la base de datos
-- le avisa a n8n (un "webhook") y n8n manda el correo.
--   confirmacion        -> se creó una reserva            -> mail al cliente
--   modificacion        -> el admin cambió día/hora/mesa  -> mail al cliente
--   cancelacion_admin   -> el restaurante canceló         -> mail al cliente
--   cancelacion_cliente -> el cliente canceló             -> mail al cliente
--   alerta_ocupacion    -> se llegó al 80 % en un horario -> mail al admin
-- =========================================================

-- La extensión que permite a la base hacer pedidos a internet
create extension if not exists pg_net;

-- ---------------------------------------------------------
-- 1. CONFIGURACIÓN (tabla chiquita, invisible para la app)
-- ---------------------------------------------------------
create table if not exists public.config_app (
  clave text primary key,
  valor text
);
alter table public.config_app enable row level security;   -- sin políticas: nadie la lee desde la app

insert into public.config_app (clave, valor) values
  ('n8n_webhook_url', null),                          -- se completa cuando tengan n8n
  ('email_admin', 'correo-del-admin@ejemplo.com'),    -- a quién le llega la alerta
  ('umbral_ocupacion', '80')                          -- % que dispara la alerta
on conflict (clave) do nothing;

create or replace function public.config(p_clave text)
returns text language sql stable security definer set search_path = public as $$
  select valor from public.config_app where clave = p_clave;
$$;

-- ---------------------------------------------------------
-- 2. FUNCIÓN QUE MANDA EL AVISO A n8n
-- ---------------------------------------------------------
create or replace function public.avisar_n8n(p_datos jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_url text := public.config('n8n_webhook_url');
begin
  if v_url is null or v_url = '' then
    return;   -- todavía no hay n8n: no hace nada y la reserva sigue normal
  end if;
  perform net.http_post(
    url     := v_url,
    body    := p_datos,
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
exception when others then
  -- Si el aviso falla, la reserva NO se pierde
  raise warning 'No se pudo avisar a n8n: %', sqlerrm;
end; $$;

-- ---------------------------------------------------------
-- 3. TRIGGER: decide qué correo corresponde
-- ---------------------------------------------------------
create or replace function public.notificar_reserva()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_tipo      text;
  v_cliente   public.usuario;
  v_mesa      public.mesa;
  v_activas   int;
  v_ocupadas  int;
  v_pct       int;
begin
  -- ¿Qué pasó?
  if tg_op = 'INSERT' and new.estado = 'confirmada' then
    v_tipo := 'confirmacion';
  elsif tg_op = 'UPDATE' and old.estado <> 'cancelada' and new.estado = 'cancelada' then
    v_tipo := case when auth.uid() = new.id_usuario then 'cancelacion_cliente'
                   else 'cancelacion_admin' end;
  elsif tg_op = 'UPDATE' and new.estado = 'confirmada'
        and (old.fecha, old.hora, old.id_mesa, old.cantidad_personas)
            is distinct from (new.fecha, new.hora, new.id_mesa, new.cantidad_personas) then
    v_tipo := 'modificacion';
  else
    return new;   -- completada / no asistió: no se manda nada
  end if;

  select * into v_cliente from public.usuario where id_usuario = new.id_usuario;
  select * into v_mesa    from public.mesa    where id_mesa    = new.id_mesa;

  perform public.avisar_n8n(jsonb_build_object(
    'tipo',       v_tipo,
    'id_reserva', new.id_reserva,
    'nombre',     v_cliente.nombre,
    'email',      v_cliente.email,
    'fecha',      to_char(new.fecha, 'DD/MM/YYYY'),
    'hora',       to_char(new.hora, 'HH24:MI'),
    'personas',   new.cantidad_personas,
    'mesa',       v_mesa.numero
  ));

  -- Alerta de ocupación (RF8): se revisa al crear o mover una reserva
  if v_tipo in ('confirmacion', 'modificacion') then
    select count(*) into v_activas from public.mesa where estado = 'activa';
    select count(distinct id_mesa) into v_ocupadas
      from public.reserva
     where fecha = new.fecha
       and estado <> 'cancelada'
       and franja @> (new.fecha + new.hora);

    v_pct := case when v_activas > 0 then round(v_ocupadas * 100.0 / v_activas) else 0 end;

    if v_pct >= coalesce(public.config('umbral_ocupacion')::int, 80) then
      perform public.avisar_n8n(jsonb_build_object(
        'tipo',       'alerta_ocupacion',
        'email',      public.config('email_admin'),
        'fecha',      to_char(new.fecha, 'DD/MM/YYYY'),
        'hora',       to_char(new.hora, 'HH24:MI'),
        'ocupacion',  v_pct,
        'ocupadas',   v_ocupadas,
        'activas',    v_activas
      ));
    end if;
  end if;

  return new;
end; $$;

-- Nadie puede llamar estas funciones desde la app: solo las usa la base
revoke execute on function public.config(text)       from public, anon, authenticated;
revoke execute on function public.avisar_n8n(jsonb)  from public, anon, authenticated;

drop trigger if exists despues_de_reserva on public.reserva;
create trigger despues_de_reserva
after insert or update on public.reserva
for each row execute function public.notificar_reserva();

-- ---------------------------------------------------------
-- 4. CUANDO TENGAN EL LINK DE n8n (Production URL), correr aparte:
--   update public.config_app
--      set valor = 'https://SU-CUENTA.app.n8n.cloud/webhook/marea-reservas'
--    where clave = 'n8n_webhook_url';
--
-- Para ver si los avisos salieron bien:
--   select id, status_code, created from net._http_response order by created desc limit 10;
-- ---------------------------------------------------------
