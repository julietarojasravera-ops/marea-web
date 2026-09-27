// =========================================================
// Aceptar una invitación para ser administrador
// El token viaja en el enlace del correo. La base verifica que sea
// válido, que no esté vencido ni usado y que sea para este correo.
// =========================================================

const CLAVE_TOKEN = "marea_invitacion";
const params = new URLSearchParams(location.search);
let token = params.get("token");

// Guardamos el token por si tiene que ir a registrarse y volver
try {
  if (token) sessionStorage.setItem(CLAVE_TOKEN, token);
  else token = sessionStorage.getItem(CLAVE_TOKEN);
} catch (e) { /* si el navegador no deja guardar, seguimos igual */ }

// Sacamos el token de la barra de direcciones (no queda en el historial)
if (params.get("token")) history.replaceState(null, "", "invitacion.html");

const texto = document.getElementById("inv-texto");

(async () => {
  if (!token) {
    texto.textContent = "Este enlace no tiene una invitación. Abrí el enlace que te llegó por correo.";
    return;
  }
  const sesion = await obtenerSesion();
  if (!sesion) {
    texto.textContent = "Te invitaron a administrar el sistema de reservas de Marea.";
    const volver = encodeURIComponent("invitacion.html");
    document.getElementById("inv-ingresar").href = `login.html?volver=${volver}`;
    document.getElementById("inv-registrarse").href = `login.html?modo=registro&volver=${volver}`;
    document.getElementById("inv-sin-sesion").classList.remove("oculto");
    return;
  }
  const perfil = await obtenerPerfil(sesion.user.id);
  texto.textContent = `Hola${perfil?.nombre ? ", " + perfil.nombre : ""}. Estás entrando como ${sesion.user.email}.`;
  document.getElementById("inv-con-sesion").classList.remove("oculto");
})();

document.getElementById("btn-aceptar").addEventListener("click", async (e) => {
  e.target.disabled = true;
  const { error } = await db.rpc("aceptar_invitacion", { p_token: token });
  if (error) {
    e.target.disabled = false;
    mostrarAviso("aviso-inv", "error", mensajeDeError(error));
    return;
  }
  try { sessionStorage.removeItem(CLAVE_TOKEN); } catch (err) { /* nada */ }
  document.getElementById("inv-con-sesion").classList.add("oculto");
  mostrarAviso("aviso-inv", "ok", "¡Listo! Ya sos parte del equipo de administración. Te llevamos al panel…");
  setTimeout(() => { location.href = "admin.html"; }, 1600);
});
