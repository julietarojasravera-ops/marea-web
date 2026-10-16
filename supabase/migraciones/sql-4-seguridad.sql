-- =========================================================
-- PARTE A — Mejoras de seguridad
-- Cómo usarlo: SQL Editor > New query > pegar todo > Run
-- (correr DESPUÉS de sql-1, sql-2 y sql-3)
--
--  1. Límite de 3 reservas futuras activas por cliente (evita abuso)
--  2. Secreto del webhook: Make solo envía correos si el aviso trae
--     la contraseña correcta (evita correos falsos desde Marea)
--  3. Consentimiento de privacidad (Ley 18.331): se guarda la fecha
--     en que cada usuario aceptó la política al registrarse
-- =========================================================

-- ---------------------------------------------------------
-- 1. LÍMITE DE RESERVAS POR CLIENTE
-- ---------------------------------------------------------
insert into public.config_app (clave, valor) values ('max_reservas_cliente', '3')
on conflict (clave) do nothing;

create or replace function public.crear_reserva(p_fecha date, p_hora time, p_personas int)
returns public.reserva language plpgsql security definer set search_path = public as $$
declare
  v_mesa    bigint;
  v_reserva public.reserva;
  v_activas int;
  v_maximo  int := coalesce(public.config('max_reservas_cliente')::int, 3);
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión para reservar';
  end if;
  if (p_fecha + p_hora) < (now() at time zone 'America/Montevideo') then
    raise exception 'No se puede reservar en una fecha u hora que ya pasó';
  end if;

  select count(*) into v_activas
    from public.reserva
   where id_usuario = auth.uid()
     and estado = 'confirmada'
     and (fecha + hora) >= (now() at time zone 'America/Montevideo');
  if v_activas >= v_maximo then
    raise exception 'Ya tenés % reservas próximas. Cancelá alguna para hacer otra.', v_maximo;
  end if;

  select id_mesa into v_mesa
  from public.mesas_disponibles(p_fecha, p_hora, p_personas)
  limit 1;

  if v_mesa is null then
    raise exception 'No hay mesas disponibles para ese día, hora y cantidad de personas';
  end if;

  insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas)
  values (auth.uid(), v_mesa, p_fecha, p_hora, p_personas)
  returning * into v_reserva;

  return v_reserva;
end; $$;

-- ---------------------------------------------------------
-- 2. SECRETO DEL WEBHOOK
-- Se genera una contraseña al azar. Para verla (y copiarla en Make):
--   select valor from public.config_app where clave = 'webhook_secreto';
-- ---------------------------------------------------------
insert into public.config_app (clave, valor)
values ('webhook_secreto', replace(gen_random_uuid()::text, '-', ''))
on conflict (clave) do nothing;

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
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Hora</td><td><b>%s</b></td></tr>'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Personas</td><td><b>%s</b></td></tr>'
    '<tr><td style="padding:4px 16px 4px 0;color:#6b7785">Reserva n.º</td><td><b>%s</b></td></tr>'
    '</table>',
    d->>'fecha', d->>'hora', v_personas, d->>'id_reserva');

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

-- ---------------------------------------------------------
-- 3. CONSENTIMIENTO DE PRIVACIDAD (Ley 18.331)
-- ---------------------------------------------------------
alter table public.usuario add column if not exists fecha_acepta_privacidad timestamptz;

create or replace function public.crear_usuario_nuevo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.usuario (id_usuario, nombre, email, fecha_acepta_privacidad)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nombre', ''),
    new.email,
    case when new.raw_user_meta_data->>'acepta_privacidad' = 'si' then now() end
  );
  return new;
end; $$;
