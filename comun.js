// =========================================================
// Funciones que usan todas las páginas
// =========================================================

const cfg = window.MAREA_CONFIG;
const db = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey);

// ---------- Sesión y rol ----------
async function obtenerSesion() {
  const { data } = await db.auth.getSession();
  return data.session;
}

async function obtenerPerfil(idUsuario) {
  const { data, error } = await db
    .from("usuario")
    .select("nombre, email, rol")
    .eq("id_usuario", idUsuario)
    .single();
  if (error) return null;
  return data;
}

// A dónde va cada rol después de entrar
function paginaDeInicio(rol) {
  return rol === "admin" ? "admin.html" : "mis-reservas.html";
}

// Protege una página. rolNecesario: null (cualquiera con sesión) o "admin"
async function requerirSesion(rolNecesario = null) {
  const sesion = await obtenerSesion();
  if (!sesion) {
    const volver = encodeURIComponent(location.pathname.split("/").pop());
    location.replace(`login.html?volver=${volver}`);
    return null;
  }
  const perfil = await obtenerPerfil(sesion.user.id);
  if (rolNecesario && (!perfil || perfil.rol !== rolNecesario)) {
    location.replace(paginaDeInicio(perfil ? perfil.rol : "cliente"));
    return null;
  }
  return { sesion, perfil };
}

async function cerrarSesion() {
  await db.auth.signOut();
  location.href = "index.html";
}

// ---------- Menú de arriba ----------
async function pintarMenu() {
  const menu = document.getElementById("menu");
  if (!menu) return;
  const sesion = await obtenerSesion();

  if (!sesion) {
    menu.innerHTML = `
      <a href="reservar.html">Reservar</a>
      <a href="login.html">Ingresar</a>`;
    return;
  }

  const perfil = await obtenerPerfil(sesion.user.id);
  const esAdmin = perfil && perfil.rol === "admin";
  menu.innerHTML = `
    <a href="reservar.html">Reservar</a>
    <a href="mis-reservas.html">Mis reservas</a>
    ${esAdmin ? '<a href="admin.html">Panel</a>' : ""}
    <button type="button" class="enlace-boton" id="btn-salir">Salir</button>`;
  document.getElementById("btn-salir").addEventListener("click", cerrarSesion);
}

// ---------- Avisos ----------
function mostrarAviso(idCaja, tipo, texto) {
  const caja = document.getElementById(idCaja);
  caja.className = `aviso aviso-${tipo}`;
  caja.textContent = texto;
}

function ocultarAviso(idCaja) {
  const caja = document.getElementById(idCaja);
  caja.className = "oculto";
  caja.textContent = "";
}

// Traduce errores técnicos a mensajes claros
function mensajeDeError(error) {
  const m = (error && error.message) || "";
  if (m.includes("Invalid login credentials")) return "El correo o la contraseña no son correctos.";
  if (m.includes("Email not confirmed")) return "Todavía no confirmaste tu correo. Revisá tu bandeja de entrada.";
  if (m.includes("User already registered")) return "Ya existe una cuenta con ese correo. Probá ingresar.";
  if (m.includes("Password should be")) return "La contraseña tiene que tener al menos 6 caracteres.";
  if (m.includes("exclusion constraint") || m.includes("sin_superposicion"))
    return "Esa mesa se acaba de ocupar. Probá de nuevo.";
  if (m.includes("Invalid API key") || m.includes("No API key"))
    return "Falta configurar la clave de Supabase en js/config.js.";
  return m || "Ocurrió un error. Probá de nuevo.";
}

// ---------- Formatos ----------
function formatearFecha(fechaISO) {
  const [a, m, d] = fechaISO.split("-").map(Number);
  return new Date(a, m - 1, d).toLocaleDateString("es-UY", {
    weekday: "long",
    day: "numeric",
    month: "long",
  });
}

function formatearHora(hora) {
  return hora.slice(0, 5); // "20:30:00" -> "20:30"
}

const NOMBRES_ESTADO = {
  confirmada: "Confirmada",
  cancelada: "Cancelada",
  completada: "Completada",
  no_asistio: "No asistió",
};

// Fecha de hoy en formato AAAA-MM-DD (hora de Uruguay del navegador)
function hoyISO() {
  const h = new Date();
  const mm = String(h.getMonth() + 1).padStart(2, "0");
  const dd = String(h.getDate()).padStart(2, "0");
  return `${h.getFullYear()}-${mm}-${dd}`;
}

document.addEventListener("DOMContentLoaded", pintarMenu);
