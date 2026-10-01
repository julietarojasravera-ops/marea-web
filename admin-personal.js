// =========================================================
// Panel admin: Clima y personal
//  · Guarda el clima de cada noche (API de Open-Meteo, últimos 92 días
//    + próximos 16) junto a las reservas.
//  · Muestra cómo cambia la cantidad de cubiertos según el clima.
//  · Sugiere cuántos mozos poner cada noche.
// "Cubiertos" = personas atendidas. Como no registramos montos de
// venta, los cubiertos son la medida de cuánto se vendió esa noche.
// También: tarjeta "Invitá a sumarse" del Dashboard (clientes sin correos).
// =========================================================

const CATEGORIAS = {
  calida:   { nombre: "Cálida",            detalle: "22 °C o más",        icono: "☀️" },
  templada: { nombre: "Templada",          detalle: "de 16 a 22 °C",      icono: "🌤️" },
  fria:     { nombre: "Fría",              detalle: "menos de 16 °C",     icono: "🧥" },
  lluvia:   { nombre: "Lluvia o tormenta", detalle: "llueve de 19 a 23 h", icono: "🌧️" },
};
const NOMBRE_DIA = ["", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"];
const DIAS_PLURAL = ["", "lunes", "martes", "miércoles", "jueves", "viernes", "sábados", "domingos"];
const CON_CLIMA = { calida: "cálidos", templada: "templados", fria: "fríos", lluvia: "con lluvia" };
const FIN_DE_SEMANA = [5, 6];      // viernes y sábado

let historiaNoches = [];
let ajustesPersonal = { cubiertos_por_mozo: 20, mozos_minimos: 2 };
let climaGuardadoHoy = false;

function sumarDias(fechaISO, n) {
  const [a, m, d] = fechaISO.split("-").map(Number);
  const f = new Date(a, m - 1, d + n);
  return `${f.getFullYear()}-${String(f.getMonth() + 1).padStart(2, "0")}-${String(f.getDate()).padStart(2, "0")}`;
}
const diaYMes = (f) => formatearFecha(f).split(", ").slice(1).join(", ");
const soloDia = (f) => formatearFecha(f).split(",")[0];
const promedio = (xs) => (xs.length ? xs.reduce((s, x) => s + x, 0) / xs.length : null);

// Clima de una noche → categoría (las mismas reglas que el script de demostración)
function categoria(n) {
  if (n.temp_noche == null) return null;
  const temp = Number(n.temp_noche);
  if (Number(n.lluvia_noche_mm || 0) >= 1 || Number(n.codigo || 0) >= 61
      || (n.es_pronostico && Number(n.prob_lluvia || 0) >= 60)) return "lluvia";
  if (temp >= 22) return "calida";
  if (temp >= 16) return "templada";
  return "fria";
}

// ---------- 1) Traer el clima de Open-Meteo y guardarlo ----------
async function traerYGuardarClima() {
  const url = `${CLIMA_URL}?latitude=${CLIMA_LUGAR.lat}&longitude=${CLIMA_LUGAR.lon}` +
    "&hourly=temperature_2m,precipitation,weather_code" +
    "&daily=temperature_2m_max,precipitation_sum,precipitation_probability_max,wind_speed_10m_max" +
    "&timezone=America%2FMontevideo&past_days=92&forecast_days=16";
  const r = await fetch(url);
  if (!r.ok) throw new Error("Open-Meteo no respondió");
  const datos = await r.json();
  const noches = {};
  datos.hourly.time.forEach((t, i) => {
    const hora = Number(t.slice(11, 13));
    if (hora < 19 || hora > 23) return;
    const f = t.slice(0, 10);
    const n = noches[f] || (noches[f] = { temps: [], lluvia: 0, codigo: 0 });
    if (datos.hourly.temperature_2m[i] != null) n.temps.push(datos.hourly.temperature_2m[i]);
    n.lluvia += datos.hourly.precipitation[i] || 0;
    n.codigo = Math.max(n.codigo, datos.hourly.weather_code[i] || 0);
  });
  const d = datos.daily;
  const dias = d.time.map((f, i) => ({
    fecha: f,
    temp_max: d.temperature_2m_max[i],
    temp_noche: noches[f] && noches[f].temps.length ? Math.round(promedio(noches[f].temps) * 10) / 10 : null,
    lluvia_mm: d.precipitation_sum[i],
    lluvia_noche_mm: noches[f] ? Math.round(noches[f].lluvia * 10) / 10 : null,
    prob_lluvia: d.precipitation_probability_max[i],
    codigo: noches[f] ? noches[f].codigo : null,
    viento_max: d.wind_speed_10m_max[i],
  })).filter((x) => x.temp_noche != null);
  const { error } = await db.rpc("guardar_clima", { p_dias: dias });
  if (error) throw error;
  return dias.length;
}

// ---------- 2) Historial: clima + cubiertos + mozos ----------
async function cargarHistoria() {
  const hoy = hoyISO();
  const [h, a] = await Promise.all([
    db.rpc("historial_noches", { p_desde: sumarDias(hoy, -91), p_hasta: sumarDias(hoy, 15) }),
    db.from("ajustes_personal").select("*").eq("id", 1).single(),
  ]);
  if (h.error) throw h.error;
  historiaNoches = h.data;
  if (a.data) ajustesPersonal = a.data;
}

async function asegurarDatos() {
  if (!climaGuardadoHoy) {
    try { await traerYGuardarClima(); climaGuardadoHoy = true; }
    catch (e) { console.warn("No se pudo actualizar el clima:", e); }
  }
  await cargarHistoria();
}

const nochesPasadas = () => historiaNoches.filter((n) => n.fecha < hoyISO() && n.cubiertos > 0 && categoria(n));

// ---------- 3) Previsión de cubiertos y mozos ----------
function prever(n) {
  const cat = categoria(n);
  const pasadas = nochesPasadas();
  const mismoDia = pasadas.filter((h) => h.dia_semana === n.dia_semana);
  const parecidas = cat ? mismoDia.filter((h) => categoria(h) === cat) : [];
  let base = null;
  let criterio = "";
  if (parecidas.length >= 2) {
    base = promedio(parecidas.map((h) => h.cubiertos));
    criterio = `promedio de ${parecidas.length} ${DIAS_PLURAL[n.dia_semana]} ${CON_CLIMA[cat]}`;
  } else if (mismoDia.length >= 2) {
    base = promedio(mismoDia.map((h) => h.cubiertos));
    criterio = `promedio de ${mismoDia.length} ${DIAS_PLURAL[n.dia_semana]} (pocas noches con este clima)`;
  } else {
    criterio = "sin historial para este día: solo cuenta lo reservado";
  }
  const esperados = Math.max(n.reservados || 0, Math.round(base || 0));
  const mozos = esperados ? Math.max(ajustesPersonal.mozos_minimos, Math.ceil(esperados / ajustesPersonal.cubiertos_por_mozo)) : 0;
  return { cat, esperados, mozos, criterio };
}

function textoClima(n) {
  const cat = categoria(n);
  if (!cat) return '<span class="texto-suave">sin datos</span>';
  const lluvia = n.es_pronostico
    ? ` · 💧 ${n.prob_lluvia ?? 0} %`
    : Number(n.lluvia_noche_mm) > 0 ? ` · ${n.lluvia_noche_mm} mm` : "";
  return `<span class="clima-chip clima-${cat}" title="${CATEGORIAS[cat].nombre}">${CATEGORIAS[cat].icono} ${Math.round(n.temp_noche)}°</span>` +
         `<span class="celda-secundaria">${CATEGORIAS[cat].nombre}${lluvia}</span>`;
}

// ---------- 4) Análisis: ¿cómo cambia la gente según el clima? ----------
function analizar() {
  const pasadas = nochesPasadas();
  // Para comparar justo, cada noche se mide contra el promedio de su día de la semana
  const porDia = {};
  pasadas.forEach((n) => (porDia[n.dia_semana] = porDia[n.dia_semana] || []).push(n.cubiertos));
  const promDia = Object.fromEntries(Object.entries(porDia).map(([d, xs]) => [d, promedio(xs)]));
  const puntos = pasadas.map((n) => ({ ...n, indice: n.cubiertos / promDia[n.dia_semana], cat: categoria(n) }));

  // correlación entre temperatura de la noche e índice (noches sin lluvia)
  const secas = puntos.filter((p) => p.cat !== "lluvia");
  let r = null;
  let pendiente = null;
  if (secas.length >= 5) {
    const mx = promedio(secas.map((p) => Number(p.temp_noche)));
    const my = promedio(secas.map((p) => p.indice));
    let sxy = 0, sxx = 0, syy = 0;
    secas.forEach((p) => {
      const dx = Number(p.temp_noche) - mx, dy = p.indice - my;
      sxy += dx * dy; sxx += dx * dx; syy += dy * dy;
    });
    r = sxx && syy ? sxy / Math.sqrt(sxx * syy) : null;
    pendiente = sxx ? sxy / sxx : null;      // índice por °C
  }
  const lluvia = puntos.filter((p) => p.cat === "lluvia");
  const efectoLluvia = lluvia.length >= 2 && secas.length >= 2
    ? promedio(lluvia.map((p) => p.indice)) / promedio(secas.map((p) => p.indice)) - 1 : null;
  const conMozos = pasadas.filter((n) => n.mozos > 0);
  const cubPorMozo = conMozos.length
    ? conMozos.reduce((s, n) => s + n.cubiertos, 0) / conMozos.reduce((s, n) => s + n.mozos, 0) : null;

  // promedio de cubiertos por categoría, fin de semana vs. resto
  const barras = Object.keys(CATEGORIAS).map((cat) => {
    const de = (finde) => puntos.filter((p) => p.cat === cat && FIN_DE_SEMANA.includes(p.dia_semana) === finde);
    const fs = de(true), sem = de(false);
    return {
      cat,
      finde: fs.length ? Math.round(promedio(fs.map((p) => p.cubiertos))) : null, nFinde: fs.length,
      semana: sem.length ? Math.round(promedio(sem.map((p) => p.cubiertos))) : null, nSemana: sem.length,
    };
  });
  return { puntos, r, pendiente, efectoLluvia, cubPorMozo, barras, noches: pasadas.length };
}

function fuerza(r) {
  const a = Math.abs(r);
  if (a >= 0.5) return "fuerte";
  if (a >= 0.3) return "moderada";
  if (a >= 0.1) return "débil";
  return "casi nula";
}

// ---------- Gráficos (SVG simple, sin librerías) ----------
function graficoBarras(barras) {
  const W = 620, H = 270, izq = 44, abajo = 54, arriba = 22;
  const max = Math.max(10, ...barras.flatMap((b) => [b.finde || 0, b.semana || 0]));
  const tope = Math.ceil(max / 10) * 10;
  const alto = H - abajo - arriba;
  const ancho = (W - izq - 10) / barras.length;
  const y = (v) => arriba + alto - (v / tope) * alto;
  let s = `<svg viewBox="0 0 ${W} ${H}" class="grafico-svg" role="img" aria-label="Cubiertos promedio por clima">`;
  for (let i = 0; i <= 4; i++) {
    const v = (tope / 4) * i;
    s += `<line x1="${izq}" x2="${W - 10}" y1="${y(v)}" y2="${y(v)}" class="eje-linea"/>` +
         `<text x="${izq - 8}" y="${y(v) + 4}" text-anchor="end" class="eje-texto">${Math.round(v)}</text>`;
  }
  barras.forEach((b, i) => {
    const x0 = izq + i * ancho + ancho * 0.14;
    const bw = ancho * 0.34;
    [["finde", "barra-finde", b.finde, b.nFinde], ["semana", "barra-semana", b.semana, b.nSemana]].forEach(([, clase, v, n], k) => {
      const x = x0 + k * (bw + 4);
      if (v == null) {
        s += `<text x="${x + bw / 2}" y="${y(0) - 6}" text-anchor="middle" class="eje-texto">–</text>`;
        return;
      }
      s += `<rect x="${x}" y="${y(v)}" width="${bw}" height="${y(0) - y(v)}" rx="4" class="${clase}"><title>${n} noches</title></rect>` +
           `<text x="${x + bw / 2}" y="${y(v) - 6}" text-anchor="middle" class="barra-valor">${v}</text>`;
    });
    const c = CATEGORIAS[b.cat];
    s += `<text x="${izq + i * ancho + ancho / 2}" y="${H - abajo + 20}" text-anchor="middle" class="eje-cat">${c.icono} ${c.nombre}</text>` +
         `<text x="${izq + i * ancho + ancho / 2}" y="${H - abajo + 38}" text-anchor="middle" class="eje-texto">${c.detalle}</text>`;
  });
  return s + "</svg>";
}

function graficoPuntos(puntos) {
  const W = 460, H = 270, izq = 40, abajo = 40, arriba = 14, der = 12;
  if (!puntos.length) return '<p class="pagina-bajada">Todavía no hay noches con datos.</p>';
  const temps = puntos.map((p) => Number(p.temp_noche));
  const tMin = Math.floor(Math.min(...temps) / 2) * 2, tMax = Math.ceil(Math.max(...temps) / 2) * 2 || tMin + 2;
  const cMax = Math.ceil(Math.max(...puntos.map((p) => p.cubiertos)) / 10) * 10 || 10;
  const x = (t) => izq + ((t - tMin) / (tMax - tMin || 1)) * (W - izq - der);
  const y = (c) => arriba + (1 - c / cMax) * (H - abajo - arriba);
  let s = `<svg viewBox="0 0 ${W} ${H}" class="grafico-svg" role="img" aria-label="Temperatura de la noche y cubiertos">`;
  for (let i = 0; i <= 4; i++) {
    const v = (cMax / 4) * i;
    s += `<line x1="${izq}" x2="${W - der}" y1="${y(v)}" y2="${y(v)}" class="eje-linea"/>` +
         `<text x="${izq - 6}" y="${y(v) + 4}" text-anchor="end" class="eje-texto">${Math.round(v)}</text>`;
  }
  for (let t = tMin; t <= tMax; t += 2) {
    s += `<text x="${x(t)}" y="${H - abajo + 16}" text-anchor="middle" class="eje-texto">${t}°</text>`;
  }
  s += `<text x="${(W + izq) / 2}" y="${H - 6}" text-anchor="middle" class="eje-texto">temperatura de la noche (19 a 23 h)</text>`;
  puntos.forEach((p) => {
    const finde = FIN_DE_SEMANA.includes(p.dia_semana);
    const llueve = p.cat === "lluvia";
    s += `<circle cx="${x(Number(p.temp_noche))}" cy="${y(p.cubiertos)}" r="5" class="${finde ? "punto-finde" : "punto-semana"}${llueve ? " punto-lluvia" : ""}">` +
         `<title>${formatearFecha(p.fecha)}: ${p.cubiertos} cubiertos, ${Math.round(p.temp_noche)} °C${llueve ? ", lluvia" : ""}</title></circle>`;
  });
  return s + "</svg>";
}

// ---------- Pintar la pestaña ----------
async function cargarClimaPersonal() {
  const estado = document.getElementById("clima-estado");
  estado.textContent = "Trayendo el clima y las reservas…";
  try {
    await asegurarDatos();
  } catch (e) {
    estado.textContent = "";
    avisoAdmin("error", "Falta instalar sql-11-correos-y-clima.sql en Supabase. " + mensajeDeError(e));
    return;
  }
  const a = analizar();
  estado.textContent = `Clima de Open-Meteo · ${a.noches} noches con reservas en los últimos 90 días.`;
  pintarPrevision();
  pintarAnalisis(a);
  pintarNochesPasadas(a);
  document.getElementById("aj-cubiertos-mozo").value = ajustesPersonal.cubiertos_por_mozo;
  document.getElementById("aj-mozos-min").value = ajustesPersonal.mozos_minimos;
}

function pintarPrevision() {
  const hoy = hoyISO();
  const proximas = historiaNoches.filter((n) => n.fecha >= hoy).slice(0, 7);
  document.getElementById("tabla-prevision").innerHTML = proximas.map((n) => {
    const p = prever(n);
    return `
      <tr>
        <td><div class="celda-principal">${n.fecha === hoy ? "Hoy" : soloDia(n.fecha)}</div>
            <div class="celda-secundaria">${diaYMes(n.fecha)}</div></td>
        <td>${textoClima(n)}</td>
        <td>${n.reservados}<div class="celda-secundaria">${n.reservas} reservas</div></td>
        <td><b>${p.esperados || "–"}</b><div class="celda-secundaria">${esc(p.criterio)}</div></td>
        <td><span class="mozos-sugeridos">${p.mozos || "–"}</span></td>
        <td><input class="form-control form-control-sm campo-mozos" type="number" min="0" max="60"
                   value="${n.mozos ?? ""}" placeholder="${p.mozos || ""}" data-fecha="${n.fecha}" aria-label="Mozos asignados el ${n.fecha}"></td>
      </tr>`;
  }).join("") || `<tr><td colspan="6" class="text-center texto-suave py-3">Sin pronóstico disponible.</td></tr>`;
}

function pintarAnalisis(a) {
  const k = [];
  if (a.r != null && a.pendiente != null) {
    const pct = Math.round(a.pendiente * 5 * 100);
    k.push(`<div><span class="indicador-cifra">${pct > 0 ? "+" : ""}${pct} %</span>
      <span class="indicador-nombre">cubiertos cada 5 °C más</span>
      <span class="celda-secundaria">relación ${fuerza(a.r)} (r = ${a.r.toFixed(2).replace(".", ",")})</span></div>`);
  }
  if (a.efectoLluvia != null) {
    const pct = Math.round(a.efectoLluvia * 100);
    k.push(`<div><span class="indicador-cifra">${pct > 0 ? "+" : ""}${pct} %</span>
      <span class="indicador-nombre">cubiertos cuando llueve</span>
      <span class="celda-secundaria">contra noches secas del mismo día</span></div>`);
  }
  if (a.cubPorMozo != null) {
    k.push(`<div><span class="indicador-cifra">${Math.round(a.cubPorMozo)}</span>
      <span class="indicador-nombre">cubiertos por mozo</span>
      <span class="celda-secundaria">promedio real · regla actual: ${ajustesPersonal.cubiertos_por_mozo}</span></div>`);
  }
  document.getElementById("indicadores-clima").innerHTML = k.join("") ||
    '<p class="pagina-bajada mb-0">Hacen falta al menos 5 noches con reservas y clima para calcular la relación.</p>';
  document.getElementById("grafico-clima-barras").innerHTML = a.noches ? graficoBarras(a.barras) : "";
  document.getElementById("grafico-clima-puntos").innerHTML = graficoPuntos(a.puntos);
  document.getElementById("conclusion-clima").textContent = conclusion(a);
}

function conclusion(a) {
  if (!a.noches) return "Cuando haya noches con reservas, acá vas a ver cómo influye el clima.";
  const partes = [];
  const b = Object.fromEntries(a.barras.map((x) => [x.cat, x]));
  if (b.calida.finde && b.lluvia.finde) {
    partes.push(`Un viernes o sábado cálido trae en promedio ${b.calida.finde} cubiertos; con lluvia, ${b.lluvia.finde}.`);
  }
  if (a.efectoLluvia != null && a.efectoLluvia < -0.1) {
    partes.push(`La lluvia baja la gente un ${Math.abs(Math.round(a.efectoLluvia * 100))} %: conviene poner menos mozos y confirmar reservas por si cancelan.`);
  }
  if (a.r != null && a.r > 0.3) partes.push("Con calor viene más gente: reforzá el equipo y el ventanal.");
  return partes.join(" ");
}

function pintarNochesPasadas() {
  const hoy = hoyISO();
  const cpm = ajustesPersonal.cubiertos_por_mozo;
  const lista = historiaNoches.filter((n) => n.fecha < hoy && (n.cubiertos > 0 || n.mozos)).slice(-14).reverse();
  document.getElementById("tabla-noches").innerHTML = lista.map((n) => {
    const ratio = n.mozos ? n.cubiertos / n.mozos : null;
    const nota = ratio == null ? "" : ratio > cpm * 1.2 ? '<span class="nota-mozos falta">faltaron mozos</span>'
      : ratio < cpm * 0.6 ? '<span class="nota-mozos sobra">sobraron mozos</span>' : '<span class="nota-mozos bien">bien</span>';
    return `
      <tr>
        <td><div class="celda-principal">${soloDia(n.fecha)}</div>
            <div class="celda-secundaria">${diaYMes(n.fecha)}</div></td>
        <td>${textoClima(n)}</td>
        <td>${n.cubiertos}<div class="celda-secundaria">${n.reservas} reservas${n.no_vinieron ? ` · ${n.no_vinieron} no vinieron` : ""}</div></td>
        <td><input class="form-control form-control-sm campo-mozos" type="number" min="0" max="60"
                   value="${n.mozos ?? ""}" data-fecha="${n.fecha}" aria-label="Mozos el ${n.fecha}"></td>
        <td>${ratio ? Math.round(ratio) : "–"} ${nota}</td>
      </tr>`;
  }).join("") || `<tr><td colspan="5" class="text-center texto-suave py-3">Todavía no hay noches con reservas.</td></tr>`;
}

// Guardar mozos (en la tabla de previsión o en la de noches anteriores)
document.getElementById("sec-clima").addEventListener("change", async (e) => {
  const campo = e.target.closest(".campo-mozos");
  if (!campo) return;
  const fecha = campo.dataset.fecha;
  const valor = campo.value === "" ? null : Number(campo.value);
  const { error } = valor == null
    ? await db.from("personal_dia").delete().eq("fecha", fecha)
    : await db.from("personal_dia").upsert({ fecha, mozos: valor });
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }
  campo.classList.add("guardado");
  setTimeout(() => campo.classList.remove("guardado"), 1200);
  const n = historiaNoches.find((x) => x.fecha === fecha);
  if (n) n.mozos = valor;
  if (fecha < hoyISO()) { const a = analizar(); pintarAnalisis(a); pintarNochesPasadas(a); }
});

document.getElementById("form-ajustes-personal").addEventListener("submit", async (e) => {
  e.preventDefault();
  const cambios = {
    cubiertos_por_mozo: Number(document.getElementById("aj-cubiertos-mozo").value),
    mozos_minimos: Number(document.getElementById("aj-mozos-min").value),
  };
  const { error } = await db.from("ajustes_personal").update(cambios).eq("id", 1);
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }
  ajustesPersonal = { ...ajustesPersonal, ...cambios };
  avisoAdmin("ok", "Regla de personal guardada. Las sugerencias se recalcularon.");
  pintarPrevision();
  const a = analizar(); pintarAnalisis(a); pintarNochesPasadas(a);
});

document.getElementById("btn-recargar-clima").addEventListener("click", () => {
  climaGuardadoHoy = false;
  cargarClimaPersonal();
});

// ---------- Dashboard: personal sugerido para el día elegido ----------
async function pintarPersonalNoche(fecha) {
  const caja = document.getElementById("personal-noche");
  if (!caja) return;
  try {
    if (!historiaNoches.length) await asegurarDatos();
  } catch (e) { caja.classList.add("oculto"); return; }
  const n = historiaNoches.find((x) => x.fecha === fecha);
  if (!n || fecha < hoyISO()) {
    if (n && n.mozos) {
      caja.classList.remove("oculto");
      caja.innerHTML = `👥 Esa noche trabajaron <b>${n.mozos} mozos</b> para ${n.cubiertos} cubiertos.`;
    } else caja.classList.add("oculto");
    return;
  }
  const p = prever(n);
  if (!p.esperados) { caja.classList.add("oculto"); return; }
  caja.classList.remove("oculto");
  caja.innerHTML = `👥 <b>Personal sugerido: ${p.mozos} mozos</b> · se esperan unos ${p.esperados} cubiertos ` +
    `(${esc(p.criterio)})${n.mozos ? ` · asignados: ${n.mozos}` : ""}. ` +
    `<button type="button" class="btn-enlace" data-ir-clima>Ver Clima y personal</button>`;
}
document.getElementById("personal-noche").addEventListener("click", (e) => {
  if (e.target.closest("[data-ir-clima]")) document.querySelector('[data-seccion="clima"]').click();
});

// ---------- Dashboard: invitar a sumarse a los correos ----------
async function pintarInvitarHoy(fecha) {
  const caja = document.getElementById("invitar-hoy");
  if (!caja) return;
  const [lista, regalo] = await Promise.all([db.rpc("invitar_a_sumarse", { p_fecha: fecha }), textoBienvenida()]);
  if (lista.error || !lista.data.length) { caja.classList.add("oculto"); return; }
  caja.classList.remove("oculto");
  caja.innerHTML = `
    <div class="d-flex justify-content-between align-items-baseline flex-wrap gap-2">
      <h2 class="grupo-titulo my-0">✉ Invitá a sumarse a los beneficios</h2>
      <span class="celda-secundaria">${lista.data.length} ${lista.data.length === 1 ? "reserva" : "reservas"} de clientes sin correos</span>
    </div>
    <p class="pagina-bajada mb-2">Cuando lleguen, contales que si aceptan correos reciben <b>${esc(regalo.toLowerCase())}</b>,
      promociones exclusivas y las novedades de la semana. Lo activan en un toque desde “Mi perfil”.</p>
    <ul class="lista-invitar">${lista.data.map((r) => `
      <li><b>${formatearHora(r.hora)}</b> · ${esc(r.nombre || "Cliente")} · mesa ${r.mesa} · ${r.personas} pers.
        <span class="celda-secundaria">${r.visitas ? `${r.visitas} ${r.visitas === 1 ? "visita" : "visitas"}` : "primera vez"}</span></li>`).join("")}
    </ul>`;
}
