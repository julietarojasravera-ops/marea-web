// =========================================================
// Crear contraseña nueva (llega desde el correo de recuperación)
// =========================================================

const formNueva = document.getElementById("form-nueva");
const bajada = document.getElementById("bajada");
let formularioVisible = false;

function mostrarFormulario() {
  if (formularioVisible) return;
  formularioVisible = true;
  bajada.textContent = "Elegí una contraseña nueva para tu cuenta.";
  formNueva.classList.remove("oculto");
  document.getElementById("sin-enlace").classList.add("oculto");
  ocultarAviso("aviso-nueva");
}

function mostrarEnlaceInvalido(texto) {
  if (formularioVisible) return;
  bajada.textContent = "";
  mostrarAviso("aviso-nueva", "error", texto);
  document.getElementById("sin-enlace").classList.remove("oculto");
}

// Supabase lee el enlace del correo y abre una sesión temporal
db.auth.onAuthStateChange((evento, sesion) => {
  if (evento === "PASSWORD_RECOVERY" || sesion) mostrarFormulario();
});

(async () => {
  // Enlace vencido o ya usado: Supabase lo indica en la dirección
  const datosError = new URLSearchParams(location.hash.slice(1) || location.search);
  if (datosError.get("error_code") === "otp_expired" || datosError.get("error")) {
    mostrarEnlaceInvalido("El enlace venció o ya se usó. Pedí uno nuevo.");
    return;
  }

  const sesion = await obtenerSesion();
  if (sesion) {
    mostrarFormulario();
    return;
  }
  // Damos un momento por si Supabase todavía está procesando el enlace
  setTimeout(() => {
    mostrarEnlaceInvalido("Para cambiar la contraseña tenés que entrar desde el enlace que te mandamos por correo.");
  }, 2500);
})();

formNueva.addEventListener("submit", async (e) => {
  e.preventDefault();
  const boton = formNueva.querySelector("button[type=submit]");
  const clave = document.getElementById("nueva-clave").value;
  const repetida = document.getElementById("nueva-clave-2").value;
  ocultarAviso("aviso-nueva");

  if (clave.length < 8 || !/[A-Za-z]/.test(clave) || !/[0-9]/.test(clave)) {
    mostrarAviso("aviso-nueva", "error", "La contraseña tiene que tener al menos 8 caracteres, con letras y números.");
    return;
  }
  if (clave !== repetida) {
    mostrarAviso("aviso-nueva", "error", "Las dos contraseñas no coinciden.");
    return;
  }

  boton.disabled = true;
  const { error } = await db.auth.updateUser({ password: clave });
  boton.disabled = false;

  if (error) {
    mostrarAviso("aviso-nueva", "error", mensajeDeError(error));
    return;
  }

  formNueva.classList.add("oculto");
  bajada.textContent = "";
  mostrarAviso("aviso-nueva", "ok", "¡Listo! Tu contraseña se cambió. Te llevamos a tu cuenta…");

  const sesion = await obtenerSesion();
  const perfil = sesion ? await obtenerPerfil(sesion.user.id) : null;
  setTimeout(() => {
    location.href = paginaDeInicio(perfil ? perfil.rol : "cliente");
  }, 1800);
});
