-- =========================================================
-- PARTE A — Administradores por invitación (seguro)
-- Cómo usarlo: SQL Editor > New query > pegar todo > Run
-- (correr DESPUÉS de sql-1 a sql-7)
--
--  - Solo un admin puede invitar. La invitación llega por correo.
--  - El enlace es único, vence en 48 h, sirve una vez y solo
--    funciona con el correo invitado. Se guarda cifrado (hash).
--  - Todo cambio de rol queda registrado (auditoría).
--  - Nadie se quita el rol a sí mismo y siempre queda al menos un admin.
-- =========================================================

-- Dirección del sitio (para armar el enlace del correo)
insert into public.config_app (clave, valor)
values ('sitio_url', 'https://marea-web-sooty.vercel.app')
on conflict (clave) do nothing;

-- ---------------------------------------------------------
-- 1. INVITACIONES
-- ---------------------------------------------------------
create table if not exists public.invitacion_admin (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  token_hash  text not null unique,          -- nunca se guarda el enlace, solo su hash
  creada_por  uuid references public.usuario(id_usuario),
  creada_en   timestamptz not null default now(),
  vence_en    timestamptz not null default now() + interval '48 hours',
  usada_en    timestamptz,
  usada_por   uuid references public.usuario(id_usuario),
  revocada    boolean not null default false
);
alter table public.invitacion_admin enable row level security;

drop policy if exists "admin ve invitaciones" on public.invitacion_admin;
create policy "admin ve invitaciones" on public.invitacion_admin
  for select to authenticated using (public.es_admin());
-- (no hay políticas de insert/update: solo se tocan con las funciones de abajo)

-- ---------------------------------------------------------
-- 2. AUDITORÍA DE ROLES
-- ---------------------------------------------------------
create table if not exists public.registro_roles (
  id            bigint generated always as identity primary key,
  id_usuario    uuid not null references public.usuario(id_usuario) on delete cascade,
  rol_anterior  text,
  rol_nuevo     text not null,
  cambiado_por  uuid,                         -- null = cambiado desde Supabase (SQL)
  fecha         timestamptz not null default now()
);
alter table public.registro_roles enable row level security;

drop policy if exists "admin ve registro de roles" on public.registro_roles;
create policy "admin ve registro de roles" on public.registro_roles
  for select to authenticated using (public.es_admin());

create or replace function public.auditar_rol()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.rol is distinct from old.rol then
    insert into public.registro_roles (id_usuario, rol_anterior, rol_nuevo, cambiado_por)
    values (new.id_usuario, old.rol, new.rol, auth.uid());
  end if;
  return new;
end; $$;

drop trigger if exists al_cambiar_rol on public.usuario;
create trigger al_cambiar_rol
after update of rol on public.usuario
for each row execute function public.auditar_rol();

-- ---------------------------------------------------------
-- 3. FUNCIONES
-- ---------------------------------------------------------

-- Invitar (solo admins). El enlace viaja solo por correo.
create or replace function public.invitar_admin(p_email text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email    text := lower(trim(p_email));
  v_token    text;
  v_vence    timestamptz := now() + interval '48 hours';
  v_quien    public.usuario;
  v_invitado public.usuario;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede invitar.';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Escribí un correo válido.';
  end if;
  select * into v_invitado from public.usuario where lower(email) = v_email;
  if v_invitado.rol = 'admin' then
    raise exception 'Esa persona ya es administradora.';
  end if;
  if (select count(*) from public.invitacion_admin
       where usada_en is null and not revocada and vence_en > now()) >= 10 then
    raise exception 'Hay demasiadas invitaciones pendientes. Revocá alguna antes de invitar.';
  end if;

  -- Una sola invitación activa por correo
  update public.invitacion_admin set revocada = true
   where lower(email) = v_email and usada_en is null and not revocada;

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into public.invitacion_admin (email, token_hash, creada_por, vence_en)
  values (v_email, encode(digest(v_token, 'sha256'), 'hex'), auth.uid(), v_vence);

  select * into v_quien from public.usuario where id_usuario = auth.uid();
  perform public.avisar_n8n(jsonb_build_object(
    'tipo',          'invitacion_admin',
    'email',         v_email,
    'nombre',        coalesce(v_invitado.nombre, ''),
    'invitado_por',  coalesce(nullif(v_quien.nombre, ''), 'Un administrador'),
    'enlace',        public.config('sitio_url') || '/invitacion.html?token=' || v_token,
    'vence',         to_char(v_vence at time zone 'America/Montevideo', 'DD/MM/YYYY "a las" HH24:MI')
  ));

  return jsonb_build_object('email', v_email, 'vence_en', v_vence);
end; $$;

-- Aceptar (la persona invitada, con sesión iniciada con ESE correo)
create or replace function public.aceptar_invitacion(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_inv   public.invitacion_admin;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'Iniciá sesión para aceptar la invitación.';
  end if;
  select lower(email) into v_email from auth.users where id = auth.uid();

  select * into v_inv from public.invitacion_admin
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');

  if v_inv.id is null or v_inv.revocada then
    raise exception 'La invitación no es válida o fue revocada.';
  end if;
  if v_inv.usada_en is not null then
    raise exception 'Esta invitación ya se usó.';
  end if;
  if v_inv.vence_en < now() then
    raise exception 'La invitación venció. Pedile a un administrador que te invite de nuevo.';
  end if;
  if lower(v_inv.email) <> v_email then
    raise exception 'Esta invitación es para %. Entrá con esa cuenta.', v_inv.email;
  end if;

  update public.usuario set rol = 'admin' where id_usuario = auth.uid();
  update public.invitacion_admin set usada_en = now(), usada_por = auth.uid() where id = v_inv.id;
  return jsonb_build_object('ok', true);
end; $$;

-- Revocar una invitación pendiente (solo admins)
create or replace function public.revocar_invitacion(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede revocar invitaciones.';
  end if;
  update public.invitacion_admin set revocada = true
   where id = p_id and usada_en is null;
end; $$;

-- Quitar el rol de admin (solo admins, nunca a uno mismo, nunca el último)
create or replace function public.quitar_admin(p_id_usuario uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede hacer esto.';
  end if;
  if p_id_usuario = auth.uid() then
    raise exception 'No podés quitarte el rol a vos mismo/a. Pedíselo a otro administrador.';
  end if;
  if (select count(*) from public.usuario where rol = 'admin') <= 1 then
    raise exception 'Tiene que quedar al menos un administrador.';
  end if;
  update public.usuario set rol = 'cliente' where id_usuario = p_id_usuario and rol = 'admin';
end; $$;

revoke execute on function public.invitar_admin(text) from public, anon;
revoke execute on function public.revocar_invitacion(uuid) from public, anon;
revoke execute on function public.quitar_admin(uuid) from public, anon;
revoke execute on function public.aceptar_invitacion(text) from public, anon;
grant execute on function public.invitar_admin(text) to authenticated;
grant execute on function public.revocar_invitacion(uuid) to authenticated;
grant execute on function public.quitar_admin(uuid) to authenticated;
grant execute on function public.aceptar_invitacion(text) to authenticated;

-- ---------------------------------------------------------
-- 4. CORREO DE INVITACIÓN (se agrega al armado de correos)
-- ---------------------------------------------------------
create or replace function public.avisar_n8n(p_datos jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_url      text := public.config('n8n_webhook_url');
  d          jsonb := p_datos;
  v_nombre   text := split_part(coalesce(p_datos->>'nombre', ''), ' ', 1);
  v_personas text := (p_datos->>'personas') ||
                     case when p_datos->>'personas' = '1' then ' persona' else ' personas' end;
  v_detalle  text;
  v_asunto   text;
  v_titulo   text;
  v_cuerpo   text;
  v_html     text;
begin
  if v_url is null or v_url = '' then
    return;   -- todavía no hay automatización conectada
  end if;

  v_detalle := format(
    '<table style="margin:18px 0;border-collapse:collapse">'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Día</td><td><b>%s</b></td></tr>'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Horario</td><td><b>%s</b></td></tr>'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Personas</td><td><b>%s</b></td></tr>'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Reserva n.º</td><td><b>%s</b></td></tr>'
    '</table>',
    d->>'fecha', (d->>'hora') || coalesce(' a ' || (d->>'hasta') || ' h', ''), v_personas, d->>'id_reserva');

  case d->>'tipo'
    when 'confirmacion' then
      v_asunto := format('Tu mesa en Marea está confirmada · %s %s', d->>'fecha', d->>'hora');
      v_titulo := format('¡Te esperamos, %s!', v_nombre);
      v_cuerpo := 'Tu reserva quedó confirmada.' || v_detalle ||
                  'Si no podés venir, cancelala desde <b>Mis reservas</b> así liberamos la mesa.';
    when 'modificacion' then
      v_asunto := format('Cambiamos tu reserva en Marea · %s %s', d->>'fecha', d->>'hora');
      v_titulo := format('Hola, %s', v_nombre);
      v_cuerpo := 'El restaurante actualizó tu reserva. Estos son los datos nuevos:' || v_detalle ||
                  'Cualquier duda, respondé este correo.';
    when 'cancelacion_admin' then
      v_asunto := 'Tu reserva en Marea fue cancelada';
      v_titulo := format('Hola, %s', v_nombre);
      v_cuerpo := 'Lamentamos avisarte que el restaurante tuvo que cancelar tu reserva:' || v_detalle ||
                  'Podés elegir otro día u horario desde nuestra web. Disculpá las molestias.';
    when 'cancelacion_cliente' then
      v_asunto := 'Cancelaste tu reserva en Marea';
      v_titulo := format('Hola, %s', v_nombre);
      v_cuerpo := 'Recibimos la cancelación de tu reserva:' || v_detalle || '¡Ojalá te veamos pronto!';
    when 'alerta_ocupacion' then
      v_asunto := format('Alerta: ocupación del %s%% · %s %s', d->>'ocupacion', d->>'fecha', d->>'hora');
      v_titulo := 'Ocupación alta';
      v_cuerpo := format('El <b>%s</b> a las <b>%s</b> hay <b>%s de %s</b> mesas reservadas (<b>%s%%</b>).'
                         '<br><br>Quedan %s mesas libres en ese horario.',
                         d->>'fecha', d->>'hora', d->>'ocupadas', d->>'activas', d->>'ocupacion',
                         (d->>'activas')::int - (d->>'ocupadas')::int);
    when 'invitacion_admin' then
      v_asunto := 'Te invitaron a administrar Marea';
      v_titulo := format('Hola, %s', coalesce(nullif(v_nombre, ''), 'equipo'));
      v_cuerpo := format(
        '%s te invitó a ser <b>administrador/a</b> del sistema de reservas de Marea.'
        '<br><br><a href="%s" style="display:inline-block;background:#0e2a47;color:#ffffff;'
        'text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:bold">Aceptar invitación</a>'
        '<br><br><span style="color:#6b7785;font-size:13px">El enlace sirve una sola vez, vence el %s '
        'y solo funciona con esta dirección de correo. Si no esperabas esta invitación, ignorá este correo.</span>',
        d->>'invitado_por', d->>'enlace', d->>'vence');
    else
      return;
  end case;

  v_html := format(
    '<div style="background:#f6efe2;padding:32px 12px;font-family:Arial,sans-serif;color:#1b2733">'
    '<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden">'
    '<div style="background:#0e2a47;color:#fff;padding:22px 28px;font-family:Georgia,serif;font-size:22px;letter-spacing:6px">MAREA</div>'
    '<div style="padding:28px"><h2 style="font-family:Georgia,serif;font-weight:normal;color:#0e2a47;margin:0 0 12px">%s</h2>'
    '<div style="line-height:1.55">%s</div></div>'
    '<div style="padding:16px 28px;background:#f6efe2;color:#6b7785;font-size:12px">Marea · Costa atlántica uruguaya · Cenas de 19 a 00 h</div>'
    '</div></div>', v_titulo, v_cuerpo);

  perform net.http_post(
    url     := v_url,
    body    := d || jsonb_build_object('asunto', v_asunto, 'html', v_html,
                                    'secreto', public.config('webhook_secreto')),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
exception when others then
  raise warning 'No se pudo avisar a la automatización: %', sqlerrm;
end; $$;




revoke execute on function public.avisar_n8n(jsonb) from public, anon, authenticated;
