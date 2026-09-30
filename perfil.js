// =========================================================
// Mi perfil: ver si sos cliente o administrador y editar tus datos
// (nombre, teléfono, cumpleaños y correos de promociones).
// El rol NO se puede cambiar desde acá: la base de datos lo impide.
// =========================================================

let idPerfil = null;
let temporizadorGuardado = null;

const campo = (id) => document.getElementById(`perfil-campo-${id}`);

function pintarCabecera(u) {
  const nombre = u.nombre || "Sin nombre";
  document.getElementById("perfil-avatar").textContent = nombre.trim()[0]?.toUpperCase() || "·";
  document.getElementById("perfil-nombre").textContent = nombre;
  document.getElementById("perfil-email").textContent = u.email;

  const esAdmin = u.rol === "admin";
  const rol = document.getElementById("perfil-rol");
  rol.textContent = esAdmin ? "Administrador" : "Cliente";
  rol.className = `rol-etiqueta ${esAdmin ? "rol-admin" : "rol-cliente"}`;
  document.getElementById("perfil-rol-texto").textContent = esAdmin
    ? "Tenés acceso al panel: podés gestionar reservas, mesas, clientes, fidelización y el equipo."
    : "Podés reservar mesa, ver y cancelar tus reservas y recibir beneficios.";
  document.getElementById("acceso-panel").classList.toggle("oculto", !esAdmin);

  if (u.fecha_creacion) {
    const desde = new Date(u.fecha_creacion).toLocaleDateString("es-UY", { month: "long", year: "numeric" });
    document.getElementById("perfil-desde").textContent = `Con cuenta desde ${desde}`;
  }
}

async function cargarPerfil() {
  const { data, error } = await db.from("usuario")
    .select("nombre, email, telefono, rol, fecha_nacimiento, acepta_promociones, fecha_creacion")
    .eq("id_usuario", idPerfil)
    .single();
  if (error) { mostrarAviso("aviso-perfil", "error", mensajeDeError(error)); return; }

  pintarCabecera(data);
  campo("nombre").value = data.nombre || "";
  campo("telefono").value = data.telefono || "";
  campo("email").value = data.email;
  campo("nacimiento").value = data.fecha_nacimiento || "";
  campo("promociones").checked = !!data.acepta_promociones;
}

function confirmarGuardado() {
  const marca = document.getElementById("perfil-guardado");
  marca.classList.remove("oculto");
  clearTimeout(temporizadorGuardado);
  temporizadorGuardado = setTimeout(() => marca.classList.add("oculto"), 6000);
}

campo("nacimiento").max = hoyISO();

document.getElementById("form-perfil").addEventListener("submit", async (e) => {
  e.preventDefault();
  ocultarAviso("aviso-perfil");
  document.getElementById("perfil-guardado").classList.add("oculto");

  const nombre = campo("nombre").value.trim();
  const telefono = campo("telefono").value.trim();
  const nacimiento = campo("nacimiento").value || null;

  if (!nombre) {
    mostrarAviso("aviso-perfil", "error", "Escribí tu nombre.");
    return;
  }
  if (telefono && !/^[0-9 +()-]{6,20}$/.test(telefono)) {
    mostrarAviso("aviso-perfil", "error", "Escribí un teléfono válido, por ejemplo 099 123 456.");
    return;
  }
  if (nacimiento && (nacimiento > hoyISO() || nacimiento < "1900-01-01")) {
    mostrarAviso("aviso-perfil", "error", "Revisá la fecha de cumpleaños.");
    return;
  }

  const boton = document.getElementById("btn-guardar-perfil");
  boton.disabled = true;
  boton.textContent = "Guardando…";
  const { error } = await db.from("usuario").update({
    nombre,
    telefono: telefono || null,
    fecha_nacimiento: nacimiento,
    acepta_promociones: campo("promociones").checked,
  }).eq("id_usuario", idPerfil);
  boton.disabled = false;
  boton.textContent = "Guardar mis datos";

  if (error) { mostrarAviso("aviso-perfil", "error", mensajeDeError(error)); return; }
  confirmarGuardado();
  mostrarAviso("aviso-perfil", "ok", "¡Listo! Guardamos tus datos.");
  cargarPerfil();
  pintarMenu();   // por si cambió el nombre
});

(async () => {
  const acceso = await requerirSesion();
  if (!acceso) return;
  idPerfil = acceso.sesion.user.id;
  cargarPerfil();
})();
