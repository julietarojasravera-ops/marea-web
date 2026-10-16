-- =========================================================
-- MAREA · INSTALACIÓN COMPLETA (versión 13)
-- Sistema inteligente de reservas y fidelización para restaurantes
--
-- PARA QUÉ SIRVE
--   Deja un proyecto de Supabase NUEVO (vacío) igual al de Marea en un
--   solo paso: tablas, reglas de seguridad, funciones, índices, correos
--   y tareas automáticas. Reemplaza a correr sql-1 … sql-13 en orden.
--   (Si tu proyecto YA tiene Marea instalado, no uses este archivo:
--    corré solo los scripts de "migraciones" que te falten.)
--
-- CÓMO SE USA
--   1. Supabase > Database > Extensions: activar pg_net y pg_cron.
--   2. SQL Editor > New query > pegar todo este archivo > Run.
--   3. Completar la configuración (sección "AL FINAL", más abajo).
--   4. Crear el primer administrador (ver README).
--
-- CÓMO SE GENERÓ
--   Automáticamente, a partir de una base armada con sql-1 … sql-13 y
--   verificada con las pruebas (pruebas/test13.sql). Por eso usa el
--   formato estándar de PostgreSQL (pg_dump). Generado el 15/10/2026.
-- =========================================================

-- Extensiones que usa Marea
create extension if not exists btree_gist;                       -- reglas de "mesa no superpuesta"
create extension if not exists pg_net;                           -- avisos a Make (correos)
create extension if not exists pg_trgm with schema extensions;   -- búsqueda por texto

--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

--
-- Name: aceptar_invitacion(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.aceptar_invitacion(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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

--
-- Name: al_aceptar_correos(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.al_aceptar_correos() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare a public.ajustes_fidelizacion;
begin
  if new.rol = 'cliente' and new.acepta_promociones
     and (tg_op = 'INSERT' or not coalesce(old.acepta_promociones, false)) then
    select * into a from public.ajustes_fidelizacion where id = 1;
    perform public.dar_beneficio(new.id_usuario, 'bienvenida', 'unica', a.beneficio_bienvenida,
                                 public.hoy_uy() + a.vigencia_dias);
  end if;
  return new;
end; $$;

--
-- Name: al_sumar_visita(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.al_sumar_visita() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.estado in ('sentada', 'completada') and old.estado not in ('sentada', 'completada') then
    perform public.revisar_tarjeta_visitas(new.id_usuario);
  end if;
  return new;
end; $$;

--
-- Name: auditar_rol(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auditar_rol() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.rol is distinct from old.rol then
    insert into public.registro_roles (id_usuario, rol_anterior, rol_nuevo, cambiado_por)
    values (new.id_usuario, old.rol, new.rol, auth.uid());
  end if;
  return new;
end; $$;

--
-- Name: avisar_cliente_sin_correos(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.avisar_cliente_sin_correos() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  u public.usuario;
  a public.ajustes_fidelizacion;
begin
  if new.estado <> 'confirmada' or new.fecha < public.hoy_uy() then
    return new;
  end if;
  select * into u from public.usuario where id_usuario = new.id_usuario;
  select * into a from public.ajustes_fidelizacion where id = 1;
  if u.rol = 'cliente' and not u.acepta_promociones and a.aviso_sin_correos then
    perform public.avisar_n8n(jsonb_build_object(
      'tipo',                 'cliente_sin_correos',
      'email',                public.config('email_admin'),
      'cliente',              u.nombre,
      'id_reserva',           new.id_reserva,
      'fecha',                to_char(new.fecha, 'DD/MM/YYYY'),
      'hora',                 to_char(new.hora, 'HH24:MI'),
      'personas',             new.cantidad_personas,
      'beneficio_bienvenida', a.beneficio_bienvenida
    ));
  end if;
  return new;
end; $$;

--
-- Name: avisar_n8n(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.avisar_n8n(p_datos jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_url      text := public.config('n8n_webhook_url');
  v_sitio    text := coalesce(public.config('sitio_url'), '');
  d          jsonb := p_datos;
  v_nombre   text := public.html_seguro(split_part(coalesce(p_datos->>'nombre', ''), ' ', 1));
  v_personas text := (p_datos->>'personas') ||
                     case when p_datos->>'personas' = '1' then ' persona' else ' personas' end;
  v_detalle  text;
  v_cupon    text := '';
  v_boton    text;
  v_pie      text := 'Marea · Costa atlántica uruguaya · Cenas de 19 a 00 h';
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

  if d ? 'codigo' then
    v_cupon := format(
      '<div style="margin:22px 0;padding:20px;border:2px dashed #b08d57;border-radius:14px;text-align:center">'
      '<div style="font-size:12px;color:#6b7785;letter-spacing:3px">TU BENEFICIO</div>'
      '<div style="font-family:Georgia,serif;font-size:21px;color:#0e2a47;margin:8px 0 12px">%s</div>'
      '<div style="font-family:monospace;font-size:22px;letter-spacing:3px;color:#0e2a47;background:#f6efe2;'
      'display:inline-block;padding:8px 16px;border-radius:8px">%s</div>'
      '<div style="font-size:13px;color:#6b7785;margin-top:10px">Válido hasta el %s · Mostrá el código al llegar</div>'
      '</div>',
      public.html_seguro(d->>'descripcion'), public.html_seguro(d->>'codigo'), d->>'vence');
  end if;
  v_boton := format(
    '<a href="%s/reservar.html" style="display:inline-block;background:#0e2a47;color:#ffffff;'
    'text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:bold">Reservar mi mesa</a>',
    v_sitio);

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
        public.html_seguro(d->>'invitado_por'), d->>'enlace', d->>'vence');
    when 'beneficio_cumpleanos' then
      v_asunto := format('¡Feliz cumpleaños, %s! Tenés un regalo en Marea', split_part(coalesce(d->>'nombre', ''), ' ', 1));
      v_titulo := 'Se viene tu cumpleaños';
      v_cuerpo := format('Hola, %s. Sabemos que el <b>%s</b> es tu día y queremos festejarlo con vos. '
                         'Reservá tu mesa para esa semana y te esperamos con:', v_nombre, d->>'cumple')
                  || v_cupon || v_boton;
    when 'beneficio_reactivacion' then
      v_asunto := format('%s, te extrañamos en Marea', split_part(coalesce(d->>'nombre', ''), ' ', 1));
      v_titulo := 'Hace rato que no te vemos';
      v_cuerpo := format('Hola, %s. El mar sigue ahí, la parrilla también, y tu mesa te está esperando. '
                         'Para que vuelvas, te guardamos esto:', v_nombre)
                  || v_cupon || v_boton;
    when 'beneficio_visitas' then
      v_asunto := 'Completaste tu tarjeta de visitas: tenés un regalo en Marea';
      v_titulo := format('Gracias, %s', v_nombre);
      v_cuerpo := format('Ya son <b>%s visitas</b> a Marea y queremos agradecértelo. '
                         'En tu próxima cena te espera:', coalesce(d->>'visitas', 'varias'))
                  || v_cupon || v_boton;
    when 'beneficio_bienvenida' then
      v_asunto := format('Bienvenido/a a los beneficios de Marea, %s', split_part(coalesce(d->>'nombre', ''), ' ', 1));
      v_titulo := format('¡Gracias por sumarte, %s!', v_nombre);
      v_cuerpo := 'Desde ahora te vamos a avisar las novedades de la semana, las promociones exclusivas '
                  'y los regalos que te esperan. Para empezar, te guardamos esto:'
                  || v_cupon || v_boton;
    when 'cliente_sin_correos' then
      v_asunto := format('Reservó %s y todavía no recibe beneficios · %s %s',
                         coalesce(d->>'cliente', 'un cliente'), d->>'fecha', d->>'hora');
      v_titulo := 'Invitalo a sumarse a los beneficios';
      v_cuerpo := format('<b>%s</b> reservó y todavía <b>no aceptó recibir correos</b> de Marea.',
                         public.html_seguro(d->>'cliente'))
                  || v_detalle ||
                  format('Cuando llegue, contale lo que gana si se suma: <b>%s</b>, promociones exclusivas '
                         'y las novedades de la semana. Lo activa en un toque desde <b>Mi perfil</b> en la web.',
                         public.html_seguro(d->>'beneficio_bienvenida'));
    when 'campana' then
      v_asunto := coalesce(d->>'asunto_campana', 'Novedades de Marea');
      v_titulo := format('Hola, %s', coalesce(nullif(v_nombre, ''), 'amigo de Marea'));
      v_cuerpo := public.html_seguro(d->>'mensaje') || v_cupon || '<br>' || v_boton;
    else
      return;
  end case;

  if d->>'tipo' like 'beneficio_%' or d->>'tipo' = 'campana' then
    v_pie := v_pie || '<br>Recibís este correo porque aceptaste recibir beneficios de Marea. '
             || format('Podés desactivarlo cuando quieras desde <a href="%s/perfil.html" style="color:#6b7785">Mi perfil</a>.', v_sitio);
  end if;

  v_html := format(
    '<div style="background:#f6efe2;padding:32px 12px;font-family:Arial,sans-serif;color:#1b2733">'
    '<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden">'
    '<div style="background:#0e2a47;color:#fff;padding:22px 28px;font-family:Georgia,serif;font-size:22px;letter-spacing:6px">MAREA</div>'
    '<div style="padding:28px"><h2 style="font-family:Georgia,serif;font-weight:normal;color:#0e2a47;margin:0 0 12px">%s</h2>'
    '<div style="line-height:1.55">%s</div></div>'
    '<div style="padding:16px 28px;background:#f6efe2;color:#6b7785;font-size:12px;line-height:1.5">%s</div>'
    '</div></div>', v_titulo, v_cuerpo, v_pie);

  perform net.http_post(
    url     := v_url,
    body    := d || jsonb_build_object('asunto', v_asunto, 'html', v_html,
                                    'secreto', public.config('webhook_secreto')),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
exception when others then
  raise warning 'No se pudo avisar a la automatización: %', sqlerrm;
end; $$;

--
-- Name: buscar_clientes(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.buscar_clientes(p_texto text, p_limite integer DEFAULT 20) RETURNS TABLE(id_usuario uuid, nombre text, email text, telefono text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v text := lower(trim(coalesce(p_texto, '')));
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede buscar clientes';
  end if;
  return query
    select u.id_usuario, u.nombre, u.email, u.telefono
      from public.usuario u
     where v = ''
        or lower(u.nombre || ' ' || u.email) like '%' || v || '%'
        -- si escribió solo números, busca también por teléfono
        or (v ~ '^[0-9 +()-]{4,}$'
            and regexp_replace(coalesce(u.telefono, ''), '\D', '', 'g') like '%' || regexp_replace(v, '\D', '', 'g') || '%')
     order by u.nombre, u.email
     limit least(greatest(coalesce(p_limite, 20), 1), 50);
end; $_$;

--
-- Name: cancelar_mi_reserva(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cancelar_mi_reserva(p_id_reserva bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  update public.reserva
  set estado = 'cancelada'
  where id_reserva = p_id_reserva
    and id_usuario = auth.uid()
    and estado = 'confirmada';
  if not found then
    raise exception 'No se encontró una reserva tuya para cancelar';
  end if;
end; $$;

--
-- Name: canjear_beneficio(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.canjear_beneficio(p_codigo text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  b public.beneficio;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede canjear cupones';
  end if;
  select * into b from public.beneficio where codigo = upper(trim(p_codigo)) for update;
  if not found then
    raise exception 'No existe un beneficio con ese código';
  end if;
  if b.usado_en is not null then
    raise exception 'Ese beneficio ya se usó el %', to_char(b.usado_en at time zone 'America/Montevideo', 'DD/MM/YYYY');
  end if;
  if b.vence_en < public.hoy_uy() then
    raise exception 'Ese beneficio venció el %', to_char(b.vence_en, 'DD/MM/YYYY');
  end if;
  update public.beneficio set usado_en = now(), usado_por = auth.uid()
   where id_beneficio = b.id_beneficio;
  return public.consultar_beneficio(p_codigo);
end; $$;

--
-- Name: cierre_de(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cierre_de(p_fecha date) RETURNS timestamp without time zone
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select p_fecha + a.cierre + case when a.cierre <= a.apertura then interval '1 day' else interval '0' end
    from public.ajustes_reserva a where a.id = 1;
$$;

--
-- Name: clientes_de_campana(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clientes_de_campana(p_segmento text, p_zona text, p_grupo text) RETURNS SETOF uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select d.id_usuario
    from public.datos_clientes() d
   where (p_segmento is null or d.segmento = p_segmento)
     and (p_zona is null or d.zona_favorita = p_zona)
     and (p_grupo is null
          or (p_grupo = 'pareja' and d.grupo_habitual <= 2)
          or (p_grupo = 'grupo'  and d.grupo_habitual >= 4));
$$;

--
-- Name: clientes_fidelizacion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clientes_fidelizacion() RETURNS TABLE(id_usuario uuid, nombre text, email text, telefono text, fecha_nacimiento date, acepta_promociones boolean, cliente_desde date, visitas integer, visitas_12m integer, ultima_visita date, dias_sin_venir integer, proxima_reserva date, cancelaciones integer, no_asistio integer, zona_favorita text, dia_favorito integer, horario_favorito text, grupo_habitual integer, ocasiones text[], proximo_cumple date, dias_para_cumple integer, segmento text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver la segmentación';
  end if;
  return query select * from public.datos_clientes();
end; $$;

--
-- Name: clientes_fidelizacion_pagina(text, text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clientes_fidelizacion_pagina(p_segmento text DEFAULT NULL::text, p_buscar text DEFAULT NULL::text, p_limite integer DEFAULT 50, p_desde integer DEFAULT 0) RETURNS TABLE(id_usuario uuid, nombre text, email text, telefono text, fecha_nacimiento date, acepta_promociones boolean, cliente_desde date, visitas integer, visitas_12m integer, ultima_visita date, dias_sin_venir integer, proxima_reserva date, cancelaciones integer, no_asistio integer, zona_favorita text, dia_favorito integer, horario_favorito text, grupo_habitual integer, ocasiones text[], proximo_cumple date, dias_para_cumple integer, segmento text, total_filas bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_seg    text := nullif(trim(p_segmento), '');
  v_buscar text := '%' || lower(coalesce(trim(p_buscar), '')) || '%';
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver la segmentación';
  end if;
  return query
    select d.*, count(*) over ()
      from public.datos_clientes() d
     where (v_seg is null
            or (v_seg = 'sin_correos' and not d.acepta_promociones)
            or d.segmento = v_seg)
       and lower(coalesce(d.nombre, '') || ' ' || d.email) like v_buscar
     order by d.visitas_12m desc, d.visitas desc, d.nombre
     limit least(greatest(coalesce(p_limite, 50), 1), 200)
    offset greatest(coalesce(p_desde, 0), 0);
end; $$;

--
-- Name: clientes_panel(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clientes_panel(p_buscar text DEFAULT NULL::text, p_limite integer DEFAULT 50, p_desde integer DEFAULT 0) RETURNS TABLE(id_usuario uuid, nombre text, email text, telefono text, rol text, fecha_creacion timestamp with time zone, total integer, asistio integer, fallas integer, ultima date, proxima date, total_filas bigint, total_clientes bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_hoy    date := public.hoy_uy();
  v_buscar text := lower(coalesce(trim(p_buscar), ''));
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver los clientes';
  end if;
  return query
    with elegidos as (
      select u.*, count(*) over () as total_filas
        from public.usuario u
       where v_buscar = '' or lower(u.nombre || ' ' || u.email) like '%' || v_buscar || '%'
       order by u.nombre, u.email
       limit least(greatest(coalesce(p_limite, 50), 1), 200)
      offset greatest(coalesce(p_desde, 0), 0)
    )
    select e.id_usuario, e.nombre, e.email, e.telefono, e.rol, e.fecha_creacion,
           coalesce(x.total, 0), coalesce(x.asistio, 0), coalesce(x.fallas, 0),
           x.ultima, x.proxima, e.total_filas,
           (select count(*) from public.usuario c where c.rol = 'cliente')
      from elegidos e
      left join lateral (
        select count(*) filter (where r.estado <> 'cancelada')::int                    as total,
               count(*) filter (where r.estado = 'completada')::int                    as asistio,
               count(*) filter (where r.estado in ('cancelada', 'no_asistio'))::int    as fallas,
               max(r.fecha) filter (where r.estado = 'completada')                     as ultima,
               min(r.fecha) filter (where r.estado = 'confirmada' and r.fecha >= v_hoy) as proxima
          from public.reserva r
         where r.id_usuario = e.id_usuario
      ) x on true
     order by e.nombre, e.email;
end; $$;

--
-- Name: config(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.config(p_clave text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select valor from public.config_app where clave = p_clave;
$$;

--
-- Name: consultar_beneficio(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consultar_beneficio(p_codigo text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  b public.beneficio;
  u public.usuario;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede consultar cupones';
  end if;
  select * into b from public.beneficio where codigo = upper(trim(p_codigo));
  if not found then
    raise exception 'No existe un beneficio con ese código';
  end if;
  select * into u from public.usuario where id_usuario = b.id_usuario;
  return jsonb_build_object(
    'codigo', b.codigo, 'descripcion', b.descripcion, 'tipo', b.tipo,
    'cliente', u.nombre, 'email', u.email,
    'vence', b.vence_en, 'usado_en', b.usado_en,
    'estado', case when b.usado_en is not null then 'usado'
                   when b.vence_en < public.hoy_uy() then 'vencido'
                   else 'vigente' end);
end; $$;

--
-- Name: consultar_turno(date, time without time zone, integer, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consultar_turno(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_motivo text;
  v_dur    int := public.duracion_para(p_personas);
  v_hasta  time := p_hora + v_dur * interval '1 minute';
  v_mesa   public.mesa;
begin
  if (p_fecha + p_hora) < (now() at time zone 'America/Montevideo') then
    return jsonb_build_object('disponible', false, 'motivo', 'Ese horario ya pasó.');
  end if;
  if not exists (select 1 from public.mesa
                  where estado = 'activa' and public.mesa_sirve(capacidad, p_personas)) then
    return jsonb_build_object('disponible', false, 'grupo_grande', true,
      'motivo', format('No tenemos mesas para %s personas. Para grupos grandes escribinos a mareareservasuy@gmail.com.', p_personas));
  end if;
  v_motivo := public.motivo_turno(p_fecha, p_hora, p_personas);
  if v_motivo is not null then
    return jsonb_build_object('disponible', false, 'motivo', v_motivo);
  end if;

  if p_id_mesa is not null then
    select * into v_mesa from public.mesa where id_mesa = p_id_mesa;
    if not public.mesa_sirve(v_mesa.capacidad, p_personas) then
      return jsonb_build_object('disponible', false,
        'motivo', format('La mesa %s es para %s personas. Para %s te damos una mesa más justa: elegí otra.',
                         v_mesa.numero, v_mesa.capacidad, p_personas));
    end if;
    if not exists (select 1 from public.mesas_disponibles(p_fecha, p_hora, p_personas) d
                    where d.id_mesa = p_id_mesa) then
      return jsonb_build_object('disponible', false,
        'motivo', format('La mesa %s no está libre a esa hora.', v_mesa.numero));
    end if;
  elsif not exists (select 1 from public.mesas_disponibles(p_fecha, p_hora, p_personas)) then
    return jsonb_build_object('disponible', false,
      'motivo', format('No quedan mesas para %s personas a esa hora.', p_personas));
  end if;

  return jsonb_build_object('disponible', true,
    'duracion_min', v_dur,
    'duracion_texto', public.texto_duracion(v_dur),
    'hasta', to_char(v_hasta, 'HH24:MI'),
    'mesa', v_mesa.numero,
    'zona', v_mesa.zona);
end; $$;

--
-- Name: contar_visitas(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contar_visitas(p_usuario uuid) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select count(*)::int from public.reserva
   where id_usuario = p_usuario
     and (estado in ('sentada', 'completada')
          or (estado = 'confirmada' and fecha < public.hoy_uy()));
$$;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: reserva; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reserva (
    id_reserva bigint NOT NULL,
    id_usuario uuid NOT NULL,
    id_mesa bigint NOT NULL,
    fecha date NOT NULL,
    hora time without time zone NOT NULL,
    cantidad_personas integer NOT NULL,
    estado text DEFAULT 'confirmada'::text NOT NULL,
    fecha_creacion timestamp with time zone DEFAULT now() NOT NULL,
    duracion_min integer NOT NULL,
    limpieza_min integer NOT NULL,
    franja tsrange GENERATED ALWAYS AS (tsrange((fecha + hora), ((fecha + hora) + (((duracion_min + limpieza_min))::double precision * '00:01:00'::interval)))) STORED,
    ocasion text,
    comentarios text,
    CONSTRAINT reserva_cantidad_personas_check CHECK ((cantidad_personas > 0)),
    CONSTRAINT reserva_comentarios_ok CHECK (((comentarios IS NULL) OR (char_length(comentarios) <= 300))),
    CONSTRAINT reserva_duracion_ok CHECK (((duracion_min >= 30) AND (duracion_min <= 360))),
    CONSTRAINT reserva_estado_check CHECK ((estado = ANY (ARRAY['confirmada'::text, 'sentada'::text, 'completada'::text, 'cancelada'::text, 'no_asistio'::text]))),
    CONSTRAINT reserva_ocasion_ok CHECK (((ocasion IS NULL) OR (ocasion = ANY (ARRAY['cumpleaños'::text, 'aniversario'::text, 'negocios'::text, 'cita'::text, 'celebración'::text, 'otra'::text]))))
);

--
-- Name: crear_reserva(date, time without time zone, integer, bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crear_reserva(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint DEFAULT NULL::bigint, p_ocasion text DEFAULT NULL::text, p_comentarios text DEFAULT NULL::text) RETURNS public.reserva
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_mesa    bigint;
  v_reserva public.reserva;
  v_activas int;
  v_maximo  int := coalesce(public.config('max_reservas_cliente')::int, 3);
  v_motivo  text;
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

  v_motivo := public.motivo_turno(p_fecha, p_hora, p_personas);
  if v_motivo is not null then
    raise exception '%', v_motivo;
  end if;

  if p_id_mesa is not null then
    select d.id_mesa into v_mesa
      from public.mesas_disponibles(p_fecha, p_hora, p_personas) d
     where d.id_mesa = p_id_mesa;
    if v_mesa is null then
      raise exception 'Esa mesa no está disponible para tu grupo a esa hora. Elegí otra o cambiá el horario.';
    end if;
  else
    select id_mesa into v_mesa
      from public.mesas_disponibles(p_fecha, p_hora, p_personas)
     limit 1;
    if v_mesa is null then
      raise exception 'No quedan mesas para % personas a esa hora', p_personas;
    end if;
  end if;

  insert into public.reserva (id_usuario, id_mesa, fecha, hora, cantidad_personas, ocasion, comentarios)
  values (auth.uid(), v_mesa, p_fecha, p_hora, p_personas,
          nullif(p_ocasion, ''), nullif(left(trim(coalesce(p_comentarios, '')), 300), ''))
  returning * into v_reserva;
  return v_reserva;
end; $$;

--
-- Name: crear_usuario_nuevo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crear_usuario_nuevo() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v_tel   text := trim(coalesce(new.raw_user_meta_data->>'telefono', ''));
  v_texto text := coalesce(new.raw_user_meta_data->>'fecha_nacimiento', '');
  v_nac   date;
begin
  if v_tel !~ '^[0-9 +()-]{6,20}$' then
    v_tel := null;   -- si viene mal escrito no se guarda (el registro no falla)
  end if;
  if v_texto ~ '^\d{4}-\d{2}-\d{2}$' then
    begin
      v_nac := v_texto::date;
      if v_nac > public.hoy_uy() or v_nac < date '1900-01-01' then v_nac := null; end if;
    exception when others then
      v_nac := null;
    end;
  end if;
  insert into public.usuario (id_usuario, nombre, email, telefono, fecha_nacimiento,
                              fecha_acepta_privacidad, acepta_promociones)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nombre', ''),
    new.email,
    v_tel,
    v_nac,
    case when new.raw_user_meta_data->>'acepta_privacidad' = 'si' then now() end,
    coalesce(new.raw_user_meta_data->>'acepta_promociones', '') = 'si'
  );
  return new;
end; $_$;

--
-- Name: dar_beneficio(uuid, text, text, text, date, bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dar_beneficio(p_usuario uuid, p_tipo text, p_periodo text, p_descripcion text, p_vence date, p_campana bigint DEFAULT NULL::bigint, p_extra jsonb DEFAULT '{}'::jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  b public.beneficio;
  u public.usuario;
begin
  insert into public.beneficio (codigo, id_usuario, tipo, descripcion, periodo, id_campana, vence_en)
  values (public.generar_codigo(), p_usuario, p_tipo, p_descripcion, p_periodo, p_campana, p_vence)
  on conflict (id_usuario, tipo, periodo) do nothing
  returning * into b;
  if b.id_beneficio is null then
    return false;   -- ya lo tenía
  end if;

  select * into u from public.usuario where id_usuario = p_usuario;
  if u.acepta_promociones then
    perform public.avisar_n8n(p_extra || jsonb_build_object(
      'tipo',        case when p_tipo = 'campana' then 'campana' else 'beneficio_' || p_tipo end,
      'nombre',      u.nombre,
      'email',       u.email,
      'codigo',      b.codigo,
      'descripcion', b.descripcion,
      'vence',       to_char(b.vence_en, 'DD/MM/YYYY')
    ));
    update public.beneficio set correo_enviado = true where id_beneficio = b.id_beneficio;
  end if;
  return true;
end; $$;

--
-- Name: datos_clientes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.datos_clientes() RETURNS TABLE(id_usuario uuid, nombre text, email text, telefono text, fecha_nacimiento date, acepta_promociones boolean, cliente_desde date, visitas integer, visitas_12m integer, ultima_visita date, dias_sin_venir integer, proxima_reserva date, cancelaciones integer, no_asistio integer, zona_favorita text, dia_favorito integer, horario_favorito text, grupo_habitual integer, ocasiones text[], proximo_cumple date, dias_para_cumple integer, segmento text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select * from public.datos_clientes_de(null);
$$;

--
-- Name: datos_clientes_de(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.datos_clientes_de(p_usuario uuid) RETURNS TABLE(id_usuario uuid, nombre text, email text, telefono text, fecha_nacimiento date, acepta_promociones boolean, cliente_desde date, visitas integer, visitas_12m integer, ultima_visita date, dias_sin_venir integer, proxima_reserva date, cancelaciones integer, no_asistio integer, zona_favorita text, dia_favorito integer, horario_favorito text, grupo_habitual integer, ocasiones text[], proximo_cumple date, dias_para_cumple integer, segmento text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_hoy date := public.hoy_uy();
  a     public.ajustes_fidelizacion;
begin
  select * into a from public.ajustes_fidelizacion where id = 1;
  return query
  with r as (
    select x.id_usuario, x.fecha, x.hora, x.cantidad_personas, x.estado, x.ocasion, m.zona,
           -- visita = sentada o completada, o confirmada de un día que ya pasó
           (x.estado in ('sentada', 'completada')
            or (x.estado = 'confirmada' and x.fecha < v_hoy)) as es_visita
      from public.reserva x
      join public.mesa m on m.id_mesa = x.id_mesa
     where p_usuario is null or x.id_usuario = p_usuario
  ),
  agg as (
    select r.id_usuario,
      count(*) filter (where r.es_visita)::int                              as visitas,
      count(*) filter (where r.es_visita and r.fecha > v_hoy - 365)::int    as visitas_12m,
      max(r.fecha) filter (where r.es_visita)                               as ultima_visita,
      min(r.fecha) filter (where r.estado = 'confirmada' and r.fecha >= v_hoy) as proxima_reserva,
      count(*) filter (where r.estado = 'cancelada')::int                   as cancelaciones,
      count(*) filter (where r.estado = 'no_asistio')::int                  as no_asistio,
      mode() within group (order by r.zona) filter (where r.es_visita)      as zona_favorita,
      mode() within group (order by extract(isodow from r.fecha)::int)
        filter (where r.es_visita)                                          as dia_favorito,
      mode() within group (order by case when r.hora < time '20:30' then 'temprano' else 'tarde' end)
        filter (where r.es_visita)                                          as horario_favorito,
      mode() within group (order by r.cantidad_personas) filter (where r.es_visita) as grupo_habitual,
      array_agg(distinct r.ocasion) filter (where r.ocasion is not null and r.estado <> 'cancelada') as ocasiones
    from r
    group by r.id_usuario
  ),
  base as (
    select u.id_usuario, u.nombre, u.email, u.telefono, u.fecha_nacimiento, u.acepta_promociones,
           u.fecha_creacion::date as cliente_desde,
           coalesce(g.visitas, 0) as visitas, coalesce(g.visitas_12m, 0) as visitas_12m,
           g.ultima_visita, g.proxima_reserva,
           coalesce(g.cancelaciones, 0) as cancelaciones, coalesce(g.no_asistio, 0) as no_asistio,
           g.zona_favorita, g.dia_favorito, g.horario_favorito, g.grupo_habitual, g.ocasiones,
           -- próximo cumpleaños (el 29/2 se festeja el 28/2 los años comunes)
           case when u.fecha_nacimiento is not null then
             case when (u.fecha_nacimiento + make_interval(years => extract(year from v_hoy)::int
                         - extract(year from u.fecha_nacimiento)::int))::date >= v_hoy
                  then (u.fecha_nacimiento + make_interval(years => extract(year from v_hoy)::int
                         - extract(year from u.fecha_nacimiento)::int))::date
                  else (u.fecha_nacimiento + make_interval(years => extract(year from v_hoy)::int + 1
                         - extract(year from u.fecha_nacimiento)::int))::date
             end
           end as proximo_cumple
      from public.usuario u
      left join agg g on g.id_usuario = u.id_usuario
     where u.rol = 'cliente'
       and (p_usuario is null or u.id_usuario = p_usuario)
  )
  select b.id_usuario, b.nombre, b.email, b.telefono, b.fecha_nacimiento, b.acepta_promociones,
         b.cliente_desde, b.visitas, b.visitas_12m, b.ultima_visita,
         (v_hoy - b.ultima_visita)::int,
         b.proxima_reserva, b.cancelaciones, b.no_asistio,
         b.zona_favorita, b.dia_favorito, b.horario_favorito, b.grupo_habitual, b.ocasiones,
         b.proximo_cumple, (b.proximo_cumple - v_hoy)::int,
         case
           when b.visitas = 0 then 'nuevo'
           when b.proxima_reserva is null and v_hoy - b.ultima_visita > a.dias_inactivo then 'inactivo'
           when b.proxima_reserva is null and v_hoy - b.ultima_visita > a.dias_en_riesgo then 'en_riesgo'
           when b.visitas_12m >= a.visitas_vip then 'vip'
           when b.visitas_12m >= a.visitas_frecuente then 'frecuente'
           else 'nuevo'
         end
    from base b;
end; $$;

--
-- Name: destinatarios_campana(text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.destinatarios_campana(p_segmento text, p_zona text, p_grupo text, p_limite integer DEFAULT 100) RETURNS TABLE(nombre text, email text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede armar campañas';
  end if;
  return query
    select u.nombre, u.email
      from public.clientes_de_campana(nullif(trim(p_segmento), ''), nullif(trim(p_zona), ''),
                                      nullif(trim(p_grupo), '')) c(id)
      join public.usuario u on u.id_usuario = c.id
     where u.acepta_promociones
     order by u.nombre
     limit least(greatest(coalesce(p_limite, 100), 1), 300);
end; $$;

--
-- Name: duracion_para(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.duracion_para(p_personas integer) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(
    (select minutos from public.duracion_por_grupo
      where hasta_personas >= p_personas order by hasta_personas limit 1),
    (select max(minutos) from public.duracion_por_grupo),
    120);
$$;

--
-- Name: ejecutar_fidelizacion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ejecutar_fidelizacion() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ejecutar las acciones';
  end if;
  return public.fidelizacion_diaria(true);
end; $$;

--
-- Name: es_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.es_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from public.usuario where id_usuario = auth.uid() and rol = 'admin'
  );
$$;

--
-- Name: estado_mesas(date, time without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.estado_mesas(p_fecha date, p_hora time without time zone, p_personas integer) RETURNS TABLE(id_mesa bigint, numero integer, capacidad integer, forma text, zona text, pos_x numeric, pos_y numeric, estado text, libre_desde text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  with pedido as (
    select tsrange(
             p_fecha + p_hora,
             p_fecha + p_hora + (public.duracion_para(p_personas)
               + (select limpieza_min from public.ajustes_reserva where id = 1)) * interval '1 minute'
           ) as franja
  )
  select m.id_mesa, m.numero, m.capacidad, m.forma, m.zona, m.pos_x, m.pos_y,
         case
           when m.estado <> 'activa'                         then 'inactiva'
           when m.capacidad < p_personas                     then 'chica'
           when not public.mesa_sirve(m.capacidad, p_personas) then 'grande'
           when exists (
             select 1 from public.reserva r, pedido
              where r.id_mesa = m.id_mesa
                and r.estado in ('confirmada', 'sentada')
                and r.franja && pedido.franja
           )                                                 then 'ocupada'
           else 'libre'
         end as estado,
         (select to_char(max(upper(r.franja)), 'HH24:MI')
            from public.reserva r, pedido
           where r.id_mesa = m.id_mesa
             and r.estado in ('confirmada', 'sentada')
             and r.franja && pedido.franja) as libre_desde
    from public.mesa m
   order by m.numero;
$$;

--
-- Name: extender_reserva(bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.extender_reserva(p_id_reserva bigint, p_minutos integer) RETURNS public.reserva
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v public.reserva;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede extender reservas';
  end if;
  update public.reserva
     set duracion_min = duracion_min + p_minutos
   where id_reserva = p_id_reserva
  returning * into v;
  return v;
exception when exclusion_violation then
  raise exception 'No se puede extender: la mesa tiene otra reserva después.';
end; $$;

--
-- Name: fidelizacion_diaria(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fidelizacion_diaria(p_forzar boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  a        public.ajustes_fidelizacion;
  c        record;
  n_cumple int := 0;
  n_react  int := 0;
  n_visit  int := 0;
  n_total  int := 0;
  pendientes int := 0;
  resumen  jsonb;
begin
  select * into a from public.ajustes_fidelizacion where id = 1;
  if not a.automatico and not p_forzar then
    return jsonb_build_object('omitido', 'Las acciones automáticas están apagadas');
  end if;

  for c in
    with d as (select * from public.datos_clientes()),
    t as (
      select d.*,
             (d.proximo_cumple is not null and d.dias_para_cumple between 0 and a.dias_aviso_cumple
              and not exists (select 1 from public.beneficio b
                               where b.id_usuario = d.id_usuario and b.tipo = 'cumpleanos'
                                 and b.periodo = extract(year from d.proximo_cumple)::text)) as toca_cumple,
             (d.visitas >= a.visitas_meta
              and not exists (select 1 from public.beneficio b
                               where b.id_usuario = d.id_usuario and b.tipo = 'visitas'
                                 and b.periodo = 'tarjeta-' || (d.visitas / a.visitas_meta)))   as toca_tarjeta,
             (d.segmento in ('en_riesgo', 'inactivo')
              and not exists (select 1 from public.beneficio b
                               where b.id_usuario = d.id_usuario and b.tipo = 'reactivacion'
                                 and b.periodo = 'desde-' || d.ultima_visita))                   as toca_react
        from d
    )
    select * from t
     where toca_cumple or toca_tarjeta or toca_react
     order by toca_cumple desc, toca_tarjeta desc, ultima_visita desc nulls last
  loop
    if n_total >= a.tope_diario then
      pendientes := pendientes + 1;
      continue;
    end if;
    if c.toca_cumple and public.dar_beneficio(c.id_usuario, 'cumpleanos', extract(year from c.proximo_cumple)::text,
                            a.beneficio_cumple, c.proximo_cumple + 15,
                            null, jsonb_build_object('cumple', to_char(c.proximo_cumple, 'DD/MM'))) then
      n_cumple := n_cumple + 1;
      n_total := n_total + 1;
    end if;
    if c.toca_tarjeta and public.dar_beneficio(c.id_usuario, 'visitas', 'tarjeta-' || (c.visitas / a.visitas_meta),
                            a.beneficio_visitas, public.hoy_uy() + a.vigencia_dias,
                            null, jsonb_build_object('visitas', c.visitas)) then
      n_visit := n_visit + 1;
      n_total := n_total + 1;
    end if;
    if c.toca_react and public.dar_beneficio(c.id_usuario, 'reactivacion', 'desde-' || c.ultima_visita,
                            a.beneficio_reactivacion, public.hoy_uy() + a.vigencia_dias) then
      n_react := n_react + 1;
      n_total := n_total + 1;
    end if;
  end loop;

  resumen := jsonb_build_object('cumpleanos', n_cumple, 'reactivacion', n_react, 'visitas', n_visit,
                                'pendientes', pendientes);
  update public.ajustes_fidelizacion
     set ultima_ejecucion = now(), ultimo_resumen = resumen
   where id = 1;
  return resumen;
end; $$;

--
-- Name: generar_codigo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generar_codigo() RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v text;
begin
  loop
    v := 'MAREA-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (select 1 from public.beneficio where codigo = v);
  end loop;
  return v;
end; $$;

--
-- Name: guardar_clima(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guardar_clima(p_dias jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  n int;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede guardar el clima';
  end if;
  insert into public.clima_dia as c (fecha, temp_max, temp_noche, lluvia_mm, lluvia_noche_mm,
                                     prob_lluvia, codigo, viento_max, es_pronostico, actualizado)
  select (d->>'fecha')::date, (d->>'temp_max')::numeric, (d->>'temp_noche')::numeric,
         (d->>'lluvia_mm')::numeric, (d->>'lluvia_noche_mm')::numeric,
         least(100, greatest(0, (d->>'prob_lluvia')::int)), (d->>'codigo')::int,
         (d->>'viento_max')::numeric,
         (d->>'fecha')::date >= public.hoy_uy(), now()
    from jsonb_array_elements(p_dias) d
   where (d->>'fecha') ~ '^\d{4}-\d{2}-\d{2}$'
  on conflict (fecha) do update
     set temp_max = excluded.temp_max, temp_noche = excluded.temp_noche,
         lluvia_mm = excluded.lluvia_mm, lluvia_noche_mm = excluded.lluvia_noche_mm,
         prob_lluvia = excluded.prob_lluvia, codigo = excluded.codigo,
         viento_max = excluded.viento_max, es_pronostico = excluded.es_pronostico,
         actualizado = now()
   -- lo que ya pasó y quedó como dato real no se pisa con un pronóstico
   where not (c.es_pronostico = false and excluded.es_pronostico = true);
  get diagnostics n = row_count;
  return n;
end; $_$;

--
-- Name: historial_noches(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.historial_noches(p_desde date, p_hasta date) RETURNS TABLE(fecha date, dia_semana integer, reservas integer, cubiertos integer, reservados integer, cancelaciones integer, no_vinieron integer, mozos integer, temp_max numeric, temp_noche numeric, lluvia_mm numeric, lluvia_noche_mm numeric, prob_lluvia integer, codigo integer, viento_max numeric, es_pronostico boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver el historial';
  end if;
  if p_hasta - p_desde > 400 then
    raise exception 'Elegí un período de hasta 400 días';
  end if;
  return query
    with dias as (select generate_series(p_desde, p_hasta, interval '1 day')::date as f),
    r as (
      select r.fecha,
             count(*) filter (where r.estado <> 'cancelada')::int as reservas,
             coalesce(sum(r.cantidad_personas) filter (
               where r.estado in ('sentada', 'completada')
                  or (r.estado = 'confirmada' and r.fecha < public.hoy_uy())), 0)::int as cubiertos,
             coalesce(sum(r.cantidad_personas) filter (
               where r.estado in ('confirmada', 'sentada')), 0)::int as reservados,
             count(*) filter (where r.estado = 'cancelada')::int as cancelaciones,
             count(*) filter (where r.estado = 'no_asistio')::int as no_vinieron
        from public.reserva r
       where r.fecha between p_desde and p_hasta
       group by r.fecha
    )
    select d.f, extract(isodow from d.f)::int,
           coalesce(r.reservas, 0), coalesce(r.cubiertos, 0), coalesce(r.reservados, 0),
           coalesce(r.cancelaciones, 0), coalesce(r.no_vinieron, 0),
           p.mozos,
           c.temp_max, c.temp_noche, c.lluvia_mm, c.lluvia_noche_mm, c.prob_lluvia, c.codigo,
           c.viento_max, c.es_pronostico
      from dias d
      left join r on r.fecha = d.f
      left join public.clima_dia c on c.fecha = d.f
      left join public.personal_dia p on p.fecha = d.f
     order by d.f;
end; $$;

--
-- Name: horarios_alternativos(date, time without time zone, integer, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.horarios_alternativos(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  a        public.ajustes_reserva;
  v_dur    int := public.duracion_para(p_personas);
  v_ahora  timestamp := now() at time zone 'America/Montevideo';
  v_pedido timestamp := p_fecha + p_hora;
  v_mismo  jsonb;
  v_dia    date;
  v_otro   jsonb := null;
begin
  select * into a from public.ajustes_reserva where id = 1;

  -- Horarios del mismo día, ordenados por cercanía a la hora pedida
  with turnos as (
    select t as inicio
      from generate_series(p_fecha + a.apertura,
                           public.cierre_de(p_fecha) - v_dur * interval '1 minute',
                           a.intervalo_min * interval '1 minute') t
  ), libres as (
    select inicio
      from turnos
     where inicio > v_ahora
       and inicio <> v_pedido
       and public.motivo_turno(inicio::date, inicio::time, p_personas) is null
       and exists (select 1 from public.mesas_disponibles(inicio::date, inicio::time, p_personas) d
                    where p_id_mesa is null or d.id_mesa = p_id_mesa)
     order by abs(extract(epoch from (inicio - v_pedido)))
     limit 4
  )
  select coalesce(jsonb_agg(to_char(inicio, 'HH24:MI') order by inicio), '[]'::jsonb)
    into v_mismo from libres;

  -- Si ese día no hay nada, buscamos el próximo día con lugar
  if jsonb_array_length(v_mismo) = 0 then
    for i in 1..14 loop
      v_dia := p_fecha + i;
      select jsonb_build_object('fecha', v_dia, 'hora', to_char(t, 'HH24:MI'))
        into v_otro
        from generate_series(v_dia + a.apertura,
                             public.cierre_de(v_dia) - v_dur * interval '1 minute',
                             a.intervalo_min * interval '1 minute') t
       where public.motivo_turno(t::date, t::time, p_personas) is null
         and exists (select 1 from public.mesas_disponibles(t::date, t::time, p_personas) d
                      where p_id_mesa is null or d.id_mesa = p_id_mesa)
       order by abs(extract(epoch from (t::time - p_hora)))
       limit 1;
      exit when v_otro is not null;
    end loop;
  end if;

  return jsonb_build_object('mismo_dia', v_mismo, 'otro_dia', v_otro);
end; $$;

--
-- Name: hoy_uy(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.hoy_uy() RETURNS date
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select (now() at time zone 'America/Montevideo')::date;
$$;

--
-- Name: html_seguro(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.html_seguro(p_texto text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select replace(replace(replace(replace(replace(replace(coalesce(p_texto, ''),
         '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;'), E'\n', '<br>');
$$;

--
-- Name: invitar_a_sumarse(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.invitar_a_sumarse(p_fecha date) RETURNS TABLE(id_reserva bigint, nombre text, hora time without time zone, personas integer, mesa integer, visitas integer)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver esta lista';
  end if;
  return query
    select r.id_reserva, u.nombre, r.hora, r.cantidad_personas, m.numero,
           (select count(*) from public.reserva x
             where x.id_usuario = u.id_usuario
               and (x.estado in ('sentada', 'completada')
                    or (x.estado = 'confirmada' and x.fecha < public.hoy_uy())))::int
      from public.reserva r
      join public.usuario u on u.id_usuario = r.id_usuario
      join public.mesa m on m.id_mesa = r.id_mesa
     where r.fecha = p_fecha
       and r.estado in ('confirmada', 'sentada')
       and u.rol = 'cliente'
       and not u.acepta_promociones
     order by r.hora;
end; $$;

--
-- Name: invitar_admin(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.invitar_admin(p_email text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $_$
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
end; $_$;

--
-- Name: campana; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campana (
    id_campana bigint NOT NULL,
    nombre text NOT NULL,
    segmento text,
    zona text,
    grupo text,
    asunto text NOT NULL,
    mensaje text NOT NULL,
    beneficio text,
    vence_en date,
    destinatarios integer DEFAULT 0 NOT NULL,
    creada_por uuid,
    creada_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT campana_asunto_check CHECK (((char_length(asunto) >= 3) AND (char_length(asunto) <= 120))),
    CONSTRAINT campana_beneficio_check CHECK (((beneficio IS NULL) OR ((char_length(beneficio) >= 3) AND (char_length(beneficio) <= 120)))),
    CONSTRAINT campana_grupo_check CHECK ((grupo = ANY (ARRAY['pareja'::text, 'grupo'::text]))),
    CONSTRAINT campana_mensaje_check CHECK (((char_length(mensaje) >= 3) AND (char_length(mensaje) <= 1000))),
    CONSTRAINT campana_nombre_check CHECK (((char_length(nombre) >= 3) AND (char_length(nombre) <= 80))),
    CONSTRAINT campana_segmento_check CHECK ((segmento = ANY (ARRAY['nuevo'::text, 'frecuente'::text, 'vip'::text, 'en_riesgo'::text, 'inactivo'::text])))
);

--
-- Name: lanzar_campana(text, text, text, text, text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lanzar_campana(p_nombre text, p_segmento text, p_zona text, p_grupo text, p_asunto text, p_mensaje text, p_beneficio text, p_vigencia_dias integer DEFAULT 30) RETURNS public.campana
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  k      public.campana;
  u      public.usuario;
  v_n    int := 0;
  v_seg  text := nullif(trim(p_segmento), '');
  v_zona text := nullif(trim(p_zona), '');
  v_grp  text := nullif(trim(p_grupo), '');
  v_ben  text := nullif(trim(p_beneficio), '');
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede lanzar campañas';
  end if;
  if coalesce(p_vigencia_dias, 0) not between 1 and 180 then
    raise exception 'La vigencia tiene que ser de 1 a 180 días';
  end if;
  if (select count(*) from public.clientes_de_campana(v_seg, v_zona, v_grp) c(id)
        join public.usuario x on x.id_usuario = c.id and x.acepta_promociones) > 300 then
    raise exception 'La campaña llega a más de 300 personas. Elegí un público más chico.';
  end if;

  insert into public.campana (nombre, segmento, zona, grupo, asunto, mensaje, beneficio, vence_en, creada_por)
  values (trim(p_nombre), v_seg, v_zona, v_grp, trim(p_asunto), trim(p_mensaje), v_ben,
          public.hoy_uy() + p_vigencia_dias, auth.uid())
  returning * into k;

  for u in
    select x.* from public.clientes_de_campana(v_seg, v_zona, v_grp) c(id)
      join public.usuario x on x.id_usuario = c.id
     where x.acepta_promociones
  loop
    if v_ben is not null then
      perform public.dar_beneficio(u.id_usuario, 'campana', 'campana-' || k.id_campana, v_ben, k.vence_en,
                                   k.id_campana,
                                   jsonb_build_object('asunto_campana', k.asunto, 'mensaje', k.mensaje));
    else
      perform public.avisar_n8n(jsonb_build_object(
        'tipo', 'campana', 'nombre', u.nombre, 'email', u.email,
        'asunto_campana', k.asunto, 'mensaje', k.mensaje));
    end if;
    v_n := v_n + 1;
  end loop;

  update public.campana set destinatarios = v_n where id_campana = k.id_campana returning * into k;
  return k;
end; $$;

--
-- Name: mantenimiento(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mantenimiento() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  n_ia   int;
  n_inv  int;
  n_pron int;
begin
  delete from public.uso_ia where fecha < now() - interval '400 days';
  get diagnostics n_ia = row_count;
  delete from public.invitacion_admin
   where usada_en is null and vence_en < now() - interval '90 days';
  get diagnostics n_inv = row_count;
  -- pronósticos viejos que nunca se reemplazaron por el dato real
  delete from public.clima_dia where es_pronostico and fecha < public.hoy_uy() - 30;
  get diagnostics n_pron = row_count;
  return jsonb_build_object('uso_ia', n_ia, 'invitaciones', n_inv, 'pronosticos', n_pron);
end; $$;

--
-- Name: mesa_sirve(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mesa_sirve(p_capacidad integer, p_personas integer) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select p_capacidad >= p_personas
     and p_capacidad - p_personas <= (select holgura_mesa from public.ajustes_reserva where id = 1);
$$;

--
-- Name: mesa; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mesa (
    id_mesa bigint NOT NULL,
    numero integer NOT NULL,
    capacidad integer NOT NULL,
    estado text DEFAULT 'activa'::text NOT NULL,
    forma text,
    pos_x numeric(5,1),
    pos_y numeric(5,1),
    zona text,
    CONSTRAINT mesa_capacidad_check CHECK ((capacidad > 0)),
    CONSTRAINT mesa_capacidad_par CHECK (((capacidad % 2) = 0)),
    CONSTRAINT mesa_estado_check CHECK ((estado = ANY (ARRAY['activa'::text, 'inactiva'::text]))),
    CONSTRAINT mesa_forma_ok CHECK (((forma IS NULL) OR (forma = ANY (ARRAY['redonda'::text, 'cuadrada'::text, 'rectangular'::text])))),
    CONSTRAINT mesa_posicion_ok CHECK ((((pos_x IS NULL) OR ((pos_x >= (0)::numeric) AND (pos_x <= (120)::numeric))) AND ((pos_y IS NULL) OR ((pos_y >= (0)::numeric) AND (pos_y <= (80)::numeric)))))
);

--
-- Name: mesas_disponibles(date, time without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mesas_disponibles(p_fecha date, p_hora time without time zone, p_personas integer) RETURNS SETOF public.mesa
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select m.*
  from public.mesa m
  where m.estado = 'activa'
    and public.mesa_sirve(m.capacidad, p_personas)
    and not exists (
      select 1 from public.reserva r
      where r.id_mesa = m.id_mesa
        and r.estado in ('confirmada', 'sentada')
        and r.franja && tsrange(
              p_fecha + p_hora,
              p_fecha + p_hora + (public.duracion_para(p_personas)
                + (select limpieza_min from public.ajustes_reserva where id = 1)) * interval '1 minute')
    )
  order by m.capacidad, m.numero;
$$;

--
-- Name: mi_fidelizacion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mi_fidelizacion() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  c record;
  a public.ajustes_fidelizacion;
begin
  if auth.uid() is null then
    return null;
  end if;
  select * into a from public.ajustes_fidelizacion where id = 1;
  select * into c from public.datos_clientes_de(auth.uid());
  if not found then
    return null;
  end if;
  return jsonb_build_object(
    'visitas',      c.visitas,
    'visitas_meta', a.visitas_meta,
    'sellos',       c.visitas % a.visitas_meta,
    'faltan',       a.visitas_meta - (c.visitas % a.visitas_meta),
    'beneficio_visitas', a.beneficio_visitas,
    'beneficio_cumple', a.beneficio_cumple,
    'proximo_cumple', c.proximo_cumple
  );
end; $$;

--
-- Name: motivo_turno(date, time without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.motivo_turno(p_fecha date, p_hora time without time zone, p_personas integer) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  a        public.ajustes_reserva;
  v_inicio timestamp := p_fecha + p_hora;
  v_dur    int := public.duracion_para(p_personas);
  v_apert  timestamp;
  v_cierre timestamp;
  v_turno  timestamp;
  v_en_turno int;
begin
  select * into a from public.ajustes_reserva where id = 1;
  v_apert  := p_fecha + a.apertura;
  v_cierre := public.cierre_de(p_fecha);

  if v_inicio < v_apert or v_inicio >= v_cierre then
    return format('Atendemos de %s a %s.', to_char(a.apertura, 'HH24:MI'), to_char(a.cierre, 'HH24:MI'));
  end if;
  if (extract(minute from p_hora)::int % a.intervalo_min) <> 0 then
    return format('Las reservas son cada %s minutos.', a.intervalo_min);
  end if;
  if v_inicio + v_dur * interval '1 minute' > v_cierre then
    return format('Para %s personas la última reserva es a las %s (la mesa es por %s y cerramos a las %s).',
                  p_personas,
                  to_char(v_cierre - v_dur * interval '1 minute', 'HH24:MI'),
                  public.texto_duracion(v_dur),
                  to_char(a.cierre, 'HH24:MI'));
  end if;

  -- Ritmo de cocina: personas que empiezan en este mismo turno
  v_turno := p_fecha + a.apertura
             + floor(extract(epoch from (v_inicio - v_apert)) / 60 / a.intervalo_min)
               * a.intervalo_min * interval '1 minute';
  select coalesce(sum(cantidad_personas), 0) into v_en_turno
    from public.reserva
   where estado in ('confirmada', 'sentada', 'completada')
     and (fecha + hora) >= v_turno
     and (fecha + hora) <  v_turno + a.intervalo_min * interval '1 minute';
  if v_en_turno + p_personas > a.max_personas_por_turno then
    return 'A esa hora la cocina ya tiene muchas mesas empezando. Probá 15 minutos antes o después.';
  end if;

  return null;
end; $$;

--
-- Name: notificar_reserva(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notificar_reserva() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_tipo      text;
  v_cliente   public.usuario;
  v_mesa      public.mesa;
  v_activas   int;
  v_ocupadas  int;
  v_pct       int;
begin
  if tg_op = 'INSERT' and new.estado = 'confirmada' then
    v_tipo := 'confirmacion';
  elsif tg_op = 'UPDATE' and old.estado in ('confirmada', 'sentada') and new.estado = 'cancelada' then
    v_tipo := case when auth.uid() = new.id_usuario then 'cancelacion_cliente'
                   else 'cancelacion_admin' end;
  elsif tg_op = 'UPDATE' and new.estado = 'confirmada' and old.estado = 'confirmada'
        and (old.fecha, old.hora, old.id_mesa, old.cantidad_personas)
            is distinct from (new.fecha, new.hora, new.id_mesa, new.cantidad_personas) then
    v_tipo := 'modificacion';
  else
    return new;   -- sentada, completada, no asistió o extender: no se manda nada
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
    'hasta',      to_char(new.hora + new.duracion_min * interval '1 minute', 'HH24:MI'),
    'personas',   new.cantidad_personas,
    'mesa',       v_mesa.numero
  ));

  if v_tipo in ('confirmacion', 'modificacion') then
    select count(*) into v_activas from public.mesa where estado = 'activa';
    select count(distinct id_mesa) into v_ocupadas
      from public.reserva
     where fecha = new.fecha
       and estado in ('confirmada', 'sentada')
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

--
-- Name: quitar_admin(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.quitar_admin(p_id_usuario uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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

--
-- Name: resumen_fidelizacion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resumen_fidelizacion() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_hoy date := public.hoy_uy();
  r     jsonb;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede ver la segmentación';
  end if;
  with d as (select segmento, acepta_promociones from public.datos_clientes())
  select jsonb_build_object(
    'total',       (select count(*) from d),
    'segmentos',   coalesce((select jsonb_object_agg(segmento, n)
                               from (select segmento, count(*) n from d group by 1) s), '{}'::jsonb),
    'sin_correos', (select count(*) from d where not acepta_promociones),
    'cupones', jsonb_build_object(
       'vigentes',     (select count(*) from public.beneficio where usado_en is null and vence_en >= v_hoy),
       'creados_30',   (select count(*) from public.beneficio where creado_en >= now() - interval '30 days'),
       'usados_30',    (select count(*) from public.beneficio where creado_en >= now() - interval '30 days'
                                                               and usado_en is not null)),
    'canjes_campana', coalesce((select jsonb_object_agg(id_campana, n) from
                       (select b.id_campana, count(*) n from public.beneficio b
                         where b.id_campana in (select id_campana from public.campana
                                                 order by creada_en desc limit 8)
                           and b.usado_en is not null
                         group by 1) k), '{}'::jsonb)
  ) into r;
  return r;
end; $$;

--
-- Name: resumen_para_ia(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resumen_para_ia(p_segmento text, p_zona text, p_grupo text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_seg  text := nullif(trim(p_segmento), '');
  v_zona text := nullif(trim(p_zona), '');
  v_grp  text := nullif(trim(p_grupo), '');
  v_hoy  int;
  r      jsonb;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede usar la IA';
  end if;
  select count(*) into v_hoy from public.uso_ia
   where fecha >= (public.hoy_uy()::timestamp at time zone 'America/Montevideo');
  if v_hoy >= 30 then
    raise exception 'Se llegó al límite de 30 sugerencias de IA por hoy. Probá mañana.';
  end if;
  insert into public.uso_ia (id_usuario) values (auth.uid());

  with d as (
    select c.* from public.datos_clientes() c
     where (v_seg is null or c.segmento = v_seg)
       and (v_zona is null or c.zona_favorita = v_zona)
       and (v_grp is null
            or (v_grp = 'pareja' and c.grupo_habitual <= 2)
            or (v_grp = 'grupo'  and c.grupo_habitual >= 4))
  )
  select jsonb_build_object(
    'segmento',           coalesce(v_seg, 'todos'),
    'zona_elegida',       coalesce(v_zona, 'cualquiera'),
    'grupo_elegido',      coalesce(v_grp, 'cualquiera'),
    'clientes',           (select count(*) from d),
    'aceptan_correos',    (select count(*) from d where acepta_promociones),
    'visitas_promedio',   (select round(avg(visitas), 1) from d),
    'dias_sin_venir_promedio', (select round(avg(dias_sin_venir)) from d),
    'zonas_favoritas',    (select jsonb_object_agg(zona_favorita, n) from
                            (select zona_favorita, count(*) n from d where zona_favorita is not null group by 1) z),
    'dias_favoritos',     (select jsonb_object_agg(dia, n) from
                            (select (array['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])[dia_favorito] dia,
                                    count(*) n from d where dia_favorito is not null group by 1) z),
    'horario',            (select jsonb_object_agg(horario_favorito, n) from
                            (select horario_favorito, count(*) n from d where horario_favorito is not null group by 1) z),
    'en_pareja',          (select count(*) from d where grupo_habitual <= 2),
    'en_grupo',           (select count(*) from d where grupo_habitual >= 4),
    'ocasiones',          (select jsonb_object_agg(o, n) from
                            (select o, count(*) n from d, unnest(d.ocasiones) o group by 1) z),
    'cumplen_en_30_dias', (select count(*) from d where dias_para_cumple <= 30),
    'beneficios_actuales', (select jsonb_build_object('cumpleanos', beneficio_cumple,
                              'reactivacion', beneficio_reactivacion, 'tarjeta_visitas', beneficio_visitas)
                              from public.ajustes_fidelizacion where id = 1)
  ) into r;
  return r;
end; $$;

--
-- Name: revisar_tarjeta_visitas(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revisar_tarjeta_visitas(p_usuario uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  a     public.ajustes_fidelizacion;
  total int := public.contar_visitas(p_usuario);
  hito  int;
begin
  select * into a from public.ajustes_fidelizacion where id = 1;
  hito := total / a.visitas_meta;
  if hito < 1 or not exists (select 1 from public.usuario where id_usuario = p_usuario and rol = 'cliente') then
    return false;
  end if;
  return public.dar_beneficio(p_usuario, 'visitas', 'tarjeta-' || hito, a.beneficio_visitas,
                              public.hoy_uy() + a.vigencia_dias,
                              null, jsonb_build_object('visitas', total));
end; $$;

--
-- Name: revocar_invitacion(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revocar_invitacion(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede revocar invitaciones.';
  end if;
  update public.invitacion_admin set revocada = true
   where id = p_id and usada_en is null;
end; $$;

--
-- Name: texto_bienvenida(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.texto_bienvenida() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select beneficio_bienvenida from public.ajustes_fidelizacion where id = 1;
$$;

--
-- Name: texto_duracion(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.texto_duracion(p_min integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select case
    when p_min < 60 then p_min || ' min'
    when p_min % 60 = 0 then (p_min / 60) || ' h'
    else (p_min / 60) || ' h ' || (p_min % 60) || ' min'
  end;
$$;

--
-- Name: validar_capacidad(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validar_capacidad() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare m public.mesa;
begin
  if new.duracion_min is null
     or (tg_op = 'UPDATE' and new.cantidad_personas <> old.cantidad_personas
         and new.duracion_min = old.duracion_min) then
    new.duracion_min := public.duracion_para(new.cantidad_personas);
  end if;
  if new.limpieza_min is null then
    new.limpieza_min := (select limpieza_min from public.ajustes_reserva where id = 1);
  end if;

  if new.estado not in ('confirmada', 'sentada') then
    return new;   -- cancelar, liberar o marcar no asistió siempre se puede
  end if;
  select * into m from public.mesa where id_mesa = new.id_mesa;
  if m.estado <> 'activa' then
    raise exception 'La mesa % no está activa', m.numero;
  end if;
  if new.cantidad_personas > m.capacidad then
    raise exception 'La mesa % es para % personas como máximo', m.numero, m.capacidad;
  end if;
  return new;
end; $$;

--
-- Name: validar_datos_cliente(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validar_datos_cliente() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.fecha_nacimiento is not null
     and (new.fecha_nacimiento > public.hoy_uy() or new.fecha_nacimiento < date '1900-01-01') then
    raise exception 'La fecha de nacimiento no es válida';
  end if;
  if new.acepta_promociones and (tg_op = 'INSERT' or not old.acepta_promociones) then
    new.fecha_acepta_promociones := now();
  elsif not new.acepta_promociones then
    new.fecha_acepta_promociones := null;
  end if;
  return new;
end; $$;

--
-- Name: vista_previa_campana(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.vista_previa_campana(p_segmento text, p_zona text, p_grupo text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_total int;
  v_con   int;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador puede armar campañas';
  end if;
  select count(*), count(*) filter (where u.acepta_promociones)
    into v_total, v_con
    from public.clientes_de_campana(nullif(p_segmento, ''), nullif(p_zona, ''), nullif(p_grupo, '')) c(id)
    join public.usuario u on u.id_usuario = c.id;
  return jsonb_build_object('coinciden', v_total, 'destinatarios', v_con, 'sin_permiso', v_total - v_con);
end; $$;

--
-- Name: ajustes_fidelizacion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ajustes_fidelizacion (
    id integer DEFAULT 1 NOT NULL,
    dias_en_riesgo integer DEFAULT 60 NOT NULL,
    dias_inactivo integer DEFAULT 150 NOT NULL,
    visitas_frecuente integer DEFAULT 3 NOT NULL,
    visitas_vip integer DEFAULT 6 NOT NULL,
    visitas_meta integer DEFAULT 5 NOT NULL,
    dias_aviso_cumple integer DEFAULT 7 NOT NULL,
    vigencia_dias integer DEFAULT 30 NOT NULL,
    beneficio_cumple text DEFAULT 'Postre de regalo para toda la mesa'::text NOT NULL,
    beneficio_reactivacion text DEFAULT '15 % de descuento en tu próxima cena'::text NOT NULL,
    beneficio_visitas text DEFAULT 'Una botella de vino de la casa'::text NOT NULL,
    automatico boolean DEFAULT true NOT NULL,
    ultima_ejecucion timestamp with time zone,
    ultimo_resumen jsonb,
    beneficio_bienvenida text DEFAULT 'Una copa de bienvenida en tu próxima visita'::text NOT NULL,
    aviso_sin_correos boolean DEFAULT true NOT NULL,
    tope_diario integer DEFAULT 200 NOT NULL,
    CONSTRAINT ajustes_fidelizacion_beneficio_bienvenida_check CHECK (((char_length(beneficio_bienvenida) >= 3) AND (char_length(beneficio_bienvenida) <= 120))),
    CONSTRAINT ajustes_fidelizacion_beneficio_cumple_check CHECK (((char_length(beneficio_cumple) >= 3) AND (char_length(beneficio_cumple) <= 120))),
    CONSTRAINT ajustes_fidelizacion_beneficio_reactivacion_check CHECK (((char_length(beneficio_reactivacion) >= 3) AND (char_length(beneficio_reactivacion) <= 120))),
    CONSTRAINT ajustes_fidelizacion_beneficio_visitas_check CHECK (((char_length(beneficio_visitas) >= 3) AND (char_length(beneficio_visitas) <= 120))),
    CONSTRAINT ajustes_fidelizacion_dias_aviso_cumple_check CHECK (((dias_aviso_cumple >= 0) AND (dias_aviso_cumple <= 30))),
    CONSTRAINT ajustes_fidelizacion_dias_en_riesgo_check CHECK (((dias_en_riesgo >= 15) AND (dias_en_riesgo <= 365))),
    CONSTRAINT ajustes_fidelizacion_dias_inactivo_check CHECK (((dias_inactivo >= 30) AND (dias_inactivo <= 730))),
    CONSTRAINT ajustes_fidelizacion_id_check CHECK ((id = 1)),
    CONSTRAINT ajustes_fidelizacion_tope_diario_check CHECK (((tope_diario >= 10) AND (tope_diario <= 5000))),
    CONSTRAINT ajustes_fidelizacion_vigencia_dias_check CHECK (((vigencia_dias >= 7) AND (vigencia_dias <= 180))),
    CONSTRAINT ajustes_fidelizacion_visitas_frecuente_check CHECK (((visitas_frecuente >= 2) AND (visitas_frecuente <= 50))),
    CONSTRAINT ajustes_fidelizacion_visitas_meta_check CHECK (((visitas_meta >= 2) AND (visitas_meta <= 50))),
    CONSTRAINT ajustes_fidelizacion_visitas_vip_check CHECK (((visitas_vip >= 3) AND (visitas_vip <= 100))),
    CONSTRAINT frecuente_antes_que_vip CHECK ((visitas_frecuente < visitas_vip)),
    CONSTRAINT riesgo_antes_que_inactivo CHECK ((dias_en_riesgo < dias_inactivo))
);

--
-- Name: ajustes_personal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ajustes_personal (
    id integer DEFAULT 1 NOT NULL,
    cubiertos_por_mozo integer DEFAULT 20 NOT NULL,
    mozos_minimos integer DEFAULT 2 NOT NULL,
    CONSTRAINT ajustes_personal_cubiertos_por_mozo_check CHECK (((cubiertos_por_mozo >= 5) AND (cubiertos_por_mozo <= 60))),
    CONSTRAINT ajustes_personal_id_check CHECK ((id = 1)),
    CONSTRAINT ajustes_personal_mozos_minimos_check CHECK (((mozos_minimos >= 1) AND (mozos_minimos <= 20)))
);

--
-- Name: ajustes_reserva; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ajustes_reserva (
    id integer DEFAULT 1 NOT NULL,
    apertura time without time zone DEFAULT '19:00:00'::time without time zone NOT NULL,
    cierre time without time zone DEFAULT '00:00:00'::time without time zone NOT NULL,
    intervalo_min integer DEFAULT 15 NOT NULL,
    limpieza_min integer DEFAULT 15 NOT NULL,
    max_personas_por_turno integer DEFAULT 12 NOT NULL,
    holgura_mesa integer DEFAULT 1 NOT NULL,
    CONSTRAINT ajustes_holgura_ok CHECK (((holgura_mesa >= 0) AND (holgura_mesa <= 4))),
    CONSTRAINT ajustes_reserva_id_check CHECK ((id = 1)),
    CONSTRAINT ajustes_reserva_intervalo_min_check CHECK ((intervalo_min = ANY (ARRAY[10, 15, 20, 30]))),
    CONSTRAINT ajustes_reserva_limpieza_min_check CHECK (((limpieza_min >= 0) AND (limpieza_min <= 60))),
    CONSTRAINT ajustes_reserva_max_personas_por_turno_check CHECK ((max_personas_por_turno > 0))
);

--
-- Name: beneficio; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.beneficio (
    id_beneficio bigint NOT NULL,
    codigo text NOT NULL,
    id_usuario uuid NOT NULL,
    tipo text NOT NULL,
    descripcion text NOT NULL,
    periodo text NOT NULL,
    id_campana bigint,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    vence_en date NOT NULL,
    usado_en timestamp with time zone,
    usado_por uuid,
    correo_enviado boolean DEFAULT false NOT NULL,
    CONSTRAINT beneficio_tipo_check CHECK ((tipo = ANY (ARRAY['cumpleanos'::text, 'reactivacion'::text, 'visitas'::text, 'campana'::text, 'bienvenida'::text])))
);

--
-- Name: beneficio_id_beneficio_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.beneficio ALTER COLUMN id_beneficio ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.beneficio_id_beneficio_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: campana_id_campana_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.campana ALTER COLUMN id_campana ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.campana_id_campana_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: clima_dia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clima_dia (
    fecha date NOT NULL,
    temp_max numeric(4,1),
    temp_noche numeric(4,1),
    lluvia_mm numeric(5,1),
    lluvia_noche_mm numeric(5,1),
    prob_lluvia integer,
    codigo integer,
    viento_max numeric(4,1),
    es_pronostico boolean DEFAULT false NOT NULL,
    actualizado timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT clima_dia_prob_lluvia_check CHECK (((prob_lluvia >= 0) AND (prob_lluvia <= 100)))
);

--
-- Name: config_app; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.config_app (
    clave text NOT NULL,
    valor text
);

--
-- Name: duracion_por_grupo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.duracion_por_grupo (
    hasta_personas integer NOT NULL,
    minutos integer NOT NULL,
    CONSTRAINT duracion_por_grupo_hasta_personas_check CHECK ((hasta_personas > 0)),
    CONSTRAINT duracion_por_grupo_minutos_check CHECK (((minutos >= 30) AND (minutos <= 300)))
);

--
-- Name: invitacion_admin; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitacion_admin (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    token_hash text NOT NULL,
    creada_por uuid,
    creada_en timestamp with time zone DEFAULT now() NOT NULL,
    vence_en timestamp with time zone DEFAULT (now() + '48:00:00'::interval) NOT NULL,
    usada_en timestamp with time zone,
    usada_por uuid,
    revocada boolean DEFAULT false NOT NULL
);

--
-- Name: mesa_id_mesa_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.mesa ALTER COLUMN id_mesa ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.mesa_id_mesa_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: personal_dia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_dia (
    fecha date NOT NULL,
    mozos integer NOT NULL,
    notas text,
    cargado_por uuid DEFAULT auth.uid(),
    actualizado timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT personal_dia_mozos_check CHECK (((mozos >= 0) AND (mozos <= 60))),
    CONSTRAINT personal_dia_notas_check CHECK ((char_length(notas) <= 200))
);

--
-- Name: registro_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.registro_roles (
    id bigint NOT NULL,
    id_usuario uuid NOT NULL,
    rol_anterior text,
    rol_nuevo text NOT NULL,
    cambiado_por uuid,
    fecha timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: registro_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.registro_roles ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.registro_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: reserva_id_reserva_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.reserva ALTER COLUMN id_reserva ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.reserva_id_reserva_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: uso_ia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uso_ia (
    id bigint NOT NULL,
    id_usuario uuid,
    fecha timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: uso_ia_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.uso_ia ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.uso_ia_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: usuario; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usuario (
    id_usuario uuid NOT NULL,
    nombre text DEFAULT ''::text NOT NULL,
    email text NOT NULL,
    rol text DEFAULT 'cliente'::text NOT NULL,
    fecha_nacimiento date,
    fecha_creacion timestamp with time zone DEFAULT now() NOT NULL,
    fecha_acepta_privacidad timestamp with time zone,
    telefono text,
    acepta_promociones boolean DEFAULT false NOT NULL,
    fecha_acepta_promociones timestamp with time zone,
    CONSTRAINT usuario_rol_check CHECK ((rol = ANY (ARRAY['cliente'::text, 'admin'::text])))
);

--
-- Name: version_esquema; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.version_esquema (
    version integer NOT NULL,
    nombre text NOT NULL,
    aplicada_en timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: ajustes_fidelizacion ajustes_fidelizacion_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ajustes_fidelizacion
    ADD CONSTRAINT ajustes_fidelizacion_pkey PRIMARY KEY (id);

--
-- Name: ajustes_personal ajustes_personal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ajustes_personal
    ADD CONSTRAINT ajustes_personal_pkey PRIMARY KEY (id);

--
-- Name: ajustes_reserva ajustes_reserva_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ajustes_reserva
    ADD CONSTRAINT ajustes_reserva_pkey PRIMARY KEY (id);

--
-- Name: beneficio beneficio_codigo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beneficio
    ADD CONSTRAINT beneficio_codigo_key UNIQUE (codigo);

--
-- Name: beneficio beneficio_id_usuario_tipo_periodo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beneficio
    ADD CONSTRAINT beneficio_id_usuario_tipo_periodo_key UNIQUE (id_usuario, tipo, periodo);

--
-- Name: beneficio beneficio_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beneficio
    ADD CONSTRAINT beneficio_pkey PRIMARY KEY (id_beneficio);

--
-- Name: campana campana_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campana
    ADD CONSTRAINT campana_pkey PRIMARY KEY (id_campana);

--
-- Name: clima_dia clima_dia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clima_dia
    ADD CONSTRAINT clima_dia_pkey PRIMARY KEY (fecha);

--
-- Name: config_app config_app_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.config_app
    ADD CONSTRAINT config_app_pkey PRIMARY KEY (clave);

--
-- Name: duracion_por_grupo duracion_por_grupo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.duracion_por_grupo
    ADD CONSTRAINT duracion_por_grupo_pkey PRIMARY KEY (hasta_personas);

--
-- Name: invitacion_admin invitacion_admin_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitacion_admin
    ADD CONSTRAINT invitacion_admin_pkey PRIMARY KEY (id);

--
-- Name: invitacion_admin invitacion_admin_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitacion_admin
    ADD CONSTRAINT invitacion_admin_token_hash_key UNIQUE (token_hash);

--
-- Name: mesa mesa_numero_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesa
    ADD CONSTRAINT mesa_numero_key UNIQUE (numero);

--
-- Name: mesa mesa_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mesa
    ADD CONSTRAINT mesa_pkey PRIMARY KEY (id_mesa);

--
-- Name: personal_dia personal_dia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_dia
    ADD CONSTRAINT personal_dia_pkey PRIMARY KEY (fecha);

--
-- Name: registro_roles registro_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.registro_roles
    ADD CONSTRAINT registro_roles_pkey PRIMARY KEY (id);

--
-- Name: reserva reserva_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reserva
    ADD CONSTRAINT reserva_pkey PRIMARY KEY (id_reserva);

--
-- Name: reserva sin_superposicion; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reserva
    ADD CONSTRAINT sin_superposicion EXCLUDE USING gist (id_mesa WITH =, franja WITH &&) WHERE ((estado = ANY (ARRAY['confirmada'::text, 'sentada'::text])));

--
-- Name: uso_ia uso_ia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uso_ia
    ADD CONSTRAINT uso_ia_pkey PRIMARY KEY (id);

--
-- Name: usuario usuario_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuario
    ADD CONSTRAINT usuario_pkey PRIMARY KEY (id_usuario);

--
-- Name: version_esquema version_esquema_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.version_esquema
    ADD CONSTRAINT version_esquema_pkey PRIMARY KEY (version);

--
-- Name: beneficio_campana_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX beneficio_campana_idx ON public.beneficio USING btree (id_campana);

--
-- Name: beneficio_creado_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX beneficio_creado_idx ON public.beneficio USING btree (creado_en DESC);

--
-- Name: beneficio_usado_por_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX beneficio_usado_por_idx ON public.beneficio USING btree (usado_por);

--
-- Name: campana_creada_en_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX campana_creada_en_idx ON public.campana USING btree (creada_en DESC);

--
-- Name: campana_creada_por_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX campana_creada_por_idx ON public.campana USING btree (creada_por);

--
-- Name: invitacion_creada_por_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invitacion_creada_por_idx ON public.invitacion_admin USING btree (creada_por);

--
-- Name: invitacion_usada_por_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invitacion_usada_por_idx ON public.invitacion_admin USING btree (usada_por);

--
-- Name: personal_cargado_por_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX personal_cargado_por_idx ON public.personal_dia USING btree (cargado_por);

--
-- Name: registro_roles_usuario_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX registro_roles_usuario_idx ON public.registro_roles USING btree (id_usuario);

--
-- Name: reserva_fecha_hora_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reserva_fecha_hora_idx ON public.reserva USING btree (fecha, hora);

--
-- Name: reserva_usuario_fecha_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reserva_usuario_fecha_idx ON public.reserva USING btree (id_usuario, fecha);

--
-- Name: uso_ia_fecha_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX uso_ia_fecha_idx ON public.uso_ia USING btree (fecha);

--
-- Name: uso_ia_usuario_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX uso_ia_usuario_idx ON public.uso_ia USING btree (id_usuario);

--
-- Name: usuario_buscar_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usuario_buscar_idx ON public.usuario USING gin (lower(((nombre || ' '::text) || email)) extensions.gin_trgm_ops);

--
-- Name: usuario_email_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usuario_email_idx ON public.usuario USING btree (lower(email));

--
-- Name: usuario_rol_nombre_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX usuario_rol_nombre_idx ON public.usuario USING btree (rol, nombre);

--
-- Name: usuario al_cambiar_rol; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER al_cambiar_rol AFTER UPDATE OF rol ON public.usuario FOR EACH ROW EXECUTE FUNCTION public.auditar_rol();

--
-- Name: reserva antes_de_guardar_reserva; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER antes_de_guardar_reserva BEFORE INSERT OR UPDATE ON public.reserva FOR EACH ROW EXECUTE FUNCTION public.validar_capacidad();

--
-- Name: usuario antes_de_guardar_usuario; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER antes_de_guardar_usuario BEFORE INSERT OR UPDATE ON public.usuario FOR EACH ROW EXECUTE FUNCTION public.validar_datos_cliente();

--
-- Name: usuario despues_de_aceptar_correos; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER despues_de_aceptar_correos AFTER INSERT OR UPDATE OF acepta_promociones ON public.usuario FOR EACH ROW EXECUTE FUNCTION public.al_aceptar_correos();

--
-- Name: reserva despues_de_reserva; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER despues_de_reserva AFTER INSERT OR UPDATE ON public.reserva FOR EACH ROW EXECUTE FUNCTION public.notificar_reserva();

--
-- Name: reserva despues_de_reservar_sin_correos; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER despues_de_reservar_sin_correos AFTER INSERT ON public.reserva FOR EACH ROW EXECUTE FUNCTION public.avisar_cliente_sin_correos();

--
-- Name: reserva despues_de_sumar_visita; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER despues_de_sumar_visita AFTER UPDATE OF estado ON public.reserva FOR EACH ROW EXECUTE FUNCTION public.al_sumar_visita();

--
-- Name: beneficio beneficio_id_campana_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beneficio
    ADD CONSTRAINT beneficio_id_campana_fkey FOREIGN KEY (id_campana) REFERENCES public.campana(id_campana) ON DELETE SET NULL;

--
-- Name: beneficio beneficio_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beneficio
    ADD CONSTRAINT beneficio_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario) ON DELETE CASCADE;

--
-- Name: beneficio beneficio_usado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beneficio
    ADD CONSTRAINT beneficio_usado_por_fkey FOREIGN KEY (usado_por) REFERENCES public.usuario(id_usuario);

--
-- Name: campana campana_creada_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campana
    ADD CONSTRAINT campana_creada_por_fkey FOREIGN KEY (creada_por) REFERENCES public.usuario(id_usuario);

--
-- Name: invitacion_admin invitacion_admin_creada_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitacion_admin
    ADD CONSTRAINT invitacion_admin_creada_por_fkey FOREIGN KEY (creada_por) REFERENCES public.usuario(id_usuario);

--
-- Name: invitacion_admin invitacion_admin_usada_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitacion_admin
    ADD CONSTRAINT invitacion_admin_usada_por_fkey FOREIGN KEY (usada_por) REFERENCES public.usuario(id_usuario);

--
-- Name: personal_dia personal_dia_cargado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_dia
    ADD CONSTRAINT personal_dia_cargado_por_fkey FOREIGN KEY (cargado_por) REFERENCES public.usuario(id_usuario);

--
-- Name: registro_roles registro_roles_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.registro_roles
    ADD CONSTRAINT registro_roles_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario) ON DELETE CASCADE;

--
-- Name: reserva reserva_id_mesa_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reserva
    ADD CONSTRAINT reserva_id_mesa_fkey FOREIGN KEY (id_mesa) REFERENCES public.mesa(id_mesa);

--
-- Name: reserva reserva_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reserva
    ADD CONSTRAINT reserva_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario);

--
-- Name: uso_ia uso_ia_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uso_ia
    ADD CONSTRAINT uso_ia_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario) ON DELETE SET NULL;

--
-- Name: usuario usuario_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuario
    ADD CONSTRAINT usuario_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES auth.users(id) ON DELETE CASCADE;

--
-- Name: duracion_por_grupo admin borra duraciones; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin borra duraciones" ON public.duracion_por_grupo FOR DELETE TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: mesa admin borra mesas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin borra mesas" ON public.mesa FOR DELETE TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: reserva admin borra reservas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin borra reservas" ON public.reserva FOR DELETE TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: ajustes_personal admin cambia ajustes de personal; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin cambia ajustes de personal" ON public.ajustes_personal FOR UPDATE TO authenticated USING (( SELECT public.es_admin() AS es_admin)) WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: ajustes_fidelizacion admin cambia reglas de fidelizacion; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin cambia reglas de fidelizacion" ON public.ajustes_fidelizacion FOR UPDATE TO authenticated USING (( SELECT public.es_admin() AS es_admin)) WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: duracion_por_grupo admin crea duraciones; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin crea duraciones" ON public.duracion_por_grupo FOR INSERT TO authenticated WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: mesa admin crea mesas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin crea mesas" ON public.mesa FOR INSERT TO authenticated WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: reserva admin crea reservas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin crea reservas" ON public.reserva FOR INSERT TO authenticated WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: ajustes_reserva admin edita ajustes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin edita ajustes" ON public.ajustes_reserva FOR UPDATE TO authenticated USING (( SELECT public.es_admin() AS es_admin)) WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: personal_dia admin gestiona el personal; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin gestiona el personal" ON public.personal_dia TO authenticated USING (( SELECT public.es_admin() AS es_admin)) WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: duracion_por_grupo admin modifica duraciones; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin modifica duraciones" ON public.duracion_por_grupo FOR UPDATE TO authenticated USING (( SELECT public.es_admin() AS es_admin)) WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: mesa admin modifica mesas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin modifica mesas" ON public.mesa FOR UPDATE TO authenticated USING (( SELECT public.es_admin() AS es_admin)) WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: reserva admin modifica reservas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin modifica reservas" ON public.reserva FOR UPDATE TO authenticated USING (( SELECT public.es_admin() AS es_admin)) WITH CHECK (( SELECT public.es_admin() AS es_admin));

--
-- Name: ajustes_personal admin ve ajustes de personal; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin ve ajustes de personal" ON public.ajustes_personal FOR SELECT TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: campana admin ve campanas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin ve campanas" ON public.campana FOR SELECT TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: clima_dia admin ve el clima; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin ve el clima" ON public.clima_dia FOR SELECT TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: invitacion_admin admin ve invitaciones; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin ve invitaciones" ON public.invitacion_admin FOR SELECT TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: registro_roles admin ve registro de roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin ve registro de roles" ON public.registro_roles FOR SELECT TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: ajustes_fidelizacion admin ve reglas de fidelizacion; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin ve reglas de fidelizacion" ON public.ajustes_fidelizacion FOR SELECT TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: uso_ia admin ve uso de ia; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin ve uso de ia" ON public.uso_ia FOR SELECT TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: version_esquema admin ve versiones; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin ve versiones" ON public.version_esquema FOR SELECT TO authenticated USING (( SELECT public.es_admin() AS es_admin));

--
-- Name: ajustes_fidelizacion; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ajustes_fidelizacion ENABLE ROW LEVEL SECURITY;

--
-- Name: ajustes_personal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ajustes_personal ENABLE ROW LEVEL SECURITY;

--
-- Name: ajustes_reserva; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ajustes_reserva ENABLE ROW LEVEL SECURITY;

--
-- Name: beneficio; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.beneficio ENABLE ROW LEVEL SECURITY;

--
-- Name: campana; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.campana ENABLE ROW LEVEL SECURITY;

--
-- Name: clima_dia; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.clima_dia ENABLE ROW LEVEL SECURITY;

--
-- Name: config_app; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.config_app ENABLE ROW LEVEL SECURITY;

--
-- Name: duracion_por_grupo; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.duracion_por_grupo ENABLE ROW LEVEL SECURITY;

--
-- Name: usuario editar mi perfil; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "editar mi perfil" ON public.usuario FOR UPDATE TO authenticated USING ((id_usuario = ( SELECT auth.uid() AS uid))) WITH CHECK ((id_usuario = ( SELECT auth.uid() AS uid)));

--
-- Name: invitacion_admin; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.invitacion_admin ENABLE ROW LEVEL SECURITY;

--
-- Name: mesa; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.mesa ENABLE ROW LEVEL SECURITY;

--
-- Name: config_app nadie lee la configuracion; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "nadie lee la configuracion" ON public.config_app FOR SELECT TO authenticated USING (false);

--
-- Name: personal_dia; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.personal_dia ENABLE ROW LEVEL SECURITY;

--
-- Name: registro_roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.registro_roles ENABLE ROW LEVEL SECURITY;

--
-- Name: reserva; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reserva ENABLE ROW LEVEL SECURITY;

--
-- Name: ajustes_reserva todos leen ajustes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "todos leen ajustes" ON public.ajustes_reserva FOR SELECT TO authenticated USING (true);

--
-- Name: duracion_por_grupo todos leen duraciones; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "todos leen duraciones" ON public.duracion_por_grupo FOR SELECT TO authenticated USING (true);

--
-- Name: mesa todos ven las mesas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "todos ven las mesas" ON public.mesa FOR SELECT TO authenticated USING (true);

--
-- Name: uso_ia; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.uso_ia ENABLE ROW LEVEL SECURITY;

--
-- Name: usuario; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.usuario ENABLE ROW LEVEL SECURITY;

--
-- Name: usuario ver mi perfil o admin ve todos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "ver mi perfil o admin ve todos" ON public.usuario FOR SELECT TO authenticated USING (((id_usuario = ( SELECT auth.uid() AS uid)) OR ( SELECT public.es_admin() AS es_admin)));

--
-- Name: beneficio ver mis beneficios o admin ve todos; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "ver mis beneficios o admin ve todos" ON public.beneficio FOR SELECT TO authenticated USING (((id_usuario = ( SELECT auth.uid() AS uid)) OR ( SELECT public.es_admin() AS es_admin)));

--
-- Name: reserva ver mis reservas o admin ve todas; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "ver mis reservas o admin ve todas" ON public.reserva FOR SELECT TO authenticated USING (((id_usuario = ( SELECT auth.uid() AS uid)) OR ( SELECT public.es_admin() AS es_admin)));

--
-- Name: version_esquema; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.version_esquema ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

--
-- Name: FUNCTION aceptar_invitacion(p_token text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.aceptar_invitacion(p_token text) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.aceptar_invitacion(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.aceptar_invitacion(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.aceptar_invitacion(p_token text) TO service_role;

--
-- Name: FUNCTION al_aceptar_correos(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.al_aceptar_correos() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.al_aceptar_correos() FROM PUBLIC;
GRANT ALL ON FUNCTION public.al_aceptar_correos() TO service_role;

--
-- Name: FUNCTION al_sumar_visita(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.al_sumar_visita() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.al_sumar_visita() FROM PUBLIC;
GRANT ALL ON FUNCTION public.al_sumar_visita() TO service_role;

--
-- Name: FUNCTION auditar_rol(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.auditar_rol() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.auditar_rol() FROM PUBLIC;
GRANT ALL ON FUNCTION public.auditar_rol() TO service_role;

--
-- Name: FUNCTION avisar_cliente_sin_correos(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.avisar_cliente_sin_correos() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.avisar_cliente_sin_correos() FROM PUBLIC;
GRANT ALL ON FUNCTION public.avisar_cliente_sin_correos() TO service_role;

--
-- Name: FUNCTION avisar_n8n(p_datos jsonb); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.avisar_n8n(p_datos jsonb) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.avisar_n8n(p_datos jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.avisar_n8n(p_datos jsonb) TO service_role;

--
-- Name: FUNCTION buscar_clientes(p_texto text, p_limite integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.buscar_clientes(p_texto text, p_limite integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.buscar_clientes(p_texto text, p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.buscar_clientes(p_texto text, p_limite integer) TO authenticated;
GRANT ALL ON FUNCTION public.buscar_clientes(p_texto text, p_limite integer) TO service_role;

--
-- Name: FUNCTION cancelar_mi_reserva(p_id_reserva bigint); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.cancelar_mi_reserva(p_id_reserva bigint) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.cancelar_mi_reserva(p_id_reserva bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancelar_mi_reserva(p_id_reserva bigint) TO authenticated;
GRANT ALL ON FUNCTION public.cancelar_mi_reserva(p_id_reserva bigint) TO service_role;

--
-- Name: FUNCTION canjear_beneficio(p_codigo text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.canjear_beneficio(p_codigo text) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.canjear_beneficio(p_codigo text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.canjear_beneficio(p_codigo text) TO authenticated;
GRANT ALL ON FUNCTION public.canjear_beneficio(p_codigo text) TO service_role;

--
-- Name: FUNCTION cierre_de(p_fecha date); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.cierre_de(p_fecha date) FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.cierre_de(p_fecha date) TO anon;
GRANT ALL ON FUNCTION public.cierre_de(p_fecha date) TO authenticated;
GRANT ALL ON FUNCTION public.cierre_de(p_fecha date) TO service_role;

--
-- Name: FUNCTION clientes_de_campana(p_segmento text, p_zona text, p_grupo text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.clientes_de_campana(p_segmento text, p_zona text, p_grupo text) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.clientes_de_campana(p_segmento text, p_zona text, p_grupo text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.clientes_de_campana(p_segmento text, p_zona text, p_grupo text) TO service_role;

--
-- Name: FUNCTION clientes_fidelizacion(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.clientes_fidelizacion() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.clientes_fidelizacion() FROM PUBLIC;
GRANT ALL ON FUNCTION public.clientes_fidelizacion() TO authenticated;
GRANT ALL ON FUNCTION public.clientes_fidelizacion() TO service_role;

--
-- Name: FUNCTION clientes_fidelizacion_pagina(p_segmento text, p_buscar text, p_limite integer, p_desde integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.clientes_fidelizacion_pagina(p_segmento text, p_buscar text, p_limite integer, p_desde integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.clientes_fidelizacion_pagina(p_segmento text, p_buscar text, p_limite integer, p_desde integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.clientes_fidelizacion_pagina(p_segmento text, p_buscar text, p_limite integer, p_desde integer) TO authenticated;
GRANT ALL ON FUNCTION public.clientes_fidelizacion_pagina(p_segmento text, p_buscar text, p_limite integer, p_desde integer) TO service_role;

--
-- Name: FUNCTION clientes_panel(p_buscar text, p_limite integer, p_desde integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.clientes_panel(p_buscar text, p_limite integer, p_desde integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.clientes_panel(p_buscar text, p_limite integer, p_desde integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.clientes_panel(p_buscar text, p_limite integer, p_desde integer) TO authenticated;
GRANT ALL ON FUNCTION public.clientes_panel(p_buscar text, p_limite integer, p_desde integer) TO service_role;

--
-- Name: FUNCTION config(p_clave text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.config(p_clave text) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.config(p_clave text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.config(p_clave text) TO service_role;

--
-- Name: FUNCTION consultar_beneficio(p_codigo text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.consultar_beneficio(p_codigo text) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.consultar_beneficio(p_codigo text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.consultar_beneficio(p_codigo text) TO authenticated;
GRANT ALL ON FUNCTION public.consultar_beneficio(p_codigo text) TO service_role;

--
-- Name: FUNCTION consultar_turno(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.consultar_turno(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint) FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.consultar_turno(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint) TO anon;
GRANT ALL ON FUNCTION public.consultar_turno(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint) TO authenticated;
GRANT ALL ON FUNCTION public.consultar_turno(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint) TO service_role;

--
-- Name: FUNCTION contar_visitas(p_usuario uuid); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.contar_visitas(p_usuario uuid) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.contar_visitas(p_usuario uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.contar_visitas(p_usuario uuid) TO service_role;

--
-- Name: TABLE reserva; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.reserva FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.reserva TO anon;
GRANT ALL ON TABLE public.reserva TO authenticated;
GRANT ALL ON TABLE public.reserva TO service_role;

--
-- Name: FUNCTION crear_reserva(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint, p_ocasion text, p_comentarios text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.crear_reserva(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint, p_ocasion text, p_comentarios text) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.crear_reserva(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint, p_ocasion text, p_comentarios text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.crear_reserva(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint, p_ocasion text, p_comentarios text) TO authenticated;
GRANT ALL ON FUNCTION public.crear_reserva(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint, p_ocasion text, p_comentarios text) TO service_role;

--
-- Name: FUNCTION crear_usuario_nuevo(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.crear_usuario_nuevo() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.crear_usuario_nuevo() FROM PUBLIC;
GRANT ALL ON FUNCTION public.crear_usuario_nuevo() TO service_role;

--
-- Name: FUNCTION dar_beneficio(p_usuario uuid, p_tipo text, p_periodo text, p_descripcion text, p_vence date, p_campana bigint, p_extra jsonb); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.dar_beneficio(p_usuario uuid, p_tipo text, p_periodo text, p_descripcion text, p_vence date, p_campana bigint, p_extra jsonb) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.dar_beneficio(p_usuario uuid, p_tipo text, p_periodo text, p_descripcion text, p_vence date, p_campana bigint, p_extra jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dar_beneficio(p_usuario uuid, p_tipo text, p_periodo text, p_descripcion text, p_vence date, p_campana bigint, p_extra jsonb) TO service_role;

--
-- Name: FUNCTION datos_clientes(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.datos_clientes() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.datos_clientes() FROM PUBLIC;
GRANT ALL ON FUNCTION public.datos_clientes() TO service_role;

--
-- Name: FUNCTION datos_clientes_de(p_usuario uuid); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.datos_clientes_de(p_usuario uuid) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.datos_clientes_de(p_usuario uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.datos_clientes_de(p_usuario uuid) TO service_role;

--
-- Name: FUNCTION destinatarios_campana(p_segmento text, p_zona text, p_grupo text, p_limite integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.destinatarios_campana(p_segmento text, p_zona text, p_grupo text, p_limite integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.destinatarios_campana(p_segmento text, p_zona text, p_grupo text, p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.destinatarios_campana(p_segmento text, p_zona text, p_grupo text, p_limite integer) TO authenticated;
GRANT ALL ON FUNCTION public.destinatarios_campana(p_segmento text, p_zona text, p_grupo text, p_limite integer) TO service_role;

--
-- Name: FUNCTION duracion_para(p_personas integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.duracion_para(p_personas integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.duracion_para(p_personas integer) TO anon;
GRANT ALL ON FUNCTION public.duracion_para(p_personas integer) TO authenticated;
GRANT ALL ON FUNCTION public.duracion_para(p_personas integer) TO service_role;

--
-- Name: FUNCTION ejecutar_fidelizacion(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.ejecutar_fidelizacion() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.ejecutar_fidelizacion() FROM PUBLIC;
GRANT ALL ON FUNCTION public.ejecutar_fidelizacion() TO authenticated;
GRANT ALL ON FUNCTION public.ejecutar_fidelizacion() TO service_role;

--
-- Name: FUNCTION es_admin(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.es_admin() FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.es_admin() TO anon;
GRANT ALL ON FUNCTION public.es_admin() TO authenticated;
GRANT ALL ON FUNCTION public.es_admin() TO service_role;

--
-- Name: FUNCTION estado_mesas(p_fecha date, p_hora time without time zone, p_personas integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.estado_mesas(p_fecha date, p_hora time without time zone, p_personas integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.estado_mesas(p_fecha date, p_hora time without time zone, p_personas integer) TO anon;
GRANT ALL ON FUNCTION public.estado_mesas(p_fecha date, p_hora time without time zone, p_personas integer) TO authenticated;
GRANT ALL ON FUNCTION public.estado_mesas(p_fecha date, p_hora time without time zone, p_personas integer) TO service_role;

--
-- Name: FUNCTION extender_reserva(p_id_reserva bigint, p_minutos integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.extender_reserva(p_id_reserva bigint, p_minutos integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.extender_reserva(p_id_reserva bigint, p_minutos integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.extender_reserva(p_id_reserva bigint, p_minutos integer) TO authenticated;
GRANT ALL ON FUNCTION public.extender_reserva(p_id_reserva bigint, p_minutos integer) TO service_role;

--
-- Name: FUNCTION fidelizacion_diaria(p_forzar boolean); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.fidelizacion_diaria(p_forzar boolean) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.fidelizacion_diaria(p_forzar boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fidelizacion_diaria(p_forzar boolean) TO service_role;

--
-- Name: FUNCTION generar_codigo(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.generar_codigo() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.generar_codigo() FROM PUBLIC;
GRANT ALL ON FUNCTION public.generar_codigo() TO service_role;

--
-- Name: FUNCTION guardar_clima(p_dias jsonb); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.guardar_clima(p_dias jsonb) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.guardar_clima(p_dias jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.guardar_clima(p_dias jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.guardar_clima(p_dias jsonb) TO service_role;

--
-- Name: FUNCTION historial_noches(p_desde date, p_hasta date); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.historial_noches(p_desde date, p_hasta date) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.historial_noches(p_desde date, p_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.historial_noches(p_desde date, p_hasta date) TO authenticated;
GRANT ALL ON FUNCTION public.historial_noches(p_desde date, p_hasta date) TO service_role;

--
-- Name: FUNCTION horarios_alternativos(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.horarios_alternativos(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint) FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.horarios_alternativos(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint) TO anon;
GRANT ALL ON FUNCTION public.horarios_alternativos(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint) TO authenticated;
GRANT ALL ON FUNCTION public.horarios_alternativos(p_fecha date, p_hora time without time zone, p_personas integer, p_id_mesa bigint) TO service_role;

--
-- Name: FUNCTION hoy_uy(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.hoy_uy() FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.hoy_uy() TO anon;
GRANT ALL ON FUNCTION public.hoy_uy() TO authenticated;
GRANT ALL ON FUNCTION public.hoy_uy() TO service_role;

--
-- Name: FUNCTION html_seguro(p_texto text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.html_seguro(p_texto text) FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.html_seguro(p_texto text) TO anon;
GRANT ALL ON FUNCTION public.html_seguro(p_texto text) TO authenticated;
GRANT ALL ON FUNCTION public.html_seguro(p_texto text) TO service_role;

--
-- Name: FUNCTION invitar_a_sumarse(p_fecha date); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.invitar_a_sumarse(p_fecha date) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.invitar_a_sumarse(p_fecha date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.invitar_a_sumarse(p_fecha date) TO authenticated;
GRANT ALL ON FUNCTION public.invitar_a_sumarse(p_fecha date) TO service_role;

--
-- Name: FUNCTION invitar_admin(p_email text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.invitar_admin(p_email text) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.invitar_admin(p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.invitar_admin(p_email text) TO authenticated;
GRANT ALL ON FUNCTION public.invitar_admin(p_email text) TO service_role;

--
-- Name: TABLE campana; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.campana FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.campana TO anon;
GRANT ALL ON TABLE public.campana TO authenticated;
GRANT ALL ON TABLE public.campana TO service_role;

--
-- Name: FUNCTION lanzar_campana(p_nombre text, p_segmento text, p_zona text, p_grupo text, p_asunto text, p_mensaje text, p_beneficio text, p_vigencia_dias integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.lanzar_campana(p_nombre text, p_segmento text, p_zona text, p_grupo text, p_asunto text, p_mensaje text, p_beneficio text, p_vigencia_dias integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.lanzar_campana(p_nombre text, p_segmento text, p_zona text, p_grupo text, p_asunto text, p_mensaje text, p_beneficio text, p_vigencia_dias integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.lanzar_campana(p_nombre text, p_segmento text, p_zona text, p_grupo text, p_asunto text, p_mensaje text, p_beneficio text, p_vigencia_dias integer) TO authenticated;
GRANT ALL ON FUNCTION public.lanzar_campana(p_nombre text, p_segmento text, p_zona text, p_grupo text, p_asunto text, p_mensaje text, p_beneficio text, p_vigencia_dias integer) TO service_role;

--
-- Name: FUNCTION mantenimiento(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.mantenimiento() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.mantenimiento() FROM PUBLIC;
GRANT ALL ON FUNCTION public.mantenimiento() TO service_role;

--
-- Name: FUNCTION mesa_sirve(p_capacidad integer, p_personas integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.mesa_sirve(p_capacidad integer, p_personas integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.mesa_sirve(p_capacidad integer, p_personas integer) TO anon;
GRANT ALL ON FUNCTION public.mesa_sirve(p_capacidad integer, p_personas integer) TO authenticated;
GRANT ALL ON FUNCTION public.mesa_sirve(p_capacidad integer, p_personas integer) TO service_role;

--
-- Name: TABLE mesa; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.mesa FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.mesa TO anon;
GRANT ALL ON TABLE public.mesa TO authenticated;
GRANT ALL ON TABLE public.mesa TO service_role;

--
-- Name: FUNCTION mesas_disponibles(p_fecha date, p_hora time without time zone, p_personas integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.mesas_disponibles(p_fecha date, p_hora time without time zone, p_personas integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.mesas_disponibles(p_fecha date, p_hora time without time zone, p_personas integer) TO anon;
GRANT ALL ON FUNCTION public.mesas_disponibles(p_fecha date, p_hora time without time zone, p_personas integer) TO authenticated;
GRANT ALL ON FUNCTION public.mesas_disponibles(p_fecha date, p_hora time without time zone, p_personas integer) TO service_role;

--
-- Name: FUNCTION mi_fidelizacion(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.mi_fidelizacion() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.mi_fidelizacion() FROM PUBLIC;
GRANT ALL ON FUNCTION public.mi_fidelizacion() TO authenticated;
GRANT ALL ON FUNCTION public.mi_fidelizacion() TO service_role;

--
-- Name: FUNCTION motivo_turno(p_fecha date, p_hora time without time zone, p_personas integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.motivo_turno(p_fecha date, p_hora time without time zone, p_personas integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.motivo_turno(p_fecha date, p_hora time without time zone, p_personas integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.motivo_turno(p_fecha date, p_hora time without time zone, p_personas integer) TO authenticated;
GRANT ALL ON FUNCTION public.motivo_turno(p_fecha date, p_hora time without time zone, p_personas integer) TO service_role;

--
-- Name: FUNCTION notificar_reserva(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.notificar_reserva() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.notificar_reserva() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notificar_reserva() TO service_role;

--
-- Name: FUNCTION quitar_admin(p_id_usuario uuid); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.quitar_admin(p_id_usuario uuid) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.quitar_admin(p_id_usuario uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.quitar_admin(p_id_usuario uuid) TO authenticated;
GRANT ALL ON FUNCTION public.quitar_admin(p_id_usuario uuid) TO service_role;

--
-- Name: FUNCTION resumen_fidelizacion(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.resumen_fidelizacion() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.resumen_fidelizacion() FROM PUBLIC;
GRANT ALL ON FUNCTION public.resumen_fidelizacion() TO authenticated;
GRANT ALL ON FUNCTION public.resumen_fidelizacion() TO service_role;

--
-- Name: FUNCTION resumen_para_ia(p_segmento text, p_zona text, p_grupo text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.resumen_para_ia(p_segmento text, p_zona text, p_grupo text) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.resumen_para_ia(p_segmento text, p_zona text, p_grupo text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resumen_para_ia(p_segmento text, p_zona text, p_grupo text) TO authenticated;
GRANT ALL ON FUNCTION public.resumen_para_ia(p_segmento text, p_zona text, p_grupo text) TO service_role;

--
-- Name: FUNCTION revisar_tarjeta_visitas(p_usuario uuid); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.revisar_tarjeta_visitas(p_usuario uuid) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.revisar_tarjeta_visitas(p_usuario uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.revisar_tarjeta_visitas(p_usuario uuid) TO service_role;

--
-- Name: FUNCTION revocar_invitacion(p_id uuid); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.revocar_invitacion(p_id uuid) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.revocar_invitacion(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.revocar_invitacion(p_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.revocar_invitacion(p_id uuid) TO service_role;

--
-- Name: FUNCTION texto_bienvenida(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.texto_bienvenida() FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.texto_bienvenida() TO anon;
GRANT ALL ON FUNCTION public.texto_bienvenida() TO authenticated;
GRANT ALL ON FUNCTION public.texto_bienvenida() TO service_role;

--
-- Name: FUNCTION texto_duracion(p_min integer); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.texto_duracion(p_min integer) FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON FUNCTION public.texto_duracion(p_min integer) TO anon;
GRANT ALL ON FUNCTION public.texto_duracion(p_min integer) TO authenticated;
GRANT ALL ON FUNCTION public.texto_duracion(p_min integer) TO service_role;

--
-- Name: FUNCTION validar_capacidad(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.validar_capacidad() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.validar_capacidad() FROM PUBLIC;
GRANT ALL ON FUNCTION public.validar_capacidad() TO service_role;

--
-- Name: FUNCTION validar_datos_cliente(); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.validar_datos_cliente() FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.validar_datos_cliente() FROM PUBLIC;
GRANT ALL ON FUNCTION public.validar_datos_cliente() TO service_role;

--
-- Name: FUNCTION vista_previa_campana(p_segmento text, p_zona text, p_grupo text); Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON FUNCTION public.vista_previa_campana(p_segmento text, p_zona text, p_grupo text) FROM anon, authenticated;
-- (permisos de la base original:)
--

REVOKE ALL ON FUNCTION public.vista_previa_campana(p_segmento text, p_zona text, p_grupo text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.vista_previa_campana(p_segmento text, p_zona text, p_grupo text) TO authenticated;
GRANT ALL ON FUNCTION public.vista_previa_campana(p_segmento text, p_zona text, p_grupo text) TO service_role;

--
-- Name: TABLE ajustes_fidelizacion; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.ajustes_fidelizacion FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE ON TABLE public.ajustes_fidelizacion TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE ON TABLE public.ajustes_fidelizacion TO authenticated;
GRANT ALL ON TABLE public.ajustes_fidelizacion TO service_role;

--
-- Name: COLUMN ajustes_fidelizacion.dias_en_riesgo; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(dias_en_riesgo) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.dias_inactivo; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(dias_inactivo) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.visitas_frecuente; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(visitas_frecuente) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.visitas_vip; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(visitas_vip) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.visitas_meta; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(visitas_meta) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.dias_aviso_cumple; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(dias_aviso_cumple) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.vigencia_dias; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(vigencia_dias) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.beneficio_cumple; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(beneficio_cumple) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.beneficio_reactivacion; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(beneficio_reactivacion) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.beneficio_visitas; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(beneficio_visitas) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.automatico; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(automatico) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.beneficio_bienvenida; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(beneficio_bienvenida) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.aviso_sin_correos; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(aviso_sin_correos) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: COLUMN ajustes_fidelizacion.tope_diario; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(tope_diario) ON TABLE public.ajustes_fidelizacion TO authenticated;

--
-- Name: TABLE ajustes_personal; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.ajustes_personal FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.ajustes_personal TO anon;
GRANT ALL ON TABLE public.ajustes_personal TO authenticated;
GRANT ALL ON TABLE public.ajustes_personal TO service_role;

--
-- Name: TABLE ajustes_reserva; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.ajustes_reserva FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.ajustes_reserva TO anon;
GRANT ALL ON TABLE public.ajustes_reserva TO authenticated;
GRANT ALL ON TABLE public.ajustes_reserva TO service_role;

--
-- Name: TABLE beneficio; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.beneficio FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.beneficio TO anon;
GRANT ALL ON TABLE public.beneficio TO authenticated;
GRANT ALL ON TABLE public.beneficio TO service_role;

--
-- Name: SEQUENCE beneficio_id_beneficio_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.beneficio_id_beneficio_seq TO anon;
GRANT ALL ON SEQUENCE public.beneficio_id_beneficio_seq TO authenticated;
GRANT ALL ON SEQUENCE public.beneficio_id_beneficio_seq TO service_role;

--
-- Name: SEQUENCE campana_id_campana_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.campana_id_campana_seq TO anon;
GRANT ALL ON SEQUENCE public.campana_id_campana_seq TO authenticated;
GRANT ALL ON SEQUENCE public.campana_id_campana_seq TO service_role;

--
-- Name: TABLE clima_dia; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.clima_dia FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.clima_dia TO anon;
GRANT ALL ON TABLE public.clima_dia TO authenticated;
GRANT ALL ON TABLE public.clima_dia TO service_role;

--
-- Name: TABLE config_app; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.config_app FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.config_app TO anon;
GRANT ALL ON TABLE public.config_app TO authenticated;
GRANT ALL ON TABLE public.config_app TO service_role;

--
-- Name: TABLE duracion_por_grupo; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.duracion_por_grupo FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.duracion_por_grupo TO anon;
GRANT ALL ON TABLE public.duracion_por_grupo TO authenticated;
GRANT ALL ON TABLE public.duracion_por_grupo TO service_role;

--
-- Name: TABLE invitacion_admin; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.invitacion_admin FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.invitacion_admin TO anon;
GRANT ALL ON TABLE public.invitacion_admin TO authenticated;
GRANT ALL ON TABLE public.invitacion_admin TO service_role;

--
-- Name: SEQUENCE mesa_id_mesa_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.mesa_id_mesa_seq TO anon;
GRANT ALL ON SEQUENCE public.mesa_id_mesa_seq TO authenticated;
GRANT ALL ON SEQUENCE public.mesa_id_mesa_seq TO service_role;

--
-- Name: TABLE personal_dia; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.personal_dia FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.personal_dia TO anon;
GRANT ALL ON TABLE public.personal_dia TO authenticated;
GRANT ALL ON TABLE public.personal_dia TO service_role;

--
-- Name: TABLE registro_roles; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.registro_roles FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.registro_roles TO anon;
GRANT ALL ON TABLE public.registro_roles TO authenticated;
GRANT ALL ON TABLE public.registro_roles TO service_role;

--
-- Name: SEQUENCE registro_roles_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.registro_roles_id_seq TO anon;
GRANT ALL ON SEQUENCE public.registro_roles_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.registro_roles_id_seq TO service_role;

--
-- Name: SEQUENCE reserva_id_reserva_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.reserva_id_reserva_seq TO anon;
GRANT ALL ON SEQUENCE public.reserva_id_reserva_seq TO authenticated;
GRANT ALL ON SEQUENCE public.reserva_id_reserva_seq TO service_role;

--
-- Name: TABLE uso_ia; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.uso_ia FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.uso_ia TO anon;
GRANT ALL ON TABLE public.uso_ia TO authenticated;
GRANT ALL ON TABLE public.uso_ia TO service_role;

--
-- Name: SEQUENCE uso_ia_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.uso_ia_id_seq TO anon;
GRANT ALL ON SEQUENCE public.uso_ia_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.uso_ia_id_seq TO service_role;

--
-- Name: TABLE usuario; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.usuario FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE ON TABLE public.usuario TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE ON TABLE public.usuario TO authenticated;
GRANT ALL ON TABLE public.usuario TO service_role;

--
-- Name: COLUMN usuario.nombre; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(nombre) ON TABLE public.usuario TO authenticated;

--
-- Name: COLUMN usuario.fecha_nacimiento; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(fecha_nacimiento) ON TABLE public.usuario TO authenticated;

--
-- Name: COLUMN usuario.telefono; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(telefono) ON TABLE public.usuario TO authenticated;

--
-- Name: COLUMN usuario.acepta_promociones; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(acepta_promociones) ON TABLE public.usuario TO authenticated;

--
-- Name: TABLE version_esquema; Type: ACL; Schema: public; Owner: -
--
REVOKE ALL ON TABLE public.version_esquema FROM anon, authenticated;
-- (permisos de la base original:)
--

GRANT ALL ON TABLE public.version_esquema TO anon;
GRANT ALL ON TABLE public.version_esquema TO authenticated;
GRANT ALL ON TABLE public.version_esquema TO service_role;

--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

--
-- PostgreSQL database dump complete
--

-- =========================================================
-- DATOS INICIALES: reglas por defecto, tiempos de mesa y plano
-- =========================================================
--
-- PostgreSQL database dump
--

--
-- Data for Name: ajustes_fidelizacion; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.ajustes_fidelizacion (id, dias_en_riesgo, dias_inactivo, visitas_frecuente, visitas_vip, visitas_meta, dias_aviso_cumple, vigencia_dias, beneficio_cumple, beneficio_reactivacion, beneficio_visitas, automatico, ultima_ejecucion, ultimo_resumen, beneficio_bienvenida, aviso_sin_correos, tope_diario) VALUES (1, 60, 150, 3, 6, 5, 7, 30, 'Postre de regalo para toda la mesa', '15 % de descuento en tu próxima cena', 'Una botella de vino de la casa', true, NULL, NULL, 'Una copa de bienvenida en tu próxima visita', true, 200);

--
-- Data for Name: ajustes_personal; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.ajustes_personal (id, cubiertos_por_mozo, mozos_minimos) VALUES (1, 20, 2);

--
-- Data for Name: ajustes_reserva; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.ajustes_reserva (id, apertura, cierre, intervalo_min, limpieza_min, max_personas_por_turno, holgura_mesa) VALUES (1, '19:00:00', '00:00:00', 15, 15, 16, 1);

--
-- Data for Name: duracion_por_grupo; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.duracion_por_grupo (hasta_personas, minutos) VALUES (2, 90);
INSERT INTO public.duracion_por_grupo (hasta_personas, minutos) VALUES (4, 120);
INSERT INTO public.duracion_por_grupo (hasta_personas, minutos) VALUES (6, 150);
INSERT INTO public.duracion_por_grupo (hasta_personas, minutos) VALUES (99, 180);

--
-- Data for Name: mesa; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (1, 1, 2, 'activa', 'redonda', 12.0, 15.0, 'Ventanal');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (2, 2, 2, 'activa', 'redonda', 26.0, 15.0, 'Ventanal');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (3, 3, 2, 'activa', 'redonda', 40.0, 15.0, 'Ventanal');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (4, 4, 2, 'activa', 'redonda', 54.0, 15.0, 'Ventanal');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (5, 5, 2, 'activa', 'redonda', 68.0, 15.0, 'Ventanal');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (6, 6, 2, 'activa', 'redonda', 82.0, 15.0, 'Ventanal');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (7, 7, 4, 'activa', 'cuadrada', 14.0, 34.0, 'Salón');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (15, 8, 4, 'activa', 'cuadrada', 31.0, 34.0, 'Salón');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (16, 9, 4, 'activa', 'cuadrada', 48.0, 34.0, 'Salón');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (17, 10, 4, 'activa', 'cuadrada', 65.0, 34.0, 'Salón');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (18, 11, 4, 'activa', 'cuadrada', 14.0, 51.0, 'Salón');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (19, 12, 4, 'activa', 'cuadrada', 31.0, 51.0, 'Salón');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (20, 13, 4, 'activa', 'cuadrada', 48.0, 51.0, 'Salón');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (21, 14, 4, 'activa', 'cuadrada', 65.0, 51.0, 'Salón');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (22, 15, 8, 'activa', 'rectangular', 90.0, 34.0, 'Barra');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (23, 16, 8, 'activa', 'rectangular', 90.0, 51.0, 'Barra');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (24, 17, 6, 'activa', 'rectangular', 18.0, 69.0, 'Fondo');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (25, 18, 6, 'activa', 'rectangular', 38.0, 69.0, 'Fondo');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (26, 19, 6, 'activa', 'rectangular', 58.0, 69.0, 'Fondo');
INSERT INTO public.mesa (id_mesa, numero, capacidad, estado, forma, pos_x, pos_y, zona) OVERRIDING SYSTEM VALUE VALUES (27, 20, 6, 'activa', 'rectangular', 78.0, 69.0, 'Fondo');

--
-- Name: mesa_id_mesa_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.mesa_id_mesa_seq', 27, true);

--
-- PostgreSQL database dump complete
--

-- Versiones instaladas
insert into public.version_esquema (version, nombre) values (1, 'base de datos'), (2, 'correos y alerta'), (3, 'correos armados'), (4, 'seguridad'), (5, 'tiempos de mesa'), (6, 'plano y alternativas'), (7, 'profesional'), (8, 'invitaciones admin'), (9, 'fidelizacion'), (11, 'correos y clima'), (13, 'escala y orden')
on conflict (version) do nothing;

-- =========================================================
-- AL FINAL: CONFIGURACIÓN (completar con los datos de tu proyecto)
-- =========================================================
insert into public.config_app (clave, valor) values
  ('n8n_webhook_url', null),                                   -- URL del webhook de Make
  ('email_admin', 'correo-del-admin@ejemplo.com'),             -- a quién le llegan los avisos
  ('umbral_ocupacion', '80'),                                  -- % que dispara la alerta
  ('max_reservas_cliente', '3'),                               -- reservas por venir por cliente
  ('sitio_url', 'https://tu-sitio.vercel.app'),                -- dirección de la web
  ('webhook_secreto', replace(gen_random_uuid()::text, '-', ''))   -- clave que valida Make
on conflict (clave) do nothing;

-- Cuando alguien se registra, se crea su fila en USUARIO
drop trigger if exists al_registrarse on auth.users;
create trigger al_registrarse
after insert on auth.users
for each row execute function public.crear_usuario_nuevo();

-- Tareas automáticas (Supabase Cron)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('marea-fidelizacion-diaria', '0 13 * * *', 'select public.fidelizacion_diaria(false)');
    perform cron.schedule('marea-mantenimiento-semanal', '30 6 * * 1', 'select public.mantenimiento()');
  else
    raise notice 'Activá Cron (Database > Extensions > pg_cron) y volvé a correr solo este bloque.';
  end if;
end $$;

select 'Marea instalada (versión 13). Falta completar la configuración y crear el primer admin.' as listo;
