// =========================================================
// Panel admin: Dashboard, Reservas, Mesas (y tiempos) y Clientes
// =========================================================

const UMBRAL_ALERTA = 80; // % de ocupación que dispara la alerta
const ESTADOS_EN_MESA = ["confirmada", "sentada", "completada"]; // cuentan para la ocupación

let mesas = [];     // se cargan una vez y se refrescan al editar
let clientes = [];  // para el formulario de nueva reserva
let editandoId = null;

// Evita que un nombre con símbolos rompa la tabla
function esc(texto) {
  return String(texto ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

// Minutos de apertura y cierre (si cierra a las 00:00, es 24:00)
function rangoServicio() {
  const a = reglasTiempo.ajustes;
  const apertura = aMinutos(a.apertura);
  let cierre = aMinutos(a.cierre);
  if (cierre <= apertura) cierre += 1440;
  return { apertura, cierre, intervalo: a.intervalo_min };
}

// El admin puede cargar reservas en cualquier turno del servicio
function horariosAdmin() {
  const { apertura, cierre, intervalo } = rangoServicio();
  const lista = [];
  for (let m = apertura; m < cierre; m += intervalo) lista.push(minutosAHora(m));
  return lista;
}

// Minuto de inicio de una reserva dentro del servicio (00:30 = 24:30)
function inicioEnServicio(hora) {
  const { apertura } = rangoServicio();
  const m = aMinutos(hora);
  return m < apertura ? m + 1440 : m;
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
    if (boton.dataset.seccion === "mesas") { pintarMesas(); pintarTiempos(); }
    if (boton.dataset.seccion === "clientes") cargarClientesTabla();
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
  const { data, error } = await db
    .from("usuario")
    .select("id_usuario, nombre, email, rol, fecha_creacion")
    .order("nombre");
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
    .select("id_reserva, id_mesa, hora, cantidad_personas, estado, duracion_min")
    .eq("fecha", dashFecha.value);
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }

  const activas = data.filter((r) => r.estado !== "cancelada");
  const canceladas = data.length - activas.length;
  const personas = activas.reduce((suma, r) => suma + r.cantidad_personas, 0);
  const mesasActivas = mesas.filter((m) => m.estado === "activa").length;

  // Ocupación: en cada turno del servicio, cuántas mesas tienen gente
  // (cada reserva ocupa la mesa según su propio tiempo de mesa).
  // Nos quedamos con el peor momento de la noche (hora pico).
  const enMesa = data.filter((r) => ESTADOS_EN_MESA.includes(r.estado));
  const { apertura, cierre, intervalo } = rangoServicio();
  let pico = 0;
  let horaPico = null;
  for (let min = apertura; min < cierre; min += intervalo) {
    const ocupadas = new Set(
      enMesa
        .filter((r) => {
          const inicio = inicioEnServicio(formatearHora(r.hora));
          return inicio <= min && min < inicio + r.duracion_min;
        })
        .map((r) => r.id_mesa)
    ).size;
    if (ocupadas > pico) {
      pico = ocupadas;
      horaPico = minutosAHora(min);
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
  // Reservas que empiezan en cada media hora
  const { apertura, cierre } = rangoServicio();
  const conteo = {};
  for (let m = apertura; m < cierre - 60; m += 30) conteo[minutosAHora(m)] = 0;
  activas.forEach((r) => {
    const inicio = inicioEnServicio(formatearHora(r.hora));
    const bloque = minutosAHora(apertura + Math.floor((inicio - apertura) / 30) * 30);
    conteo[bloque] = (conteo[bloque] || 0) + 1;
  });
  const horas = Object.keys(conteo).sort((a, b) => inicioEnServicio(a) - inicioEnServicio(b));
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
    .select("id_reserva, id_usuario, id_mesa, fecha, hora, cantidad_personas, estado, duracion_min, usuario(nombre, email), mesa(numero)")
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
      <td class="celda-fecha">${formatearHora(r.hora)} a ${sumarMinutos(formatearHora(r.hora), r.duracion_min)}</td>
      <td>${r.cantidad_personas}</td>
      <td>${r.mesa ? r.mesa.numero : "–"}</td>
      <td>
        <select class="form-select form-select-sm selector-estado estado-${r.estado}" data-estado="${r.id_reserva}">
          ${opcionesEstado(r.estado)}
        </select>
      </td>
      <td class="text-end">
        <div class="acciones-reserva">
          ${r.estado === "confirmada" ? `<button type="button" class="btn-borde" data-accion="sentar" data-id="${r.id_reserva}">Sentar</button>` : ""}
          ${r.estado === "sentada" ? `<button type="button" class="btn-borde" data-accion="liberar" data-id="${r.id_reserva}">Liberar mesa</button>` : ""}
          ${["confirmada", "sentada"].includes(r.estado) ? `<button type="button" class="btn-borde" data-accion="extender" data-id="${r.id_reserva}" title="Se quedan más tiempo">+15 min</button>` : ""}
          <button type="button" class="btn-borde" data-editar="${r.id_reserva}">Editar</button>
        </div>
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

// Acciones rápidas del salón: sentar, liberar mesa, extender
document.getElementById("tabla-reservas").addEventListener("click", async (e) => {
  const accion = e.target.closest("[data-accion]");
  if (!accion) return;
  const id = Number(accion.dataset.id);
  accion.disabled = true;
  let resultado;
  let texto;
  if (accion.dataset.accion === "sentar") {
    resultado = await db.from("reserva").update({ estado: "sentada" }).eq("id_reserva", id);
    texto = `Reserva n.º ${id}: el grupo ya está en la mesa.`;
  } else if (accion.dataset.accion === "liberar") {
    resultado = await db.from("reserva").update({ estado: "completada" }).eq("id_reserva", id);
    texto = `Reserva n.º ${id}: mesa liberada. Ya se puede volver a reservar.`;
  } else {
    resultado = await db.rpc("extender_reserva", { p_id_reserva: id, p_minutos: 15 });
    texto = `Reserva n.º ${id}: se extendió 15 minutos.`;
  }
  if (resultado.error) { avisoAdmin("error", mensajeDeError(resultado.error)); }
  else { avisoAdmin("ok", texto); }
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
    horariosAdmin().map((h) => `<option value="${h}">${h}</option>`).join("");
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
// TIEMPOS DE MESA (reglas del restaurante)
// ---------------------------------------------------------
function pintarTiempos() {
  const a = reglasTiempo.ajustes;
  document.getElementById("t-apertura").value = formatearHora(a.apertura);
  document.getElementById("t-cierre").value = formatearHora(a.cierre);
  document.getElementById("t-intervalo").value = String(a.intervalo_min);
  document.getElementById("t-limpieza").value = a.limpieza_min;
  document.getElementById("t-pacing").value = a.max_personas_por_turno;
  pintarDuraciones(reglasTiempo.duraciones);
}

function pintarDuraciones(lista) {
  document.getElementById("tabla-duraciones").innerHTML = lista.map((d, i) => `
    <tr>
      <td>
        <div class="d-flex align-items-center gap-2">
          <span class="texto-suave">hasta</span>
          <input class="form-control form-control-sm campo-corto" type="number" min="1" max="99"
                 value="${d.hasta_personas}" data-dur-personas="${i}">
          <span class="texto-suave">personas</span>
        </div>
      </td>
      <td>
        <div class="d-flex align-items-center gap-2">
          <input class="form-control form-control-sm campo-corto" type="number" min="30" max="300" step="15"
                 value="${d.minutos}" data-dur-minutos="${i}">
          <span class="texto-suave">min</span>
        </div>
      </td>
      <td class="text-end">
        <button type="button" class="btn-borde btn-peligro" data-dur-quitar="${i}">Quitar</button>
      </td>
    </tr>`).join("");
}

function leerDuraciones() {
  return [...document.querySelectorAll("[data-dur-personas]")].map((campo) => ({
    hasta_personas: Number(campo.value),
    minutos: Number(document.querySelector(`[data-dur-minutos="${campo.dataset.durPersonas}"]`).value),
  }));
}

document.getElementById("btn-agregar-duracion").addEventListener("click", () => {
  const lista = leerDuraciones();
  const ultimo = lista.length ? lista[lista.length - 1] : { hasta_personas: 0, minutos: 90 };
  lista.push({ hasta_personas: ultimo.hasta_personas + 2, minutos: ultimo.minutos + 30 });
  pintarDuraciones(lista);
});

document.getElementById("tabla-duraciones").addEventListener("click", (e) => {
  const boton = e.target.closest("[data-dur-quitar]");
  if (!boton) return;
  const lista = leerDuraciones();
  lista.splice(Number(boton.dataset.durQuitar), 1);
  pintarDuraciones(lista);
});

document.getElementById("form-tiempos").addEventListener("submit", async (e) => {
  e.preventDefault();
  const lista = leerDuraciones().sort((x, y) => x.hasta_personas - y.hasta_personas);
  const personasRepetidas = new Set(lista.map((d) => d.hasta_personas)).size !== lista.length;
  if (!lista.length || personasRepetidas || lista.some((d) => !d.hasta_personas || d.minutos < 30 || d.minutos > 300)) {
    avisoAdmin("error", "Revisá los tiempos por grupo: sin cantidades repetidas y entre 30 y 300 minutos.");
    return;
  }

  const ajustes = {
    apertura: document.getElementById("t-apertura").value,
    cierre: document.getElementById("t-cierre").value,
    intervalo_min: Number(document.getElementById("t-intervalo").value),
    limpieza_min: Number(document.getElementById("t-limpieza").value),
    max_personas_por_turno: Number(document.getElementById("t-pacing").value),
  };
  const r1 = await db.from("ajustes_reserva").update(ajustes).eq("id", 1);
  if (r1.error) { avisoAdmin("error", mensajeDeError(r1.error)); return; }

  // Reemplaza las reglas por grupo: borra las que se quitaron y guarda el resto
  const actuales = reglasTiempo.duraciones.map((d) => d.hasta_personas);
  const quitar = actuales.filter((n) => !lista.some((d) => d.hasta_personas === n));
  if (quitar.length) {
    const r2 = await db.from("duracion_por_grupo").delete().in("hasta_personas", quitar);
    if (r2.error) { avisoAdmin("error", mensajeDeError(r2.error)); return; }
  }
  const r3 = await db.from("duracion_por_grupo").upsert(lista, { onConflict: "hasta_personas" });
  if (r3.error) { avisoAdmin("error", mensajeDeError(r3.error)); return; }

  await cargarReglasTiempo();
  pintarTiempos();
  avisoAdmin("ok", "Tiempos guardados. Se aplican a las reservas nuevas.");
});

// ---------------------------------------------------------
// CLIENTES
// ---------------------------------------------------------
let filasClientes = [];

async function cargarClientesTabla() {
  await cargarClientes();
  const { data, error } = await db.from("reserva").select("id_usuario, fecha, hora, estado");
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }

  const hoy = hoyISO();
  filasClientes = clientes.map((c) => {
    const propias = data.filter((r) => r.id_usuario === c.id_usuario);
    const validas = propias.filter((r) => r.estado !== "cancelada");
    const asistio = propias.filter((r) => r.estado === "completada");
    const fallas = propias.filter((r) => r.estado === "cancelada" || r.estado === "no_asistio");
    const ultima = asistio.map((r) => r.fecha).sort().pop() || null;
    const proxima = propias
      .filter((r) => r.estado === "confirmada" && r.fecha >= hoy)
      .map((r) => r.fecha).sort()[0] || null;
    return { ...c, total: validas.length, asistio: asistio.length, fallas: fallas.length, ultima, proxima };
  });

  const soloClientes = filasClientes.filter((c) => c.rol === "cliente").length;
  document.getElementById("resumen-clientes").textContent =
    `${soloClientes} ${soloClientes === 1 ? "cliente registrado" : "clientes registrados"}`;
  pintarClientes();
}

function pintarClientes() {
  const texto = document.getElementById("buscar-cliente").value.trim().toLowerCase();
  const lista = filasClientes.filter((c) =>
    !texto || (c.nombre || "").toLowerCase().includes(texto) || c.email.toLowerCase().includes(texto));

  const cuerpo = document.getElementById("tabla-clientes");
  if (!lista.length) {
    cuerpo.innerHTML = `<tr><td colspan="7" class="text-center py-4 texto-suave">No hay clientes que coincidan.</td></tr>`;
    return;
  }
  const fechaCorta = (f) => f ? formatearFecha(f) : "–";
  cuerpo.innerHTML = lista.map((c) => `
    <tr>
      <td>
        <div class="celda-principal">${esc(c.nombre || "Sin nombre")}
          ${c.rol === "admin" ? '<span class="estado estado-completada ms-1">Admin</span>' : ""}</div>
        <div class="celda-secundaria">${esc(c.email)}</div>
      </td>
      <td class="celda-fecha">${c.fecha_creacion ? new Date(c.fecha_creacion).toLocaleDateString("es-UY") : "–"}</td>
      <td>${c.total}</td>
      <td>${c.asistio}</td>
      <td>${c.fallas}</td>
      <td class="celda-fecha">${fechaCorta(c.ultima)}</td>
      <td class="celda-fecha">${fechaCorta(c.proxima)}</td>
    </tr>`).join("");
}

document.getElementById("buscar-cliente").addEventListener("input", pintarClientes);

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
  await Promise.all([cargarMesas(), cargarClientes(), cargarReglasTiempo()]);
  cargarDashboard();
})();
