// =========================================================
// Panel admin: Fidelización (PARTE B)
// Datos almacenados → segmentación → Make → acciones de fidelización
// + IA (Claude) que sugiere promociones según el público elegido
// Las reglas y los cupones viven en la base (sql-9): acá solo se muestran.
// =========================================================

const SEGMENTOS = {
  vip:       { nombre: "VIP",        icono: "★", texto: "Los que más vienen: muchas visitas en el año." },
  frecuente: { nombre: "Frecuentes", icono: "↻", texto: "Vuelven seguido: varias visitas en el año." },
  nuevo:     { nombre: "Nuevos",     icono: "✦", texto: "Recién llegan: todavía pocas visitas." },
  en_riesgo: { nombre: "En riesgo",  icono: "!", texto: "Hace un tiempo que no vienen." },
  inactivo:  { nombre: "Inactivos",  icono: "–", texto: "Hace mucho que no vienen." },
};
const DIAS_SEMANA = ["", "lunes", "martes", "miércoles", "jueves", "viernes", "sábados", "domingos"];
const NOMBRES_TIPO_BENEFICIO = { cumpleanos: "Cumpleaños", reactivacion: "Reactivación", visitas: "Tarjeta de visitas", campana: "Promoción", bienvenida: "Bienvenida" };
// Grupo aparte de los segmentos: clientes que no aceptaron correos
const SIN_CORREOS = { nombre: "Sin correos", icono: "✉", texto: "No aceptaron recibir correos: invitalos en el local." };

let clientesFide = [];
let segmentoElegido = "";
let reglasFide = null;

function textoSegmento(s) {
  return `<span class="segmento segmento-${s}">${SEGMENTOS[s]?.nombre.replace(/s$/, "") || s}</span>`;
}

function haceDias(n) {
  if (n == null) return "–";
  if (n === 0) return "hoy";
  if (n === 1) return "ayer";
  if (n < 60) return `hace ${n} días`;
  return `hace ${Math.round(n / 30)} meses`;
}

async function cargarFidelizacion() {
  const [clientes, reglas, campanas, beneficios] = await Promise.all([
    db.rpc("clientes_fidelizacion"),
    db.from("ajustes_fidelizacion").select("*").eq("id", 1).single(),
    db.from("campana").select("*").order("creada_en", { ascending: false }).limit(8),
    db.from("beneficio").select("id_beneficio, codigo, tipo, descripcion, vence_en, usado_en, correo_enviado, id_campana, creado_en, usuario:usuario!beneficio_id_usuario_fkey(nombre, email)")
      .order("creado_en", { ascending: false }).limit(200),
  ]);
  if (clientes.error) {
    avisoAdmin("error", "Falta instalar la Parte B en Supabase (sql-9-fidelizacion.sql). " + mensajeDeError(clientes.error));
    return;
  }
  clientesFide = clientes.data;
  reglasFide = reglas.data;
  pintarSegmentos();
  pintarTablaFide();
  pintarReglas(beneficios.data || []);
  pintarCampanas(campanas.data || [], beneficios.data || []);
  pintarBeneficios(beneficios.data || []);
  actualizarAlcance();
}

// ---------- Segmentos ----------
function pintarSegmentos() {
  const total = clientesFide.length || 1;
  const tarjetas = Object.entries(SEGMENTOS).map(([clave, s]) => {
    const n = clientesFide.filter((c) => c.segmento === clave).length;
    return `
      <button type="button" class="tarjeta-segmento segmento-borde-${clave} ${segmentoElegido === clave ? "activa" : ""}" data-segmento="${clave}">
        <span class="segmento-icono segmento-${clave}" aria-hidden="true">${s.icono}</span>
        <span class="segmento-cifra">${n}</span>
        <span class="segmento-nombre">${s.nombre}</span>
        <span class="segmento-pct">${Math.round((n * 100) / total)} % de los clientes</span>
        <span class="segmento-texto">${s.texto}</span>
      </button>`;
  });
  const sin = clientesFide.filter((c) => !c.acepta_promociones).length;
  tarjetas.push(`
      <button type="button" class="tarjeta-segmento segmento-borde-sin_correos ${segmentoElegido === "sin_correos" ? "activa" : ""}" data-segmento="sin_correos">
        <span class="segmento-icono segmento-sin_correos" aria-hidden="true">${SIN_CORREOS.icono}</span>
        <span class="segmento-cifra">${sin}</span>
        <span class="segmento-nombre">${SIN_CORREOS.nombre}</span>
        <span class="segmento-pct">${Math.round((sin * 100) / total)} % de los clientes</span>
        <span class="segmento-texto">${SIN_CORREOS.texto}</span>
      </button>`);
  document.getElementById("tarjetas-segmentos").innerHTML = tarjetas.join("");
}

document.getElementById("tarjetas-segmentos").addEventListener("click", (e) => {
  const boton = e.target.closest("[data-segmento]");
  if (!boton) return;
  segmentoElegido = segmentoElegido === boton.dataset.segmento ? "" : boton.dataset.segmento;
  pintarSegmentos();
  pintarTablaFide();
});

function preferenciasDe(c) {
  const partes = [];
  if (c.zona_favorita) partes.push(c.zona_favorita);
  if (c.dia_favorito) partes.push(`los ${DIAS_SEMANA[c.dia_favorito]}`);
  if (c.horario_favorito) partes.push(c.horario_favorito === "temprano" ? "temprano" : "más tarde");
  if (c.grupo_habitual) partes.push(c.grupo_habitual <= 2 ? "en pareja" : `grupos de ${c.grupo_habitual}`);
  const ocasiones = (c.ocasiones || []).map((o) => NOMBRES_OCASION[o] || o).join(" ");
  return `${partes.length ? esc(partes.join(" · ")) : '<span class="texto-suave">Sin datos aún</span>'}
          ${ocasiones ? `<div class="celda-secundaria">${esc(ocasiones)}</div>` : ""}`;
}

function cumpleDe(c) {
  if (!c.proximo_cumple) return '<span class="texto-suave">–</span>';
  const [, m, d] = c.proximo_cumple.split("-");
  const pronto = c.dias_para_cumple <= 30;
  return `<span class="${pronto ? "cumple-pronto" : ""}">${d}/${m}</span>
          ${pronto ? `<div class="celda-secundaria">${c.dias_para_cumple === 0 ? "¡hoy!" : `en ${c.dias_para_cumple} días`}</div>` : ""}`;
}

// Tarjeta de visitas: ●●●○○ (cada N visitas, un regalo)
function sellosDe(visitas) {
  const meta = reglasFide ? reglasFide.visitas_meta : 5;
  const sellos = visitas % meta;
  const puntos = Array.from({ length: meta }, (_, i) =>
    `<span class="sello-chico ${i < sellos ? "lleno" : ""}"></span>`).join("");
  return `<span class="sellos-fila" title="${sellos} de ${meta} sellos">${puntos}</span>
          <div class="celda-secundaria">${sellos} de ${meta}${visitas >= meta ? ` · ${Math.floor(visitas / meta)} ${Math.floor(visitas / meta) === 1 ? "premio" : "premios"}` : ""}</div>`;
}

function pintarTablaFide() {
  const texto = document.getElementById("buscar-fide").value.trim().toLowerCase();
  const lista = clientesFide
    .filter((c) => !segmentoElegido || (segmentoElegido === "sin_correos" ? !c.acepta_promociones : c.segmento === segmentoElegido))
    .filter((c) => !texto || [c.nombre, c.email].some((v) => (v || "").toLowerCase().includes(texto)))
    .sort((a, b) => b.visitas_12m - a.visitas_12m || b.visitas - a.visitas);

  const s = segmentoElegido === "sin_correos" ? SIN_CORREOS : SEGMENTOS[segmentoElegido];
  document.getElementById("titulo-lista-segmento").textContent = s ? s.nombre : "Todos los clientes";
  document.getElementById("bajada-lista-segmento").textContent = segmentoElegido === "sin_correos"
    ? `No reciben promociones ni avisos. Cuando reservan te avisamos para que el equipo los invite en el local: si se suman, reciben ${reglasFide ? reglasFide.beneficio_bienvenida.toLowerCase() : "un regalo de bienvenida"}. Tocá de nuevo para ver a todos.`
    : s ? `${s.texto} Tocá de nuevo el segmento para ver a todos.` : "Tocá un segmento para filtrar.";

  const cuerpo = document.getElementById("tabla-fide");
  if (!lista.length) {
    cuerpo.innerHTML = `<tr><td colspan="7" class="text-center py-4 texto-suave">No hay clientes en este grupo.</td></tr>`;
    return;
  }
  cuerpo.innerHTML = lista.map((c) => `
    <tr>
      <td>
        <div class="celda-principal">${esc(c.nombre || "Sin nombre")}</div>
        <div class="celda-secundaria">${esc(c.email)}${c.acepta_promociones ? "" : " · sin correos"}</div>
      </td>
      <td>${textoSegmento(c.segmento)}</td>
      <td>${c.visitas}<div class="celda-secundaria">${c.visitas_12m} en el año${c.no_asistio ? ` · ${c.no_asistio} sin venir` : ""}</div></td>
      <td class="celda-fecha">${sellosDe(c.visitas)}</td>
      <td class="celda-fecha">${haceDias(c.dias_sin_venir)}${c.proxima_reserva ? `<div class="celda-secundaria">vuelve el ${formatearFecha(c.proxima_reserva).replace(/^\w+,\s*/, "")}</div>` : ""}</td>
      <td class="celda-notas">${preferenciasDe(c)}</td>
      <td>${cumpleDe(c)}</td>
    </tr>`).join("");
}
document.getElementById("buscar-fide").addEventListener("input", pintarTablaFide);
document.getElementById("btn-recargar-fide").addEventListener("click", cargarFidelizacion);

// ---------- Acciones automáticas ----------
function pintarReglas(beneficios) {
  const r = reglasFide;
  if (!r) return;
  document.getElementById("reglas-resumen").innerHTML = `
    <div class="regla"><span class="regla-icono">🎂</span><div><b>Cumpleaños</b> · ${r.dias_aviso_cumple} días antes<div class="celda-secundaria">${esc(r.beneficio_cumple)}</div></div></div>
    <div class="regla"><span class="regla-icono">🌊</span><div><b>Reactivación</b> · a los ${r.dias_en_riesgo} días sin venir<div class="celda-secundaria">${esc(r.beneficio_reactivacion)}</div></div></div>
    <div class="regla"><span class="regla-icono">🍷</span><div><b>Tarjeta de visitas</b> · cada ${r.visitas_meta} visitas<div class="celda-secundaria">${esc(r.beneficio_visitas)}</div></div></div>
    ${r.beneficio_bienvenida ? `<div class="regla"><span class="regla-icono">🥂</span><div><b>Bienvenida</b> · al aceptar correos${r.aviso_sin_correos ? " · te avisamos si reserva alguien sin correos" : ""}<div class="celda-secundaria">${esc(r.beneficio_bienvenida)}</div></div></div>` : ""}
    ${r.automatico ? "" : '<div class="aviso aviso-info mt-2">Las acciones automáticas están apagadas. Solo se ejecutan con el botón.</div>'}`;

  const hoy = hoyISO();
  const hace30 = new Date(Date.now() - 30 * 86400000);
  const vigentes = beneficios.filter((b) => !b.usado_en && b.vence_en >= hoy).length;
  const creados30 = beneficios.filter((b) => new Date(b.creado_en) >= hace30);
  const usados30 = creados30.filter((b) => b.usado_en).length;
  const tasa = creados30.length ? Math.round((usados30 * 100) / creados30.length) : 0;
  document.getElementById("indicadores-cupon").innerHTML = `
    <div><span class="indicador-cifra">${vigentes}</span><span class="indicador-nombre">cupones vigentes</span></div>
    <div><span class="indicador-cifra">${creados30.length}</span><span class="indicador-nombre">entregados en 30 días</span></div>
    <div><span class="indicador-cifra">${tasa} %</span><span class="indicador-nombre">se usaron</span></div>`;

  const ultima = document.getElementById("ultima-ejecucion");
  if (r.ultima_ejecucion) {
    const res = r.ultimo_resumen || {};
    ultima.textContent = `Última revisión: ${fechaHora(r.ultima_ejecucion)} · ` +
      `${res.cumpleanos || 0} cumpleaños, ${res.reactivacion || 0} reactivaciones, ${res.visitas || 0} tarjetas completas.`;
  } else {
    ultima.textContent = "Todavía no se ejecutó ninguna vez.";
  }
}

document.getElementById("btn-ejecutar-fide").addEventListener("click", async (e) => {
  e.target.disabled = true;
  const { data, error } = await db.rpc("ejecutar_fidelizacion");
  e.target.disabled = false;
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }
  const total = (data.cumpleanos || 0) + (data.reactivacion || 0) + (data.visitas || 0);
  avisoAdmin("ok", total
    ? `Listo: se entregaron ${total} beneficios (${data.cumpleanos} de cumpleaños, ${data.reactivacion} de reactivación y ${data.visitas} por tarjeta de visitas).`
    : "Listo: hoy no había beneficios nuevos para entregar.");
  cargarFidelizacion();
});

// ---------- Editar reglas ----------
const CAMPOS_REGLAS = {
  "regla-frecuente": "visitas_frecuente", "regla-vip-visitas": "visitas_vip",
  "regla-riesgo": "dias_en_riesgo", "regla-inactivo": "dias_inactivo", "regla-ben-cumple": "beneficio_cumple",
  "regla-aviso-cumple": "dias_aviso_cumple", "regla-vigencia": "vigencia_dias",
  "regla-ben-react": "beneficio_reactivacion", "regla-ben-visitas": "beneficio_visitas", "regla-meta": "visitas_meta",
  "regla-ben-bienvenida": "beneficio_bienvenida",
};
const formReglas = document.getElementById("form-reglas");

document.getElementById("btn-editar-reglas").addEventListener("click", () => {
  if (!reglasFide) return;
  Object.entries(CAMPOS_REGLAS).forEach(([id, col]) => { document.getElementById(id).value = reglasFide[col]; });
  document.getElementById("regla-automatico").checked = reglasFide.automatico;
  document.getElementById("regla-aviso-sin-correos").checked = reglasFide.aviso_sin_correos !== false;
  formReglas.classList.remove("oculto");
  formReglas.scrollIntoView({ behavior: "smooth", block: "start" });
});
document.getElementById("btn-cerrar-reglas").addEventListener("click", () => formReglas.classList.add("oculto"));

formReglas.addEventListener("submit", async (e) => {
  e.preventDefault();
  const cambios = {
    automatico: document.getElementById("regla-automatico").checked,
    aviso_sin_correos: document.getElementById("regla-aviso-sin-correos").checked,
  };
  Object.entries(CAMPOS_REGLAS).forEach(([id, col]) => {
    const campo = document.getElementById(id);
    cambios[col] = campo.type === "number" ? Number(campo.value) : campo.value.trim();
  });
  if (cambios.dias_en_riesgo >= cambios.dias_inactivo) {
    avisoAdmin("error", "Los días para 'En riesgo' tienen que ser menos que los de 'Inactivo'."); return;
  }
  if (cambios.visitas_frecuente >= cambios.visitas_vip) {
    avisoAdmin("error", "Las visitas para 'Frecuente' tienen que ser menos que las de 'VIP'."); return;
  }
  const { error } = await db.from("ajustes_fidelizacion").update(cambios).eq("id", 1);
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }
  avisoAdmin("ok", "Reglas guardadas. Los segmentos se recalcularon.");
  formReglas.classList.add("oculto");
  cargarFidelizacion();
});

// ---------- Canjear cupón ----------
const cajaCupon = document.getElementById("resultado-cupon");

function pintarCupon(c) {
  const estados = { vigente: "estado-confirmada", usado: "estado-completada", vencido: "estado-no_asistio" };
  cajaCupon.classList.remove("oculto");
  cajaCupon.innerHTML = `
    <div class="d-flex justify-content-between align-items-start gap-2">
      <div>
        <div class="celda-principal">${esc(c.descripcion)}</div>
        <div class="celda-secundaria">${esc(c.cliente || "")} · ${esc(c.email || "")}</div>
        <div class="celda-secundaria">${NOMBRES_TIPO_BENEFICIO[c.tipo] || ""} · vence ${formatearFecha(c.vence).replace(/^\w+,\s*/, "")}</div>
      </div>
      <span class="estado ${estados[c.estado]}">${c.estado[0].toUpperCase() + c.estado.slice(1)}</span>
    </div>
    ${c.estado === "vigente" ? `<button type="button" class="btn-marea ancho mt-3" data-canjear="${esc(c.codigo)}">Marcar como usado</button>` : ""}`;
}

document.getElementById("form-cupon").addEventListener("submit", async (e) => {
  e.preventDefault();
  const { data, error } = await db.rpc("consultar_beneficio", { p_codigo: document.getElementById("cupon-codigo").value });
  if (error) {
    cajaCupon.classList.remove("oculto");
    cajaCupon.innerHTML = `<div class="aviso aviso-error mt-0">${esc(mensajeDeError(error))}</div>`;
    return;
  }
  pintarCupon(data);
});

cajaCupon.addEventListener("click", async (e) => {
  const boton = e.target.closest("[data-canjear]");
  if (!boton) return;
  boton.disabled = true;
  const { data, error } = await db.rpc("canjear_beneficio", { p_codigo: boton.dataset.canjear });
  if (error) { boton.disabled = false; avisoAdmin("error", mensajeDeError(error)); return; }
  pintarCupon(data);
  avisoAdmin("ok", `Cupón ${data.codigo} canjeado: ${data.descripcion}.`);
  document.getElementById("cupon-codigo").value = "";
  cargarFidelizacion();
});

// ---------- Promociones (campañas) ----------
function valoresCampana() {
  return {
    segmento: document.getElementById("camp-segmento").value,
    zona: document.getElementById("camp-zona").value,
    grupo: document.getElementById("camp-grupo").value,
  };
}

async function actualizarAlcance() {
  const v = valoresCampana();
  const caja = document.getElementById("camp-alcance");
  const { data, error } = await db.rpc("vista_previa_campana", { p_segmento: v.segmento, p_zona: v.zona, p_grupo: v.grupo });
  if (error) { caja.textContent = ""; return; }
  caja.innerHTML = data.destinatarios
    ? `Llega a <b>${data.destinatarios}</b> ${data.destinatarios === 1 ? "cliente" : "clientes"} (los que aceptaron recibir correos).`
    : "Ningún cliente con correos activados coincide con estos filtros.";
  caja.dataset.destinatarios = data.destinatarios;
  pintarDestinatarios(v);
}

// Lista de quiénes reciben la promoción (mismas reglas que la base de datos)
function coincideConPublico(c, v) {
  return (!v.segmento || c.segmento === v.segmento)
    && (!v.zona || c.zona_favorita === v.zona)
    && (!v.grupo || (v.grupo === "pareja" ? c.grupo_habitual <= 2 : c.grupo_habitual >= 4));
}

function pintarDestinatarios(v) {
  // Solo los que van a recibir el correo
  const lista = clientesFide.filter((c) => c.acepta_promociones && coincideConPublico(c, v))
    .sort((a, b) => (a.nombre || "").localeCompare(b.nombre || ""));
  const caja = document.getElementById("camp-lista");
  document.getElementById("camp-destinatarios").classList.toggle("oculto", !lista.length);
  caja.innerHTML = lista.map((c) => `
    <li>
      <span class="celda-principal">${esc(c.nombre || "Sin nombre")}</span>
      <span class="celda-secundaria">${esc(c.email)}</span>
      <span class="recibe">✓ recibe el correo</span>
    </li>`).join("");
}
["camp-segmento", "camp-zona", "camp-grupo"].forEach((id) =>
  document.getElementById(id).addEventListener("change", actualizarAlcance));

document.getElementById("form-campana").addEventListener("submit", async (e) => {
  e.preventDefault();
  const n = Number(document.getElementById("camp-alcance").dataset.destinatarios || 0);
  if (!n) { avisoAdmin("error", "La promoción no le llega a nadie. Cambiá los filtros."); return; }
  if (!confirm(`¿Enviar esta promoción a ${n} ${n === 1 ? "cliente" : "clientes"}? No se puede deshacer.`)) return;
  const boton = e.target.querySelector("button[type=submit]");
  boton.disabled = true;
  const v = valoresCampana();
  const { data, error } = await db.rpc("lanzar_campana", {
    p_nombre: document.getElementById("camp-nombre").value,
    p_segmento: v.segmento, p_zona: v.zona, p_grupo: v.grupo,
    p_asunto: document.getElementById("camp-asunto").value,
    p_mensaje: document.getElementById("camp-mensaje").value,
    p_beneficio: document.getElementById("camp-beneficio").value,
    p_vigencia_dias: Number(document.getElementById("camp-vigencia").value),
  });
  boton.disabled = false;
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }
  avisoAdmin("ok", `Promoción "${data.nombre}" enviada a ${data.destinatarios} ${data.destinatarios === 1 ? "cliente" : "clientes"}.`);
  e.target.reset();
  cargarFidelizacion();
});

// ---------- IA: sugerir la promoción ----------
document.getElementById("btn-ia").addEventListener("click", async (e) => {
  const boton = e.target;
  const porque = document.getElementById("camp-porque");
  boton.disabled = true;
  boton.textContent = "Pensando…";
  porque.classList.add("oculto");
  const v = valoresCampana();
  const { data, error } = await db.functions.invoke("sugerir-promocion", {
    body: { ...v, idea: document.getElementById("camp-idea").value.trim() },
  });
  boton.disabled = false;
  boton.textContent = "Sugerir otra";
  let problema = data && data.error;
  if (error && !problema) {
    // Si la función respondió con error, el detalle viene en el cuerpo
    try { problema = (await error.context.json()).error; } catch (err) { problema = null; }
    problema = problema || "No se pudo contactar a la IA. ¿Está publicada la función sugerir-promocion?";
  }
  if (problema) { avisoAdmin("error", problema); return; }

  document.getElementById("camp-nombre").value = data.nombre;
  document.getElementById("camp-asunto").value = data.asunto;
  document.getElementById("camp-mensaje").value = data.mensaje;
  document.getElementById("camp-beneficio").value = data.beneficio;
  porque.textContent = `💡 ${data.por_que} Revisá el texto y cambiá lo que quieras antes de enviar.`;
  porque.classList.remove("oculto");
});

function pintarCampanas(campanas, beneficios) {
  const caja = document.getElementById("lista-campanas");
  if (!campanas.length) {
    caja.innerHTML = '<p class="pagina-bajada mb-0">Todavía no se envió ninguna promoción.</p>';
    return;
  }
  caja.innerHTML = campanas.map((k) => {
    const cupones = beneficios.filter((b) => b.id_campana === k.id_campana);
    const usados = cupones.filter((b) => b.usado_en).length;
    const publico = [k.segmento ? SEGMENTOS[k.segmento]?.nombre : "Todos", k.zona, k.grupo === "pareja" ? "parejas" : k.grupo === "grupo" ? "grupos" : null]
      .filter(Boolean).join(" · ");
    return `
      <div class="fila-equipo">
        <div class="flex-grow-1">
          <div class="celda-principal">${esc(k.nombre)}</div>
          <div class="celda-secundaria">${fechaHora(k.creada_en)} · ${esc(publico)}${k.beneficio ? ` · ${esc(k.beneficio)}` : ""}</div>
        </div>
        <div class="text-end">
          <div class="celda-principal">${k.destinatarios} enviados</div>
          ${k.beneficio ? `<div class="celda-secundaria">${usados} canjeados</div>` : ""}
        </div>
      </div>`;
  }).join("");
}

function pintarBeneficios(beneficios) {
  const cuerpo = document.getElementById("tabla-beneficios");
  const lista = beneficios.slice(0, 8);
  if (!lista.length) {
    cuerpo.innerHTML = `<tr><td colspan="4" class="text-center py-3 texto-suave">Todavía no hay beneficios.</td></tr>`;
    return;
  }
  const hoy = hoyISO();
  cuerpo.innerHTML = lista.map((b) => {
    const e = b.usado_en ? ["Usado", "estado-completada"] : b.vence_en < hoy ? ["Vencido", "estado-no_asistio"] : ["Vigente", "estado-confirmada"];
    return `
      <tr>
        <td><div class="celda-principal">${esc(b.usuario?.nombre || "–")}</div>
            <div class="celda-secundaria">${b.correo_enviado ? "correo enviado" : "sin correo"}</div></td>
        <td>${NOMBRES_TIPO_BENEFICIO[b.tipo]}<div class="celda-secundaria">${esc(b.descripcion)}</div></td>
        <td class="celda-codigo">${esc(b.codigo)}</td>
        <td><span class="estado ${e[1]}">${e[0]}</span></td>
      </tr>`;
  }).join("");
}
