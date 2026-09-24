// =========================================================
// Reservar: consultar disponibilidad y confirmar (RF3, RF4, RF6)
// =========================================================

const campoFecha = document.getElementById("fecha");
const campoHora = document.getElementById("hora");
const campoPersonas = document.getElementById("personas");
const formBuscar = document.getElementById("form-buscar");
const cajaResultado = document.getElementById("resultado");
const botonConfirmar = document.getElementById("btn-confirmar");

// Horarios de reserva: 19:00 a 22:00 cada 30 min (cada reserva ocupa 2 h)
const HORARIOS = ["19:00", "19:30", "20:00", "20:30", "21:00", "21:30", "22:00"];
const MAX_PERSONAS = 8;

function llenarOpciones() {
  campoHora.innerHTML = HORARIOS.map((h) => `<option value="${h}">${h}</option>`).join("");
  let opciones = "";
  for (let i = 1; i <= MAX_PERSONAS; i++) {
    opciones += `<option value="${i}">${i} ${i === 1 ? "persona" : "personas"}</option>`;
  }
  campoPersonas.innerHTML = opciones;
  campoPersonas.value = "2";
  campoFecha.min = hoyISO();
  campoFecha.value = hoyISO();
}

function limpiarResultado() {
  cajaResultado.classList.add("oculto");
  ocultarAviso("aviso-reserva");
}

[campoFecha, campoHora, campoPersonas].forEach((c) => c.addEventListener("change", limpiarResultado));

// ---------- Ver disponibilidad ----------
formBuscar.addEventListener("submit", async (e) => {
  e.preventDefault();
  limpiarResultado();
  const boton = formBuscar.querySelector("button[type=submit]");
  boton.disabled = true;

  const { data, error } = await db.rpc("mesas_disponibles", {
    p_fecha: campoFecha.value,
    p_hora: campoHora.value,
    p_personas: Number(campoPersonas.value),
  });
  boton.disabled = false;

  if (error) {
    mostrarAviso("aviso-reserva", "error", mensajeDeError(error));
    return;
  }

  const texto = `${formatearFecha(campoFecha.value)} a las ${campoHora.value}, ${campoPersonas.value} ${
    campoPersonas.value === "1" ? "persona" : "personas"
  }`;

  if (!data || data.length === 0) {
    mostrarAviso(
      "aviso-reserva",
      "error",
      `No hay lugar para el ${texto}. Probá otro horario u otro día.`
    );
    return;
  }

  document.getElementById("resultado-texto").textContent = `Hay lugar para el ${texto}.`;
  cajaResultado.classList.remove("oculto");
});

// ---------- Confirmar reserva ----------
botonConfirmar.addEventListener("click", async () => {
  botonConfirmar.disabled = true;

  const { data, error } = await db.rpc("crear_reserva", {
    p_fecha: campoFecha.value,
    p_hora: campoHora.value,
    p_personas: Number(campoPersonas.value),
  });
  botonConfirmar.disabled = false;

  if (error) {
    mostrarAviso("aviso-reserva", "error", mensajeDeError(error));
    return;
  }

  cajaResultado.classList.add("oculto");
  document.getElementById("form-buscar").classList.add("oculto");
  document.getElementById("confirmacion-texto").textContent =
    `${formatearFecha(data.fecha)} a las ${formatearHora(data.hora)}, ` +
    `${data.cantidad_personas} ${data.cantidad_personas === 1 ? "persona" : "personas"}. ` +
    `Número de reserva: ${data.id_reserva}.`;
  document.getElementById("confirmacion").classList.remove("oculto");
});

// ---------- Inicio ----------
(async () => {
  const acceso = await requerirSesion();
  if (!acceso) return;
  llenarOpciones();
  const nombre = acceso.perfil && acceso.perfil.nombre;
  if (nombre) document.getElementById("saludo").textContent = `Hola, ${nombre}.`;
})();
