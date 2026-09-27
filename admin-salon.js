// =========================================================
// Panel admin: salón en vivo, línea de tiempo y próximas llegadas
// Usa datos de admin.js: reservasDia, mesas, dashFecha, accionReserva...
// =========================================================

const selectHoraSalon = document.getElementById("salon-hora");
const detalleMesa = document.getElementById("detalle-mesa");
let mesaEnDetalle = null;
let fechaSalon = null;   // para saber si cambió el día

const ESTADOS_QUE_OCUPAN = ["confirmada", "sentada"];

function minutoActual() {
  const ahora = new Date();
  return inicioEnServicio(`${String(ahora.getHours()).padStart(2, "0")}:${String(ahora.getMinutes()).padStart(2, "0")}`);
}

// Turno más cercano a la hora actual (dentro del servicio)
function turnoActual() {
  const { apertura, cierre, intervalo } = rangoServicio();
  const ahora = minutoActual();
  const m = Math.min(cierre - intervalo, Math.max(apertura, Math.floor((ahora - apertura) / intervalo) * intervalo + apertura));
  return minutosAHora(m);
}

function primerNombre(r) {
  return (r.usuario?.nombre || "Cliente").split(" ")[0];
}

function rangoReserva(r) {
  const inicio = inicioEnServicio(formatearHora(r.hora));
  const fin = inicio + r.duracion_min;
  return { inicio, fin, finLimpieza: fin + (r.limpieza_min || 0) };
}

// ¿Cómo está una mesa en el minuto T del servicio?
function estadoMesaEn(mesa, t) {
  if (mesa.estado !== "activa") return { estado: "inactiva" };
  const suyas = reservasDia.filter((r) => r.id_mesa === mesa.id_mesa && ESTADOS_QUE_OCUPAN.includes(r.estado));
  for (const r of suyas) {
    const { inicio, fin, finLimpieza } = rangoReserva(r);
    // Si ya están sentados, la mesa sigue ocupada aunque se pasen del tiempo
    if (r.estado === "sentada" && t >= inicio && t < Math.max(fin, finLimpieza)) return { estado: "sentada", r };
    if (t >= inicio && t < fin) return { estado: r.estado === "sentada" ? "sentada" : "reservada", r };
    if (t >= fin && t < finLimpieza) return { estado: "limpieza", r };
  }
  const proxima = suyas
    .map((r) => ({ r, ...rangoReserva(r) }))
    .filter((x) => x.inicio > t && x.inicio - t <= 30)
    .sort((a, b) => a.inicio - b.inicio)[0];
  if (proxima) return { estado: "proxima", r: proxima.r };
  return { estado: "libre" };
}

// ---------------------------------------------------------
// Salón en vivo
// ---------------------------------------------------------
function pintarSalon() {
  const t = inicioEnServicio(selectHoraSalon.value);
  const estados = {};
  mesas.forEach((m) => { estados[m.id_mesa] = estadoMesaEn(m, t); });

  dibujarPlano(document.getElementById("plano-salon"), mesas, {
    estados,
    marcada: mesaEnDetalle,
    etiqueta: (m) => {
      const e = estados[m.id_mesa];
      if (!e.r || e.estado === "limpieza") return null;
      return `${primerNombre(e.r)} · ${formatearHora(e.r.hora)}`;
    },
    alElegir: (mesa) => mostrarDetalle(mesa.id_mesa),
  });
}

// ---------------------------------------------------------
// Detalle de una mesa: todas sus reservas del día
// ---------------------------------------------------------
function mostrarDetalle(idMesa) {
  mesaEnDetalle = idMesa;
  const mesa = mesas.find((m) => m.id_mesa === idMesa);
  if (!mesa) return;
  const suyas = reservasDia
    .filter((r) => r.id_mesa === idMesa && r.estado !== "cancelada")
    .sort((a, b) => rangoReserva(a).inicio - rangoReserva(b).inicio);

  const lista = suyas.length
    ? suyas.map((r) => `
      <div class="detalle-reserva">
        <div class="d-flex justify-content-between align-items-start gap-2">
          <div>
            <div class="celda-principal">${formatearHora(r.hora)} a ${sumarMinutos(formatearHora(r.hora), r.duracion_min)}
              · ${esc(r.usuario?.nombre || "Cliente")}</div>
            <div class="celda-secundaria">${r.cantidad_personas} personas${r.usuario?.telefono ? ` · ${esc(r.usuario.telefono)}` : ""}</div>
          </div>
          <span class="estado estado-${r.estado}">${NOMBRES_ESTADO[r.estado] || r.estado}</span>
        </div>
        ${r.ocasion ? `<div class="nota-ocasion">${NOMBRES_OCASION[r.ocasion] || esc(r.ocasion)}</div>` : ""}
        ${r.comentarios ? `<div class="detalle-comentario">“${esc(r.comentarios)}”</div>` : ""}
        <div class="acciones-reserva justify-content-start mt-2">${botonesAccion(r)}</div>
      </div>`).join("")
    : `<p class="pagina-bajada mb-0">Sin reservas este día.</p>`;

  detalleMesa.innerHTML = `
    <h2 class="grupo-titulo mt-0">Mesa ${mesa.numero}</h2>
    <p class="pagina-bajada">Para ${mesa.capacidad} personas${mesa.zona ? ` · ${esc(mesa.zona)}` : ""}${mesa.estado !== "activa" ? " · inactiva" : ""}</p>
    ${lista}`;
  pintarSalon();
}

detalleMesa.addEventListener("click", async (e) => {
  const boton = e.target.closest("[data-accion]");
  if (!boton) return;
  boton.disabled = true;
  await accionReserva(Number(boton.dataset.id), boton.dataset.accion);
  await cargarDashboard();
});

// ---------------------------------------------------------
// Próximas llegadas
// ---------------------------------------------------------
function pintarProximas() {
  const esHoy = dashFecha.value === hoyISO();
  const ahora = minutoActual();
  const lista = reservasDia
    .filter((r) => r.estado === "confirmada")
    .filter((r) => !esHoy || rangoReserva(r).inicio >= ahora - 30)
    .sort((a, b) => rangoReserva(a).inicio - rangoReserva(b).inicio)
    .slice(0, 6);

  const caja = document.getElementById("proximas-llegadas");
  if (!lista.length) {
    caja.innerHTML = `<p class="pagina-bajada mb-0">No hay llegadas pendientes.</p>`;
    return;
  }
  caja.innerHTML = lista.map((r) => {
    const atrasada = esHoy && rangoReserva(r).inicio + 15 < ahora;
    return `
      <div class="llegada ${atrasada ? "llegada-atrasada" : ""}">
        <div class="llegada-hora">${formatearHora(r.hora)}</div>
        <div class="llegada-datos">
          <div class="celda-principal">${esc(r.usuario?.nombre || "Cliente")} ${r.ocasion ? (NOMBRES_OCASION[r.ocasion] || "").split(" ")[0] : ""}</div>
          <div class="celda-secundaria">${r.cantidad_personas} pers. · mesa ${r.mesa?.numero ?? "–"}${atrasada ? " · demorados" : ""}</div>
        </div>
        <div class="acciones-reserva">
          <button type="button" class="btn-borde" data-accion="sentar" data-id="${r.id_reserva}">Sentar</button>
          ${atrasada ? `<button type="button" class="btn-borde btn-peligro" data-accion="noshow" data-id="${r.id_reserva}">No vino</button>` : ""}
        </div>
      </div>`;
  }).join("");
}

document.getElementById("proximas-llegadas").addEventListener("click", async (e) => {
  const boton = e.target.closest("[data-accion]");
  if (!boton) return;
  boton.disabled = true;
  await accionReserva(Number(boton.dataset.id), boton.dataset.accion);
  await cargarDashboard();
});

// ---------------------------------------------------------
// Línea de tiempo (una fila por mesa, una barra por reserva)
// ---------------------------------------------------------
const LT = { etiqueta: 92, porCuarto: 44, fila: 30, cabecera: 28 };

function pintarLineaTiempo() {
  const svg = document.getElementById("linea-tiempo");
  const { apertura, cierre } = rangoServicio();
  const cuartos = (cierre - apertura) / 15;
  const ancho = LT.etiqueta + cuartos * LT.porCuarto + 24;
  const ordenadas = [...mesas].sort((a, b) => a.numero - b.numero);
  const alto = LT.cabecera + ordenadas.length * LT.fila + 6;
  const xDe = (min) => LT.etiqueta + ((min - apertura) / 15) * LT.porCuarto;

  svg.innerHTML = "";
  svg.setAttribute("viewBox", `0 0 ${ancho} ${alto}`);
  const defs = nodo("defs");
  const patron = nodo("pattern", { id: "rayado", width: 6, height: 6, patternUnits: "userSpaceOnUse", patternTransform: "rotate(45)" });
  patron.appendChild(nodo("rect", { width: 6, height: 6, class: "rayado-fondo" }));
  patron.appendChild(nodo("line", { x1: 0, y1: 0, x2: 0, y2: 6, class: "rayado-linea" }));
  defs.appendChild(patron);
  svg.appendChild(defs);

  // Filas
  ordenadas.forEach((m, i) => {
    const y = LT.cabecera + i * LT.fila;
    svg.appendChild(nodo("rect", { x: 0, y, width: ancho, height: LT.fila, class: i % 2 ? "lt-fila" : "lt-fila lt-fila-par" }));
    svg.appendChild(nodo("text", { x: 8, y: y + LT.fila / 2 + 4, class: "lt-mesa" }, `Mesa ${m.numero}`));
    svg.appendChild(nodo("text", { x: LT.etiqueta - 8, y: y + LT.fila / 2 + 4, class: "lt-cap", "text-anchor": "end" }, `${m.capacidad}p`));
  });

  // Grilla de horas
  for (let min = apertura; min <= cierre; min += 30) {
    const x = xDe(min);
    const enHora = (min - apertura) % 60 === 0;
    svg.appendChild(nodo("line", { x1: x, y1: LT.cabecera - 4, x2: x, y2: alto, class: enHora ? "lt-grilla lt-grilla-hora" : "lt-grilla" }));
    if (enHora) svg.appendChild(nodo("text", { x, y: 16, class: "lt-hora", "text-anchor": "middle" }, minutosAHora(min)));
  }

  // Barras de reservas
  reservasDia
    .filter((r) => r.estado !== "cancelada")
    .forEach((r) => {
      const fila = ordenadas.findIndex((m) => m.id_mesa === r.id_mesa);
      if (fila < 0) return;
      const { inicio, fin, finLimpieza } = rangoReserva(r);
      const y = LT.cabecera + fila * LT.fila + 4;
      const g = nodo("g", { class: `lt-reserva lt-${r.estado}`, "data-mesa": r.id_mesa, "data-hora": formatearHora(r.hora), tabindex: "0", role: "button" });
      g.appendChild(nodo("title", {}, `${formatearHora(r.hora)} · ${r.usuario?.nombre || "Cliente"} · ${r.cantidad_personas} pers. · ${NOMBRES_ESTADO[r.estado]}`));
      if (finLimpieza > fin) {
        g.appendChild(nodo("rect", { x: xDe(fin), y: y + 3, width: xDe(finLimpieza) - xDe(fin) - 1, height: LT.fila - 14, rx: 3, class: "lt-limpieza" }));
      }
      const w = xDe(fin) - xDe(inicio) - 2;
      g.appendChild(nodo("rect", { x: xDe(inicio) + 1, y, width: w, height: LT.fila - 8, rx: 5, class: "lt-barra" }));
      if (w > 40) {
        const texto = w > 90 ? `${primerNombre(r)} · ${r.cantidad_personas}p` : `${r.cantidad_personas}p`;
        g.appendChild(nodo("text", { x: xDe(inicio) + 7, y: y + (LT.fila - 8) / 2 + 4, class: "lt-texto" }, texto));
      }
      svg.appendChild(g);
    });

  // Línea de "ahora"
  if (dashFecha.value === hoyISO()) {
    const ahora = minutoActual();
    if (ahora >= apertura && ahora <= cierre) {
      svg.appendChild(nodo("line", { x1: xDe(ahora), y1: LT.cabecera - 6, x2: xDe(ahora), y2: alto, class: "lt-ahora" }));
      svg.appendChild(nodo("text", { x: xDe(ahora), y: LT.cabecera - 8, class: "lt-ahora-texto", "text-anchor": "middle" }, "ahora"));
    }
  }
}

document.getElementById("linea-tiempo").addEventListener("click", (e) => {
  const barra = e.target.closest(".lt-reserva");
  if (!barra) return;
  selectHoraSalon.value = barra.dataset.hora;
  mostrarDetalle(Number(barra.dataset.mesa));
  document.getElementById("plano-salon").scrollIntoView({ behavior: "smooth", block: "center" });
});
document.getElementById("linea-tiempo").addEventListener("keydown", (e) => {
  if ((e.key === "Enter" || e.key === " ") && e.target.closest(".lt-reserva")) {
    e.preventDefault();
    e.target.closest(".lt-reserva").dispatchEvent(new MouseEvent("click", { bubbles: true }));
  }
});

// ---------------------------------------------------------
// Preparación y refresco
// ---------------------------------------------------------
function prepararSalon() {
  selectHoraSalon.innerHTML = horariosAdmin().map((h) => `<option value="${h}">${h}</option>`).join("");
  selectHoraSalon.addEventListener("change", pintarSalon);
  document.getElementById("salon-ahora").addEventListener("click", () => {
    if (dashFecha.value !== hoyISO()) {
      dashFecha.value = hoyISO();
      fechaSalon = null;
      cargarDashboard();
    } else {
      selectHoraSalon.value = turnoActual();
      pintarSalon();
    }
  });
}

// La llama cargarDashboard() cada vez que se cargan las reservas del día
function pintarPanelSalon() {
  if (fechaSalon !== dashFecha.value) {
    fechaSalon = dashFecha.value;
    selectHoraSalon.value = dashFecha.value === hoyISO() ? turnoActual() : "20:00";
    mesaEnDetalle = null;
    detalleMesa.innerHTML = `<h2 class="grupo-titulo mt-0">Detalle de mesa</h2>
      <p class="pagina-bajada mb-0">Tocá una mesa del plano o una barra de la línea de tiempo.</p>`;
  }
  pintarSalon();
  pintarLineaTiempo();
  pintarProximas();
  if (mesaEnDetalle) mostrarDetalle(mesaEnDetalle);
}
