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
  if (m.includes("Password should")) return "La contraseña tiene que tener al menos 8 caracteres, con letras y números.";
  if (m.includes("New password should be different")) return "La contraseña nueva tiene que ser distinta a la anterior.";
  if (m.includes("not authorized")) return "No pudimos enviar el correo a esa dirección. Avisale al restaurante.";
  if (m.includes("reserva_ocasion_ok")) return "Elegí una ocasión de la lista.";
  if (m.includes("reserva_comentarios_ok")) return "Los comentarios pueden tener hasta 300 caracteres.";
  if (m.includes("mesa_capacidad_par")) return "Las mesas tienen que ser de capacidad par (2, 4, 6, 8…).";
  if (m.includes("rate limit") || m.includes("too many")) return "Demasiados intentos seguidos. Esperá unos minutos y probá de nuevo.";
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

const NOMBRES_OCASION = {
  "cumpleaños": "🎂 Cumpleaños",
  aniversario: "💞 Aniversario",
  cita: "🌹 Cita",
  negocios: "💼 Negocios",
  "celebración": "🥂 Celebración",
  otra: "✨ Ocasión especial",
};

const NOMBRES_ESTADO = {
  confirmada: "Confirmada",
  sentada: "Sentada",
  cancelada: "Cancelada",
  completada: "Completada",
  no_asistio: "No asistió",
};

// ---------- Tiempos de mesa (reglas del restaurante) ----------
let reglasTiempo = null;

async function cargarReglasTiempo() {
  const [ajustes, duraciones] = await Promise.all([
    db.from("ajustes_reserva").select("*").eq("id", 1).single(),
    db.from("duracion_por_grupo").select("*").order("hasta_personas"),
  ]);
  reglasTiempo = {
    ajustes: ajustes.data || { apertura: "19:00:00", cierre: "00:00:00", intervalo_min: 15, limpieza_min: 15 },
    duraciones: duraciones.data || [],
  };
  return reglasTiempo;
}

function aMinutos(hora) {
  const [h, m] = hora.split(":").map(Number);
  return h * 60 + m;
}

function minutosAHora(min) {
  const m = ((min % 1440) + 1440) % 1440;
  return `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
}

function sumarMinutos(hora, minutos) {
  return minutosAHora(aMinutos(hora) + minutos);
}

function duracionPara(personas) {
  const lista = reglasTiempo ? reglasTiempo.duraciones : [];
  const regla = lista.find((d) => d.hasta_personas >= personas) || lista[lista.length - 1];
  return regla ? regla.minutos : 120;
}

function textoDuracion(min) {
  if (min < 60) return `${min} min`;
  return min % 60 === 0 ? `${min / 60} h` : `${Math.floor(min / 60)} h ${min % 60} min`;
}

// Horarios en los que un grupo puede empezar (la cena termina antes del cierre)
function horariosPara(personas) {
  const a = reglasTiempo.ajustes;
  const apertura = aMinutos(a.apertura);
  let cierre = aMinutos(a.cierre);
  if (cierre <= apertura) cierre += 1440;
  const ultimo = cierre - duracionPara(personas);
  const lista = [];
  for (let m = apertura; m <= ultimo; m += a.intervalo_min) lista.push(minutosAHora(m));
  return lista;
}

// Fecha de hoy en formato AAAA-MM-DD (hora de Uruguay del navegador)
function hoyISO() {
  const h = new Date();
  const mm = String(h.getMonth() + 1).padStart(2, "0");
  const dd = String(h.getDate()).padStart(2, "0");
  return `${h.getFullYear()}-${mm}-${dd}`;
}

// Si alguien entra desde el enlace de "olvidé mi contraseña" y Supabase
// lo manda a otra página, lo llevamos a la página para crear la clave nueva
db.auth.onAuthStateChange((evento) => {
  if (evento === "PASSWORD_RECOVERY" && !location.pathname.endsWith("nueva-clave.html")) {
    location.replace("nueva-clave.html");
  }
});

document.addEventListener("DOMContentLoaded", pintarMenu);
