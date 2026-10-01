// =========================================================
// Reservar: plano del local, disponibilidad y confirmación
// - Los horarios dependen del tamaño del grupo (tiempo de mesa)
// - El cliente puede elegir la mesa en el plano (opcional)
// - Si no hay lugar, se sugieren horarios cercanos o el próximo día
// =========================================================

const campoFecha = document.getElementById("fecha");
const campoHora = document.getElementById("hora");
const campoPersonas = document.getElementById("personas");
const formBuscar = document.getElementById("form-buscar");
const cajaResultado = document.getElementById("resultado");
const botonConfirmar = document.getElementById("btn-confirmar");
const infoTiempo = document.getElementById("info-tiempo");
const svgPlano = document.getElementById("plano");
const textoMesa = document.getElementById("mesa-elegida-texto");
const cajaAlternativas = document.getElementById("alternativas");

const MAX_PERSONAS = 8;
let mesaElegida = null;   // id_mesa elegido en el plano (o null = automática)
let mesasPlano = [];
let estadosMesas = {};

function personasTexto(n) {
  return `${n} ${Number(n) === 1 ? "persona" : "personas"}`;
}

// ---------- Horarios según el grupo ----------
function actualizarHorarios() {
  const personas = Number(campoPersonas.value);
  const anterior = campoHora.value;
  const horas = horariosPara(personas);
  campoHora.innerHTML = horas.map((h) => `<option value="${h}">${h}</option>`).join("");
  if (horas.includes(anterior)) campoHora.value = anterior;
  else if (horas.includes("20:00")) campoHora.value = "20:00";

  infoTiempo.textContent =
    `Para ${personasTexto(personas)} la mesa es por ${textoDuracion(duracionPara(personas))}. ` +
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

// ---------- Plano ----------
function describirMesaElegida() {
  if (!mesaElegida) {
    textoMesa.textContent = "Tocá una mesa libre, o dejá que te asignemos la mejor.";
    return;
  }
  const m = mesasPlano.find((x) => x.id_mesa === mesaElegida);
  const zona = m.zona ? `, ${m.zona.toLowerCase()}` : "";
  textoMesa.textContent = `Elegiste la mesa ${m.numero} (para ${m.capacidad}${zona}). Tocala de nuevo para quitarla.`;
}

function redibujarPlano() {
  dibujarPlano(svgPlano, mesasPlano, {
    estados: estadosMesas,
    seleccion: mesaElegida,
    alElegir: (mesa, info) => {
      limpiarResultado();
      if (info.estado === "libre") {
        mesaElegida = mesaElegida === mesa.id_mesa ? null : mesa.id_mesa;
        describirMesaElegida();
      } else if (info.estado === "ocupada") {
        textoMesa.textContent = info.libre_desde
          ? `La mesa ${mesa.numero} está ocupada a esa hora. Se libera a las ${info.libre_desde}.`
          : `La mesa ${mesa.numero} está ocupada a esa hora.`;
      } else if (info.estado === "chica") {
        textoMesa.textContent = `La mesa ${mesa.numero} es para ${mesa.capacidad}: no entra un grupo de ${campoPersonas.value}.`;
      } else if (info.estado === "grande") {
        textoMesa.textContent = `La mesa ${mesa.numero} es para ${mesa.capacidad}. Para ${personasTexto(campoPersonas.value)} te damos una mesa más justa.`;
      } else {
        textoMesa.textContent = `La mesa ${mesa.numero} no está disponible.`;
      }
      redibujarPlano();
    },
  });
}

let pedidoPlano = 0;
async function actualizarPlano() {
  if (typeof pintarClimaReserva === "function") pintarClimaReserva(campoFecha.value, campoHora.value);
  if (!campoHora.value) return;
  const numero = ++pedidoPlano;   // si cambian rápido los campos, gana el último pedido
  const { data, error } = await db.rpc("estado_mesas", {
    p_fecha: campoFecha.value,
    p_hora: campoHora.value,
    p_personas: Number(campoPersonas.value),
  });
  if (numero !== pedidoPlano) return;
  if (error) { mostrarAviso("aviso-reserva", "error", mensajeDeError(error)); return; }

  mesasPlano = data;
  estadosMesas = Object.fromEntries(data.map((m) => [m.id_mesa, { estado: m.estado, libre_desde: m.libre_desde }]));
  if (mesaElegida && (!estadosMesas[mesaElegida] || estadosMesas[mesaElegida].estado !== "libre")) {
    mesaElegida = null;
  }
  describirMesaElegida();
  redibujarPlano();
}

function limpiarResultado() {
  cajaResultado.classList.add("oculto");
  cajaAlternativas.classList.add("oculto");
  cajaAlternativas.innerHTML = "";
  ocultarAviso("aviso-reserva");
}

campoFecha.addEventListener("change", () => { limpiarResultado(); actualizarPlano(); });
campoHora.addEventListener("change", () => { limpiarResultado(); actualizarPlano(); });
campoPersonas.addEventListener("change", () => {
  limpiarResultado();
  actualizarHorarios();
  actualizarPlano();
});

// ---------- Horarios alternativos ----------
async function mostrarAlternativas() {
  const { data, error } = await db.rpc("horarios_alternativos", {
    p_fecha: campoFecha.value,
    p_hora: campoHora.value,
    p_personas: Number(campoPersonas.value),
    p_id_mesa: mesaElegida,
  });
  if (error || !data) return;

  let html = "";
  if (data.mismo_dia.length) {
    const cual = mesaElegida ? "para esa mesa" : "ese día";
    html += `<p class="alternativas-titulo">Horarios libres ${cual}:</p><div class="alternativas-lista">`;
    html += data.mismo_dia.map((h) =>
      `<button type="button" class="chip-horario" data-hora="${h}">${h}</button>`).join("");
    html += "</div>";
  } else if (data.otro_dia) {
    html += `<p class="alternativas-titulo">Ese día ya no hay lugar. El próximo disponible:</p>
      <div class="alternativas-lista">
        <button type="button" class="chip-horario" data-fecha="${data.otro_dia.fecha}" data-hora="${data.otro_dia.hora}">
          ${formatearFecha(data.otro_dia.fecha)} a las ${data.otro_dia.hora}
        </button>
      </div>`;
  }
  if (mesaElegida) {
    html += `<button type="button" class="enlace-olvide mt-2" id="btn-sin-mesa">Buscar en cualquier mesa a las ${campoHora.value}</button>`;
  }
  if (!html) return;

  cajaAlternativas.innerHTML = html;
  cajaAlternativas.classList.remove("oculto");
}

cajaAlternativas.addEventListener("click", async (e) => {
  const chip = e.target.closest(".chip-horario");
  if (chip) {
    if (chip.dataset.fecha) campoFecha.value = chip.dataset.fecha;
    campoHora.value = chip.dataset.hora;
    limpiarResultado();
    await actualizarPlano();
    formBuscar.requestSubmit();
    return;
  }
  if (e.target.id === "btn-sin-mesa") {
    mesaElegida = null;
    limpiarResultado();
    await actualizarPlano();
    formBuscar.requestSubmit();
  }
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
    p_id_mesa: mesaElegida,
  });
  boton.disabled = false;

  if (error) {
    mostrarAviso("aviso-reserva", "error", mensajeDeError(error));
    return;
  }
  if (!data.disponible) {
    mostrarAviso("aviso-reserva", "error", data.motivo);
    if (!data.grupo_grande) mostrarAlternativas();
    return;
  }

  const mesa = data.mesa ? ` Mesa ${data.mesa}${data.zona ? ` (${data.zona.toLowerCase()})` : ""}.` : "";
  document.getElementById("resultado-texto").textContent =
    `${formatearFecha(campoFecha.value)}, ${personasTexto(campoPersonas.value)}. ` +
    `La mesa es tuya de ${campoHora.value} a ${data.hasta} (${data.duracion_texto}).${mesa}`;
  cajaResultado.classList.remove("oculto");
  cajaResultado.scrollIntoView({ behavior: "smooth", block: "center" });
});

// ---------- Confirmar reserva ----------
botonConfirmar.addEventListener("click", async () => {
  botonConfirmar.disabled = true;

  const { data, error } = await db.rpc("crear_reserva", {
    p_fecha: campoFecha.value,
    p_hora: campoHora.value,
    p_personas: Number(campoPersonas.value),
    p_id_mesa: mesaElegida,
    p_ocasion: document.getElementById("ocasion").value || null,
    p_comentarios: document.getElementById("comentarios").value.trim() || null,
  });
  botonConfirmar.disabled = false;

  if (error) {
    mostrarAviso("aviso-reserva", "error", mensajeDeError(error));
    actualizarPlano();
    return;
  }

  const hora = formatearHora(data.hora);
  const mesa = mesasPlano.find((m) => m.id_mesa === data.id_mesa);
  cajaResultado.classList.add("oculto");
  document.getElementById("form-buscar").classList.add("oculto");
  document.getElementById("confirmacion-texto").textContent =
    `${formatearFecha(data.fecha)}, de ${hora} a ${sumarMinutos(hora, data.duracion_min)}, ` +
    `${personasTexto(data.cantidad_personas)}${mesa ? `, mesa ${mesa.numero}` : ""}. ` +
    `Número de reserva: ${data.id_reserva}. Te mandamos la confirmación por correo.`;
  document.getElementById("confirmacion").classList.remove("oculto");
  pintarIncentivoCorreos("incentivo-reserva");
});

// ---------- Inicio ----------
(async () => {
  const acceso = await requerirSesion();
  if (!acceso) return;
  await cargarReglasTiempo();
  llenarOpciones();
  actualizarPlano();
  const nombre = acceso.perfil && acceso.perfil.nombre;
  if (nombre) document.getElementById("saludo").textContent = `Hola, ${nombre}.`;
})();
