// =========================================================
// Ingreso y registro
// =========================================================

const params = new URLSearchParams(location.search);
const volverA = params.get("volver");

const formIngreso = document.getElementById("form-ingreso");
const formRegistro = document.getElementById("form-registro");
const pestanaIngreso = document.getElementById("pestana-ingreso");
const pestanaRegistro = document.getElementById("pestana-registro");

function mostrarPestana(cual) {
  const esIngreso = cual === "ingreso";
  formIngreso.classList.toggle("oculto", !esIngreso);
  formRegistro.classList.toggle("oculto", esIngreso);
  pestanaIngreso.classList.toggle("activa", esIngreso);
  pestanaRegistro.classList.toggle("activa", !esIngreso);
  ocultarAviso("aviso-login");
}

pestanaIngreso.addEventListener("click", () => mostrarPestana("ingreso"));
pestanaRegistro.addEventListener("click", () => mostrarPestana("registro"));

// Después de entrar: volver a la página pedida o ir a la del rol
async function redirigir(sesion) {
  const perfil = await obtenerPerfil(sesion.user.id);
  const rol = perfil ? perfil.rol : "cliente";
  if (volverA && !(volverA === "admin.html" && rol !== "admin")) {
    location.href = volverA;
  } else {
    location.href = paginaDeInicio(rol);
  }
}

// ---------- Ingresar ----------
formIngreso.addEventListener("submit", async (e) => {
  e.preventDefault();
  const boton = formIngreso.querySelector("button[type=submit]");
  boton.disabled = true;
  ocultarAviso("aviso-login");

  const { data, error } = await db.auth.signInWithPassword({
    email: document.getElementById("ingreso-email").value.trim(),
    password: document.getElementById("ingreso-clave").value,
  });

  if (error) {
    mostrarAviso("aviso-login", "error", mensajeDeError(error));
    boton.disabled = false;
    return;
  }
  await redirigir(data.session);
});

// ---------- Registrarse ----------
formRegistro.addEventListener("submit", async (e) => {
  e.preventDefault();
  const boton = formRegistro.querySelector("button[type=submit]");
  boton.disabled = true;
  ocultarAviso("aviso-login");

  const clave = document.getElementById("registro-clave").value;
  if (clave.length < 8 || !/[A-Za-z]/.test(clave) || !/[0-9]/.test(clave)) {
    mostrarAviso("aviso-login", "error", "La contraseña tiene que tener al menos 8 caracteres, con letras y números.");
    boton.disabled = false;
    return;
  }
  if (!document.getElementById("registro-privacidad").checked) {
    mostrarAviso("aviso-login", "error", "Para crear la cuenta tenés que aceptar la política de privacidad.");
    boton.disabled = false;
    return;
  }

  const { data, error } = await db.auth.signUp({
    email: document.getElementById("registro-email").value.trim(),
    password: clave,
    options: {
      data: {
        nombre: document.getElementById("registro-nombre").value.trim(),
        acepta_privacidad: "si",
      },
    },
  });

  if (error) {
    mostrarAviso("aviso-login", "error", mensajeDeError(error));
    boton.disabled = false;
    return;
  }

  // Si "Confirm email" está activado en Supabase, no hay sesión todavía
  if (!data.session) {
    mostrarAviso(
      "aviso-login",
      "info",
      "¡Listo! Te mandamos un correo para confirmar tu cuenta. Después volvé y ingresá."
    );
    boton.disabled = false;
    return;
  }
  await redirigir(data.session);
});

// Si ya tiene sesión, no tiene sentido mostrar el login
(async () => {
  const sesion = await obtenerSesion();
  if (sesion) await redirigir(sesion);
  if (params.get("modo") === "registro") mostrarPestana("registro");
})();
