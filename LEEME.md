# Marea — sitio de reservas (Parte A)

Sitio web del restaurante Marea conectado a Supabase (proyecto `reservas-restaurante`).

## Qué incluye
- `index.html` — portada
- `login.html` — ingreso y registro
- `reservar.html` — consultar disponibilidad y confirmar reserva
- `mis-reservas.html` — próximas / pasadas, cancelar
- `admin.html` — panel admin (protegido; contenido en la próxima versión)
- `css/estilos.css` — colores y estilos (todo en variables al principio)
- `js/config.js` — **URL y clave de Supabase (lo único que hay que editar)**

## Poner online (sin instalar nada)

1. **Pegar la clave.** En Supabase: botón verde *Connect* o *Project Settings → API Keys*.
   Copiá la clave **anon / publishable** y pegala en `js/config.js` en lugar de `PEGAR_ACA_LA_ANON_KEY`.
   Nunca uses la `service_role`.
2. **Subir a GitHub.** github.com → *New repository* → nombre `marea-web` → *Create*.
   En el repo vacío tocá *uploading an existing file* y arrastrá **el contenido** de la carpeta
   (index.html, las otras páginas y las carpetas css y js). *Commit changes*.
3. **Publicar en Vercel.** vercel.com → *Add New → Project* → importar `marea-web` → *Deploy*.
   No hace falta cambiar ninguna opción. Te da un link del tipo `marea-web.vercel.app`.
4. **Avisarle a Supabase el link.** Supabase → *Authentication → URL Configuration* →
   en *Site URL* pegá el link de Vercel y guardá.

## Hacerse admin
Registrarse en el sitio y después, en Supabase → SQL Editor:

```sql
update public.usuario set rol = 'admin' where email = 'tu@correo.com';
```

Cerrar sesión y volver a entrar.

## Cambios futuros
Editá el archivo en GitHub (lápiz ✏️) o subí la versión nueva encima. Vercel publica solo en 1 minuto.
