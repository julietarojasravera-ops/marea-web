// =========================================================
// Panel admin: Dashboard, Reservas y Mesas
// =========================================================

const HORARIOS_ADMIN = ["19:00", "19:30", "20:00", "20:30", "21:00", "21:30", "22:00"];
const UMBRAL_ALERTA = 80; // % de ocupación que dispara la alerta
const DURACION_MIN = 120; // cada reserva ocupa la mesa 2 horas

let mesas = [];     // se cargan una vez y se refrescan al editar
let clientes = [];  // para el formulario de nueva reserva
let editandoId = null;

// Evita que un nombre con símbolos rompa la tabla
function esc(texto) {
  return String(texto ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function aMinutos(hora) {
  const [h, m] = hora.split(":").map(Number);
  return h * 60 + m;
}

function avisoAdmin(tipo, texto) {
  mostrarAviso("aviso-admin", tipo, texto);
  window.scrollTo({ top: 0, behavior: "smooth" });
}

// ---------------------------------------------------------
// Pestañas
// ---------------------------------------------------------
document.querySelectorAll("[data-seccion]").forEach((boton) => {
  boton.addEventListener("click", () => {
    document.querySelectorAll("[data-seccion]").forEach((b) => b.classList.toggle("activa", b === boton));
    document.querySelectorAll(".seccion-admin").forEach((s) => s.classList.add("oculto"));
    document.getElementById(`sec-${boton.dataset.seccion}`).classList.remove("oculto");
    ocultarAviso("aviso-admin");
    if (boton.dataset.seccion === "dashboard") cargarDashboard();
    if (boton.dataset.seccion === "reservas") cargarReservas();
    if (boton.dataset.seccion === "mesas") pintarMesas();
  });
});

// ---------------------------------------------------------
// Datos base
// ---------------------------------------------------------
async function cargarMesas() {
  const { data, error } = await db.from("mesa").select("*").order("numero");
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }
  mesas = data;
}

async function cargarClientes() {
  const { data, error } = await db.from("usuario").select("id_usuario, nombre, email").order("nombre");
  if (!error) clientes = data;
}

// ---------------------------------------------------------
// DASHBOARD
// ---------------------------------------------------------
const dashFecha = document.getElementById("dash-fecha");
dashFecha.addEventListener("change", cargarDashboard);

async function cargarDashboard() {
  const { data, error } = await db
    .from("reserva")
    .select("id_reserva, id_mesa, hora, cantidad_personas, estado")
    .eq("fecha", dashFecha.value);
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }

  const activas = data.filter((r) => r.estado !== "cancelada");
  const canceladas = data.length - activas.length;
  const personas = activas.reduce((suma, r) => suma + r.cantidad_personas, 0);
  const mesasActivas = mesas.filter((m) => m.estado === "activa").length;

  // Ocupación: en cada media hora, cuántas mesas están tomadas.
  // Nos quedamos con el peor momento de la noche (hora pico).
  let pico = 0;
  let horaPico = null;
  for (let min = aMinutos("19:00"); min <= aMinutos("23:30"); min += 30) {
    const ocupadas = new Set(
      activas
        .filter((r) => aMinutos(r.hora) <= min && min < aMinutos(r.hora) + DURACION_MIN)
        .map((r) => r.id_mesa)
    ).size;
    if (ocupadas > pico) {
      pico = ocupadas;
      horaPico = `${String(Math.floor(min / 60)).padStart(2, "0")}:${String(min % 60).padStart(2, "0")}`;
    }
  }
  const ocupacion = mesasActivas ? Math.round((pico / mesasActivas) * 100) : 0;

  document.getElementById("kpi-reservas").textContent = activas.length;
  document.getElementById("kpi-personas").textContent = personas;
  document.getElementById("kpi-canceladas").textContent = canceladas;
  document.getElementById("kpi-ocupacion").textContent = `${ocupacion}%`;
  document.getElementById("kpi-ocupacion-nota").textContent = horaPico
    ? `${pico} de ${mesasActivas} mesas a las ${horaPico}`
    : `0 de ${mesasActivas} mesas`;

  // Alerta del 80 %
  const alerta = document.getElementById("alerta-ocupacion");
  const caja = document.getElementById("kpi-ocupacion-caja");
  const superada = ocupacion >= UMBRAL_ALERTA;
  alerta.classList.toggle("oculto", !superada);
  caja.classList.toggle("kpi-alerta", superada);
  if (superada) {
    alerta.textContent = `Atención: la ocupación llega al ${ocupacion}% a las ${horaPico}. ` +
      `Quedan ${mesasActivas - pico} mesas libres en ese horario.`;
  }

  pintarGrafico(activas);
}

function pintarGrafico(activas) {
  const conteo = Object.fromEntries(HORARIOS_ADMIN.map((h) => [h, 0]));
  activas.forEach((r) => {
    const h = formatearHora(r.hora);
    conteo[h] = (conteo[h] || 0) + 1;
  });
  const horas = Object.keys(conteo).sort();
  const maximo = Math.max(1, ...Object.values(conteo));

  document.getElementById("grafico-horas").innerHTML = horas.map((h) => {
    const nivel = Math.round((conteo[h] / maximo) * 10); // 0 a 10 -> clase CSS
    const esMax = conteo[h] === maximo && conteo[h] > 0;
    return `
      <div class="barra-col">
        <div class="barra-valor">${conteo[h]}</div>
        <div class="barra-pista"><div class="barra barra-h-${nivel} ${esMax ? "barra-max" : ""}"></div></div>
        <div class="barra-etiqueta">${h}</div>
      </div>`;
  }).join("");
}

// ---------------------------------------------------------
// RESERVAS
// ---------------------------------------------------------
const filtroFecha = document.getElementById("filtro-fecha");
const filtroEstado = document.getElementById("filtro-estado");
filtroFecha.addEventListener("change", cargarReservas);
filtroEstado.addEventListener("change", cargarReservas);
document.getElementById("btn-ver-todas").addEventListener("click", () => {
  filtroFecha.value = "";
  cargarReservas();
});

let reservasCargadas = [];

async function cargarReservas() {
  let consulta = db
    .from("reserva")
    .select("id_reserva, id_usuario, id_mesa, fecha, hora, cantidad_personas, estado, usuario(nombre, email), mesa(numero)")
    .order("fecha", { ascending: true })
    .order("hora", { ascending: true });
  if (filtroFecha.value) consulta = consulta.eq("fecha", filtroFecha.value);
  if (filtroEstado.value) consulta = consulta.eq("estado", filtroEstado.value);

  const { data, error } = await consulta;
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }
  reservasCargadas = data;

  const cuerpo = document.getElementById("tabla-reservas");
  if (!data.length) {
    cuerpo.innerHTML = `<tr><td colspan="7" class="text-center py-4 texto-suave">No hay reservas con esos filtros.</td></tr>`;
    return;
  }

  const opcionesEstado = (actual) => Object.entries(NOMBRES_ESTADO)
    .map(([valor, nombre]) => `<option value="${valor}" ${valor === actual ? "selected" : ""}>${nombre}</option>`)
    .join("");

  cuerpo.innerHTML = data.map((r) => `
    <tr>
      <td>
        <div class="celda-principal">${esc(r.usuario?.nombre || "Sin nombre")}</div>
        <div class="celda-secundaria">${esc(r.usuario?.email || "")}</div>
      </td>
      <td class="celda-fecha">${formatearFecha(r.fecha)}</td>
      <td>${formatearHora(r.hora)}</td>
      <td>${r.cantidad_personas}</td>
      <td>${r.mesa ? r.mesa.numero : "–"}</td>
      <td>
        <select class="form-select form-select-sm selector-estado estado-${r.estado}" data-estado="${r.id_reserva}">
          ${opcionesEstado(r.estado)}
        </select>
      </td>
      <td class="text-end">
        <button type="button" class="btn-borde" data-editar="${r.id_reserva}">Editar</button>
      </td>
    </tr>`).join("");
}

// Cambiar estado desde la tabla
document.getElementById("tabla-reservas").addEventListener("change", async (e) => {
  const selector = e.target.closest("[data-estado]");
  if (!selector) return;
  const { error } = await db
    .from("reserva")
    .update({ estado: selector.value })
    .eq("id_reserva", Number(selector.dataset.estado));
  if (error) { avisoAdmin("error", mensajeDeError(error)); cargarReservas(); return; }
  avisoAdmin("ok", `Reserva n.º ${selector.dataset.estado} marcada como "${NOMBRES_ESTADO[selector.value]}".`);
  cargarReservas();
});

// Abrir formulario para editar
document.getElementById("tabla-reservas").addEventListener("click", (e) => {
  const boton = e.target.closest("[data-editar]");
  if (!boton) return;
  const r = reservasCargadas.find((x) => x.id_reserva === Number(boton.dataset.editar));
  abrirPanel(r);
});

// ---------- Formulario crear / editar ----------
const panel = document.getElementById("panel-reserva");
const formReserva = document.getElementById("form-reserva");

function llenarSelectores() {
  document.getElementById("r-hora").innerHTML =
    HORARIOS_ADMIN.map((h) => `<option value="${h}">${h}</option>`).join("");
  document.getElementById("r-mesa").innerHTML =
    `<option value="">Automática (la más chica que sirva)</option>` +
    mesas.filter((m) => m.estado === "activa")
      .map((m) => `<option value="${m.id_mesa}">Mesa ${m.numero} · hasta ${m.capacidad} personas</option>`)
      .join("");
  document.getElementById("r-cliente").innerHTML =
    `<option value="">Elegí un cliente…</option>` +
    clientes.map((c) => `<option value="${c.id_usuario}">${esc(c.nombre || "Sin nombre")} · ${esc(c.email)}</option>`).join("");
}

function abrirPanel(reserva = null) {
  llenarSelectores();
  editandoId = reserva ? reserva.id_reserva : null;
  document.getElementById("panel-reserva-titulo").textContent =
    reserva ? `Editar reserva n.º ${reserva.id_reserva}` : "Nueva reserva";
  document.getElementById("grupo-cliente").classList.toggle("oculto", !!reserva);
  document.getElementById("r-cliente").required = !reserva;

  document.getElementById("r-fecha").value = reserva ? reserva.fecha : (filtroFecha.value || hoyISO());
  document.getElementById("r-hora").value = reserva ? formatearHora(reserva.hora) : "20:00";
  document.getElementById("r-personas").value = reserva ? reserva.cantidad_personas : 2;
  document.getElementById("r-mesa").value = reserva ? reserva.id_mesa : "";

  panel.classList.remove("oculto");
  ocultarAviso("aviso-admin");
  panel.scrollIntoView({ behavior: "smooth", block: "start" });
}

function cerrarPanel() {
  panel.classList.add("oculto");
  editandoId = null;
}

document.getElementById("btn-nueva-reserva").addEventListener("click", () => abrirPanel());
document.getElementById("btn-cerrar-panel").addEventListener("click", cerrarPanel);

formReserva.addEventListener("submit", async (e) => {
  e.preventDefault();
  const boton = formReserva.querySelector("button[type=submit]");
  boton.disabled = true;

  const fecha = document.getElementById("r-fecha").value;
  const hora = document.getElementById("r-hora").value;
  const personas = Number(document.getElementById("r-personas").value);
  let idMesa = document.getElementById("r-mesa").value;

  // Mesa automática: pedimos a la base la mejor mesa libre
  if (!idMesa) {
    const { data, error } = await db.rpc("mesas_disponibles", { p_fecha: fecha, p_hora: hora, p_personas: personas });
    const libres = data || [];
    if (error) { avisoAdmin("error", mensajeDeError(error)); boton.disabled = false; return; }
    if (!libres.length) {
      // Si estamos editando, probamos quedarnos en la mesa actual
      const actual = editandoId && reservasCargadas.find((r) => r.id_reserva === editandoId);
      if (actual) idMesa = actual.id_mesa;
      else { avisoAdmin("error", "No hay mesas libres para ese día, hora y cantidad de personas."); boton.disabled = false; return; }
    } else {
      idMesa = libres[0].id_mesa;
    }
  }

  const datos = { fecha, hora, cantidad_personas: personas, id_mesa: Number(idMesa) };
  let resultado;
  if (editandoId) {
    resultado = await db.from("reserva").update(datos).eq("id_reserva", editandoId);
  } else {
    const idCliente = document.getElementById("r-cliente").value;
    resultado = await db.from("reserva").insert({ ...datos, id_usuario: idCliente });
  }
  boton.disabled = false;

  if (resultado.error) { avisoAdmin("error", mensajeDeError(resultado.error)); return; }
  avisoAdmin("ok", editandoId ? "Reserva actualizada." : "Reserva creada.");
  cerrarPanel();
  cargarReservas();
});

// ---------------------------------------------------------
// MESAS
// ---------------------------------------------------------
function pintarMesas() {
  document.getElementById("tabla-mesas").innerHTML = mesas.map((m) => `
    <tr>
      <td class="celda-principal">Mesa ${m.numero}</td>
      <td>
        <div class="d-flex gap-2 align-items-center">
          <input class="form-control form-control-sm campo-corto" type="number" min="1" max="20"
                 value="${m.capacidad}" data-capacidad="${m.id_mesa}">
          <button type="button" class="btn-borde" data-guardar="${m.id_mesa}">Guardar</button>
        </div>
      </td>
      <td><span class="estado ${m.estado === "activa" ? "estado-confirmada" : "estado-cancelada"}">
        ${m.estado === "activa" ? "Activa" : "Inactiva"}</span></td>
      <td class="text-end">
        <button type="button" class="btn-borde ${m.estado === "activa" ? "btn-peligro" : ""}" data-alternar="${m.id_mesa}">
          ${m.estado === "activa" ? "Desactivar" : "Activar"}
        </button>
      </td>
    </tr>`).join("");
}

document.getElementById("tabla-mesas").addEventListener("click", async (e) => {
  const guardar = e.target.closest("[data-guardar]");
  const alternar = e.target.closest("[data-alternar]");
  if (!guardar && !alternar) return;

  let resultado;
  if (guardar) {
    const id = Number(guardar.dataset.guardar);
    const capacidad = Number(document.querySelector(`[data-capacidad="${id}"]`).value);
    if (capacidad < 1) { avisoAdmin("error", "La capacidad tiene que ser 1 o más."); return; }
    resultado = await db.from("mesa").update({ capacidad }).eq("id_mesa", id);
  } else {
    const id = Number(alternar.dataset.alternar);
    const mesa = mesas.find((m) => m.id_mesa === id);
    const nuevo = mesa.estado === "activa" ? "inactiva" : "activa";
    resultado = await db.from("mesa").update({ estado: nuevo }).eq("id_mesa", id);
  }

  if (resultado.error) { avisoAdmin("error", mensajeDeError(resultado.error)); return; }
  avisoAdmin("ok", "Mesa actualizada.");
  await cargarMesas();
  pintarMesas();
});

document.getElementById("form-mesa").addEventListener("submit", async (e) => {
  e.preventDefault();
  const numero = Number(document.getElementById("m-numero").value);
  const capacidad = Number(document.getElementById("m-capacidad").value);
  const { error } = await db.from("mesa").insert({ numero, capacidad });
  if (error) {
    const texto = error.message.includes("duplicate") ? `Ya existe la mesa ${numero}.` : mensajeDeError(error);
    avisoAdmin("error", texto);
    return;
  }
  e.target.reset();
  avisoAdmin("ok", `Mesa ${numero} agregada.`);
  await cargarMesas();
  pintarMesas();
});

// ---------------------------------------------------------
// Inicio
// ---------------------------------------------------------
(async () => {
  const acceso = await requerirSesion("admin");
  if (!acceso) return;
  const nombre = acceso.perfil && acceso.perfil.nombre;
  document.getElementById("saludo").textContent = `Hola${nombre ? ", " + nombre : ""}. Entraste como admin.`;

  dashFecha.value = hoyISO();
  filtroFecha.value = hoyISO();
  await Promise.all([cargarMesas(), cargarClientes()]);
  cargarDashboard();
})();
