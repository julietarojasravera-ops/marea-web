// =========================================================
// Reservar: consultar disponibilidad y confirmar (RF3, RF4, RF6)
// Los horarios dependen del tamaño del grupo: cada grupo tiene su
// tiempo de mesa y la cena tiene que terminar antes del cierre.
// =========================================================

const campoFecha = document.getElementById("fecha");
const campoHora = document.getElementById("hora");
const campoPersonas = document.getElementById("personas");
const formBuscar = document.getElementById("form-buscar");
const cajaResultado = document.getElementById("resultado");
const botonConfirmar = document.getElementById("btn-confirmar");
const infoTiempo = document.getElementById("info-tiempo");

const MAX_PERSONAS = 8;

function personasTexto(n) {
  return `${n} ${Number(n) === 1 ? "persona" : "personas"}`;
}

// Arma la lista de horas posibles para ese grupo
function actualizarHorarios() {
  const personas = Number(campoPersonas.value);
  const anterior = campoHora.value;
  const horas = horariosPara(personas);
  campoHora.innerHTML = horas.map((h) => `<option value="${h}">${h}</option>`).join("");
  if (horas.includes(anterior)) campoHora.value = anterior;
  else if (horas.includes("20:00")) campoHora.value = "20:00";

  const dur = duracionPara(personas);
  infoTiempo.textContent =
    `Para ${personasTexto(personas)} la mesa es por ${textoDuracion(dur)}. ` +
    `Última reserva: ${horas[horas.length - 1]}.`;
}

function llenarOpciones() {
  let opciones = "";
  for (let i = 1; i <= MAX_PERSONAS; i++) {
    opciones += `<option value="${i}">${personasTexto(i)}</option>`;
  }
  campoPersonas.innerHTML = opciones;
  campoPersonas.value = "2";
  campoFecha.min = hoyISO();
  campoFecha.value = hoyISO();
  actualizarHorarios();
}

function limpiarResultado() {
  cajaResultado.classList.add("oculto");
  ocultarAviso("aviso-reserva");
}

[campoFecha, campoHora].forEach((c) => c.addEventListener("change", limpiarResultado));
campoPersonas.addEventListener("change", () => {
  limpiarResultado();
  actualizarHorarios();
});

// ---------- Ver disponibilidad ----------
formBuscar.addEventListener("submit", async (e) => {
  e.preventDefault();
  limpiarResultado();
  const boton = formBuscar.querySelector("button[type=submit]");
  boton.disabled = true;

  const { data, error } = await db.rpc("consultar_turno", {
    p_fecha: campoFecha.value,
    p_hora: campoHora.value,
    p_personas: Number(campoPersonas.value),
  });
  boton.disabled = false;

  if (error) {
    mostrarAviso("aviso-reserva", "error", mensajeDeError(error));
    return;
  }
  if (!data.disponible) {
    mostrarAviso("aviso-reserva", "error", data.motivo);
    return;
  }

  document.getElementById("resultado-texto").textContent =
    `${formatearFecha(campoFecha.value)}, ${personasTexto(campoPersonas.value)}. ` +
    `La mesa es tuya de ${campoHora.value} a ${data.hasta} (${data.duracion_texto}).`;
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

  const hora = formatearHora(data.hora);
  cajaResultado.classList.add("oculto");
  document.getElementById("form-buscar").classList.add("oculto");
  document.getElementById("confirmacion-texto").textContent =
    `${formatearFecha(data.fecha)}, de ${hora} a ${sumarMinutos(hora, data.duracion_min)}, ` +
    `${personasTexto(data.cantidad_personas)}. Número de reserva: ${data.id_reserva}. ` +
    `Te mandamos la confirmación por correo.`;
  document.getElementById("confirmacion").classList.remove("oculto");
});

// ---------- Inicio ----------
(async () => {
  const acceso = await requerirSesion();
  if (!acceso) return;
  await cargarReglasTiempo();
  llenarOpciones();
  const nombre = acceso.perfil && acceso.perfil.nombre;
  if (nombre) document.getElementById("saludo").textContent = `Hola, ${nombre}.`;
})();
