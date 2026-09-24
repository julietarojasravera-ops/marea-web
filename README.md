# Marea — Sistema de reservas y fidelización para restaurantes

Aplicación web para que un restaurante gestione **reservas, mesas y clientes** desde un único sistema.
Proyecto académico — Incorporación Estratégica · Universidad ORT Uruguay.

🔗 **Demo online:** https://marea-web-sooty.vercel.app

---

## Estado

| Etapa | Estado |
|---|---|
| **Parte A — MVP** | ✅ Completa y funcionando |
| Parte B — Fidelización basada en datos | ⏳ Próxima etapa |

## Qué hace (Parte A)

**Cliente**
- Se registra e inicia sesión.
- Consulta disponibilidad por fecha, horario y cantidad de personas.
- Reserva: el sistema asigna automáticamente la mesa más chica que sirva.
- Ve sus reservas (próximas y pasadas) y puede cancelarlas.
- Recibe correos automáticos: confirmación, cambios y cancelaciones.

**Administrador**
- **Dashboard:** reservas del día, personas esperadas, ocupación en hora pico, cancelaciones y reservas por horario.
- **Alerta de ocupación:** aviso en el panel y por correo cuando un horario llega al 80 %.
- **Reservas:** consultar, filtrar, crear, modificar y cancelar (el cliente recibe aviso por correo).
- **Mesas:** agregar, cambiar capacidad, activar y desactivar.
- **Clientes:** listado con reservas, asistencias, cancelaciones, última visita y próxima reserva.

## Reglas garantizadas por la base de datos

- Una mesa no puede tener dos reservas activas que se superpongan (cada reserva ocupa la mesa 2 horas).
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
| `index.html` | Portada del restaurante |
| `login.html` / `login.js` | Ingreso y registro |
| `reservar.html` / `reservar.js` | Consulta de disponibilidad y reserva |
| `mis-reservas.html` / `mis-reservas.js` | Reservas del cliente |
| `admin.html` / `admin.js` | Panel: Dashboard, Reservas, Mesas, Clientes |
| `comun.js` | Funciones compartidas (sesión, roles, mensajes) |
| `config.js` | Conexión a Supabase (clave pública) |
| `estilos.css` | Paleta de colores y estilos |

## Modelo de datos (Parte A)

- **usuario** (id_usuario, nombre, email, rol, fecha_nacimiento, fecha_creacion)
- **mesa** (id_mesa, numero, capacidad, estado)
- **reserva** (id_reserva, id_usuario → usuario, id_mesa → mesa, fecha, hora, cantidad_personas, estado)

Relaciones: USUARIO 1 — N RESERVA · MESA 1 — N RESERVA.
`fecha_nacimiento` queda preparada para la Parte B.

## Seguridad

- La clave de `config.js` es la **clave pública** de Supabase: está pensada para usarse en el navegador.
  La protección de los datos la dan las reglas de la base (RLS).
- Las claves secretas nunca se guardan en este repositorio.
