# Marea — Sistema de reservas y fidelización para restaurantes

Aplicación web para que un restaurante gestione **reservas, mesas y clientes** desde un único sistema.
Marea tiene **20 mesas y 84 lugares** en cuatro zonas: ventanal al mar, salón, barra y fondo.
📍 Rambla Lorenzo Batlle Pacheco, Parada 8, Playa Brava, Punta del Este, Maldonado, Uruguay.
Proyecto académico — Incorporación Estratégica · Universidad ORT Uruguay.

🔗 **Demo online:** https://marea-web-sooty.vercel.app

---

## Estado

| Etapa | Estado |
|---|---|
| **Parte A — MVP** | ✅ Completa y funcionando |
| Parte B — Segmentación y fidelización | ✅ Completa y funcionando |

## Qué hace (Parte A)

**Cliente**
- Se registra (nombre, teléfono, correo) e inicia sesión; puede recuperar o cambiar su contraseña.
- En **Mi perfil** ve si es cliente o administrador y edita su nombre, teléfono, cumpleaños y el permiso de promociones.
- Consulta disponibilidad por fecha, horario y cantidad de personas, viendo el **plano del local** con las mesas libres y ocupadas.
- Puede **elegir su mesa** en el plano (o dejar que el sistema asigne la mejor). Solo puede elegir mesas **justas para su grupo**: 4 personas → mesa de 4; 5 personas → mesa de 6 (nunca una de 8).
- Puede indicar una **ocasión especial** (cumpleaños, aniversario, negocios…) y **comentarios** (alergias, silla de bebé).
- Si no hay lugar, el sistema **sugiere los horarios libres más cercanos** o el próximo día con lugar.
- Reserva: el sistema asigna automáticamente la mesa más chica que sirva y le dice hasta qué hora es la mesa.
- Ve sus reservas (próximas y pasadas) y puede cancelarlas.
- Recibe correos automáticos: confirmación, cambios y cancelaciones.

**Administrador** (panel profesional)
- **Navegación por días** (ayer / hoy / mañana) e indicadores: reservas, cubiertos, ocupación pico, gente en el salón ahora, cancelaciones y no-shows.
- **Salón en vivo:** plano con el estado de cada mesa a la hora elegida (libre, llegan pronto, reservada, con clientes, en limpieza). Al tocar una mesa se ven sus reservas del día, la ocasión y los comentarios, con acciones *Sentar*, *Liberar mesa*, *+15 min* y *No vino*.
- **Línea de tiempo:** una fila por mesa y una barra por reserva, con la limpieza rayada y la línea de "ahora".
- **Próximas llegadas** con aviso de demorados, **reservas por horario** y **resumen de los últimos 7 días** (tasas de cancelación y no-show).
- **Reservas:** filtros por día y estado, buscador por nombre, correo o teléfono, creación y edición (con ocasión y comentarios) y **exportar a CSV** (Excel / Google Sheets).
- **Mesas:** plano del local para acomodar las mesas arrastrándolas, capacidad, forma, activar/desactivar, y **tiempos de mesa** configurables.
- **Clientes:** listado con teléfono, reservas, asistencias, cancelaciones, última visita y próxima reserva.
- **Equipo:** administradores por **invitación segura**, invitaciones pendientes (revocables) y registro de cambios de rol.
- **Alerta de ocupación:** aviso en el panel y por correo cuando un horario llega al 80 %.

## Qué hace (Parte B — fidelización)

La Parte B usa los mismos datos de Supabase, suma un paso de **segmentación**, reutiliza el webhook de Make y agrega **IA** para escribir promociones. Todo sale de las reservas: en la demo no hay que cargar nada a mano.

```
Datos almacenados en Supabase ──► Segmentación de clientes ──► Make ──► Acciones de fidelización
(visitas, cumpleaños,              (recencia + frecuencia        ▲       (cumpleaños, reactivación,
 preferencias, permiso)             + preferencias)              │        tarjeta de visitas, promociones)
                                          │                      │
                                          └──► IA (Claude) sugiere el texto de cada promoción
```

**Datos**
- Las **visitas se cuentan solas**: una reserva sentada o completada (o confirmada de un día que ya pasó) es una visita.
- El cliente puede dar su **fecha de cumpleaños** (opcional) y elegir si **acepta recibir promociones** (Ley 18.331). Lo cambia cuando quiere desde **Mi perfil**.
- Las preferencias se calculan solas: zona favorita, día y horario habitual, tamaño del grupo y ocasiones.

**Segmentos (recencia y frecuencia, reglas editables desde el panel)**

| Segmento | Regla inicial |
|---|---|
| VIP | 6+ visitas en el último año |
| Frecuente | 3+ visitas en el último año |
| Nuevo | 0 a 2 visitas |
| En riesgo | 60+ días sin venir y sin reserva próxima |
| Inactivo | 150+ días sin venir y sin reserva próxima |

**Acciones de fidelización** (cupón con código único `MAREA-XXXXXX`, vence y se usa una sola vez)

| Acción | Cuándo | Beneficio inicial |
|---|---|---|
| 🎂 Cumpleaños | 7 días antes, una vez por año | Postre de regalo para toda la mesa |
| 🌊 Reactivación | al pasar a En riesgo o Inactivo, una vez por ausencia | 15 % de descuento en la próxima cena |
| 🍷 Tarjeta de visitas | cada 5 visitas (un sello por visita) | Una botella de vino de la casa |
| ✨ Promoción | el admin la lanza filtrando por segmento, zona favorita y si vienen en pareja o en grupo; **la IA sugiere nombre, asunto, mensaje y beneficio** | cupón opcional |

- Cumpleaños y reactivación se revisan **todos los días a las 10:00** (Supabase Cron). El premio de la tarjeta se entrega **en el momento** en que el admin sienta al grupo o libera la mesa.
- El cliente ve sus cupones y su **tarjeta de sellos** en **Mis beneficios**.
- En el panel, la pestaña **Fidelización** muestra los segmentos, la lista de clientes con sus preferencias y su cumpleaños, el **canje de cupones**, las reglas, el botón *Ejecutar ahora*, las promociones enviadas y cuántos cupones se usaron.

## Integraciones con APIs externas

| API | Para qué | Cómo |
|---|---|---|
| **Anthropic (Claude Haiku 4.5)** | Sugerir promociones según el público elegido | Supabase Edge Function `sugerir-promocion`. La clave está en los *Secrets* de Supabase. A la IA solo le llegan **totales anónimos** (nunca nombres ni correos). Solo admins, máximo 30 por día. |
| **Open-Meteo** (clima) | Pronóstico para el día y la hora de la reserva (cliente) y clima de la noche con un consejo para el servicio (admin) | Llamada directa desde el sitio. Es gratis y sin clave, así que no hay nada secreto en el navegador. |
| **Make + Gmail** | Correos de reservas, alertas, beneficios y promociones | Webhook con secreto compartido |

## Tiempos de mesa (como los sistemas profesionales)

Inspirado en cómo trabajan OpenTable, Resy o SevenRooms:

| Regla | Valor inicial |
|---|---|
| Tiempo de mesa según el grupo ("turn time") | 1–2 personas 1 h 30 · 3–4 personas 2 h · 5–6 personas 2 h 30 · 7+ 3 h |
| Limpieza entre reservas (buffer) | 15 min |
| Turnos | cada 15 min, de 19:00 a 00:00 |
| Última reserva | la cena debe terminar antes del cierre (pareja 22:30, grupo de 6 21:30) |
| Ritmo de cocina ("cover pacing") | máximo 16 personas empezando en el mismo turno |
| Mesa justa | la mesa puede tener como máximo 1 lugar vacío (todas las mesas son de capacidad par) |
| Salón en vivo | liberar la mesa si se van antes, extender si se quedan; los "no asistió" liberan la mesa |

## Reglas garantizadas por la base de datos

- Una mesa no puede tener dos reservas activas que se superpongan (tiempo de mesa del grupo + limpieza).
- La cantidad de personas no puede superar la capacidad de la mesa, y la mesa debe estar activa.
- Cada cliente solo puede ver sus propias reservas (Row Level Security).
- Solo el administrador accede al panel y al dashboard.
- Ningún usuario puede cambiarse el rol a sí mismo.

## Tecnologías

| Capa | Herramienta |
|---|---|
| Frontend | HTML, CSS, JavaScript, Bootstrap 5 |
| Hosting | Vercel (deploy automático desde este repositorio) |
| Base de datos | Supabase / PostgreSQL |
| Autenticación | Supabase Auth |
| Automatización de correos | Make (webhook + Gmail) |
| Tareas programadas | Supabase Cron (pg_cron) |
| IA | Anthropic Claude (Supabase Edge Function) |
| Clima | Open-Meteo |
| Versionado | GitHub |

> **Make en lugar de n8n:** cumple el mismo rol de automatización y su plan gratuito no vence,
> lo que asegura que los correos funcionen el día de la demo.

## Cómo funciona

```
Navegador ──► Vercel (sitio) ──► Supabase (Auth + API + PostgreSQL)
                                        │
                                        │ trigger + pg_net (webhook)
                                        ▼
                                  Make ──► Gmail ──► correo al cliente / admin
```

1. El cliente reserva desde el sitio.
2. Supabase valida disponibilidad y capacidad, y guarda la reserva.
3. Un trigger de la base arma el correo y avisa a Make por webhook.
4. Make envía el correo desde la cuenta del restaurante.
5. Si el horario llega al 80 % de ocupación, se envía una alerta al administrador.

## Archivos

| Archivo | Qué es |
|---|---|
| `index.html` / `portada.js` | Portada del restaurante: la casa, la carta, ambientes, cómo reservar y contacto |
| `login.html` / `login.js` | Ingreso, registro y pedido de recuperación de contraseña |
| `nueva-clave.html` / `nueva-clave.js` | Crear contraseña nueva desde el enlace del correo |
| `reservar.html` / `reservar.js` | Consulta de disponibilidad y reserva |
| `mis-reservas.html` / `mis-reservas.js` | Reservas del cliente |
| `perfil.html` / `perfil.js` | Mi perfil: rol (cliente o administrador), nombre, teléfono, cumpleaños y correos de promociones |
| `admin.html` / `admin.js` | Panel: Dashboard, Reservas, Mesas, Clientes |
| `admin-salon.js` | Salón en vivo, línea de tiempo y próximas llegadas del panel |
| `admin-equipo.js` | Pestaña Equipo: administradores, invitaciones y auditoría |
| `admin-fidelizacion.js` | Pestaña Fidelización (Parte B): segmentos, canje de cupones, reglas y promociones |
| `invitacion.html` / `invitacion.js` | Aceptar una invitación para ser administrador |
| `comun.js` | Funciones compartidas (sesión, roles, mensajes, tiempos de mesa) |
| `plano.js` | Dibuja el plano del local (elegir mesa y editor del admin) |
| `config.js` | Conexión a Supabase (clave pública) |
| `estilos.css` | Paleta de colores y estilos |
| `img-*.jpg` / `plato-*.jpg` | Fotos del local y de los platos (optimizadas para web) |
| `logo-marea.png` / `logo-marea-claro.png` / `favicon.png` | Logo en dos versiones e ícono del sitio |
| `privacidad.html` | Política de privacidad (Ley 18.331) |
| `vercel.json` | Encabezados de seguridad del sitio (CSP, anti-clickjacking) |
| `sql-1-base-de-datos.sql` | Tablas, reglas, funciones y seguridad (RLS) en Supabase |
| `sql-2-correos-y-alerta.sql` | Trigger que detecta reservas nuevas, cambios y cancelaciones, y la alerta del 80 % |
| `sql-3-correos-armados.sql` | Arma el asunto y el diseño de cada correo antes de enviarlo a Make |
| `sql-4-seguridad.sql` | Límite de reservas por cliente, secreto del webhook y consentimiento de privacidad |
| `sql-5-tiempos-de-mesa.sql` | Tiempo de mesa por grupo, limpieza, cierre, ritmo de cocina, estado sentada, extender |
| `sql-6-plano-y-alternativas.sql` | Forma y ubicación de las mesas, estado de cada mesa, elegir mesa y horarios alternativos |
| `sql-7-profesional.sql` | 20 mesas con zonas, mesa justa por grupo, ocasión y comentarios, teléfono del cliente |
| `sql-8-invitaciones-admin.sql` | Invitaciones de administradores (enlace único, cifrado, 48 h) y auditoría de roles |
| `sql-9-fidelizacion.sql` | **Parte B:** cumpleaños, permiso de promociones, segmentación, tarjeta de visitas, cupones, promociones, correos, tarea diaria y resumen anónimo para la IA |
| `sugerir-promocion.ts` | Supabase Edge Function que pide la sugerencia a Claude (se pega en Supabase, no va en Vercel) |
| `clima.js` | Pronóstico del clima (Open-Meteo) en Reservar y en el Dashboard |
| `sql-10-datos-demo-fidelizacion.sql` | Opcional: 13 clientes de prueba con historial, para mostrar los segmentos en la demo |
| `diagramas/` | Arquitectura, flujo de usuario y MER (Parte A) · flujo y MER de la Parte B |

Los SQL se corren en ese orden en el SQL Editor de Supabase. Las cuentas de administradores se crean con un script aparte que **no** está en el repositorio (tiene contraseñas). La dirección del webhook de Make
y el correo del administrador se configuran aparte en la tabla `config_app` (no están en el repositorio).

## Modelo de datos (Parte A)

- **usuario** (id_usuario, nombre, email, telefono, rol, fecha_nacimiento, fecha_acepta_privacidad, fecha_creacion)
- **mesa** (id_mesa, numero, capacidad par, estado, zona, forma, pos_x, pos_y)
- **reserva** (id_reserva, id_usuario → usuario, id_mesa → mesa, fecha, hora, cantidad_personas, duracion_min, limpieza_min, estado, ocasion, comentarios)
- **duracion_por_grupo** (hasta_personas, minutos) y **ajustes_reserva** (apertura, cierre, turnos, limpieza, máx. personas por turno)

Relaciones: USUARIO 1 — N RESERVA · MESA 1 — N RESERVA.

## Modelo de datos (Parte B)

- **usuario** suma `acepta_promociones` y `fecha_acepta_promociones` (usa `fecha_nacimiento`)
- **beneficio** (id_beneficio, codigo único, id_usuario → usuario, tipo, descripcion, periodo, id_campana → campana, vence_en, usado_en, usado_por → usuario, correo_enviado)
- **campana** (id_campana, nombre, segmento, zona, grupo, asunto, mensaje, beneficio, vence_en, destinatarios, creada_por → usuario)
- **ajustes_fidelizacion** (reglas de segmentos y beneficios, una sola fila)
- **uso_ia** (id, id_usuario → usuario, fecha): registro de cada sugerencia de IA, para el tope diario
- La **segmentación no se guarda**: la calcula la función `datos_clientes()`, así siempre está al día.

Relaciones: USUARIO 1 — N BENEFICIO · CAMPANA 1 — N BENEFICIO.

## Seguridad

| Medida | Qué protege |
|---|---|
| Supabase Auth (contraseñas con hash, sesiones JWT) | Autenticación segura; nadie ve las contraseñas |
| Confirmación de correo al registrarse | Que nadie cree cuentas con correos ajenos |
| Contraseñas de 8+ caracteres con letras y números | Contraseñas débiles |
| Row Level Security (RLS) en todas las tablas | Cada cliente ve solo lo suyo, aunque manipule el navegador |
| Permisos por columna en `usuario` | Escalada de privilegios (nadie se hace admin solo) |
| Validaciones en la base (superposición, capacidad, fechas) | Saltarse el formulario no sirve |
| Máximo 3 reservas futuras por cliente | Abuso / bloqueo del restaurante con reservas falsas |
| Funciones internas sin permiso de ejecución externa | Uso indebido de la automatización |
| Secreto compartido entre la base y Make | Correos falsos enviados desde la cuenta de Marea |
| Escape de texto en el panel (anti-XSS) | Inyección de código a través de nombres |
| Encabezados CSP, X-Frame-Options, nosniff | Scripts de terceros, clickjacking |
| HTTPS en todos los servicios | Datos interceptados en tránsito |
| Clave pública en el sitio, claves secretas fuera del repositorio | Filtración de credenciales |
| Política de privacidad y consentimiento registrado | Cumplimiento de la Ley 18.331 |
| Admins solo por invitación: enlace único, cifrado (hash), 48 h, un uso, atado al correo | Que alguien se haga administrador sin permiso |
| Auditoría de roles (trigger) · no se puede quitar el propio rol ni el último admin | Cambios de permisos sin rastro o dejar el sistema sin dueño |
| Redirección después del login solo a páginas del propio sitio | Enlaces que mandan a sitios falsos (open redirect) |
| Correos de promociones solo con permiso explícito (opt-in) y enlace para darse de baja | Ley 18.331 y correo no deseado |
| Cupones únicos, con vencimiento, de un solo uso, y solo un admin los canjea | Que un cupón se use dos veces o se invente |
| Clave de la IA solo en el servidor (Secrets de Supabase) · a la IA van solo datos anónimos · solo admins · tope de 30 por día | Robo de la clave, fuga de datos personales, gasto descontrolado |
| Funciones de fidelización internas sin permiso externo · texto de promociones escapado | Cupones o correos creados desde afuera, inyección de HTML |

**Mejoras futuras:** auditoría de cambios en reservas y verificación en dos pasos (MFA) para los administradores.
