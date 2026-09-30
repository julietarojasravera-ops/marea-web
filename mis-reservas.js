// =========================================================
// Mis reservas: ver próximas y pasadas, cancelar
// =========================================================

let idUsuario = null;

function esProxima(r) {
  const ahora = new Date();
  const [a, m, d] = r.fecha.split("-").map(Number);
  const [hh, mm] = r.hora.split(":").map(Number);
  return new Date(a, m - 1, d, hh, mm) >= ahora;
}

function tarjetaReserva(r, proxima) {
  const personas = `${r.cantidad_personas} ${r.cantidad_personas === 1 ? "persona" : "personas"}`;
  const puedeCancelar = proxima && r.estado === "confirmada";
  return `
    <div class="reserva-item ${proxima ? "" : "pasada"}">
      <div>
        <div class="reserva-fecha">${formatearFecha(r.fecha)} · ${formatearHora(r.hora)} a ${sumarMinutos(formatearHora(r.hora), r.duracion_min)}</div>
        <div class="reserva-detalle">${personas}${r.mesa ? ` · Mesa ${r.mesa.numero}${r.mesa.zona ? ` (${r.mesa.zona.toLowerCase()})` : ""}` : ""} · Reserva n.º ${r.id_reserva}</div>
        ${r.ocasion ? `<div class="reserva-ocasion">${NOMBRES_OCASION[r.ocasion] || r.ocasion}</div>` : ""}
      </div>
      <div class="reserva-acciones">
        <span class="estado estado-${r.estado}">${NOMBRES_ESTADO[r.estado] || r.estado}</span>
        ${puedeCancelar
          ? `<button type="button" class="btn-borde btn-peligro" data-cancelar="${r.id_reserva}">Cancelar</button>`
          : ""}
      </div>
    </div>`;
}

function pintarGrupo(idCaja, lista, proxima, textoVacio) {
  const caja = document.getElementById(idCaja);
  caja.innerHTML = lista.length
    ? lista.map((r) => tarjetaReserva(r, proxima)).join("")
    : `<div class="vacio">${textoVacio}</div>`;
}

async function cargarReservas() {
  const { data, error } = await db
    .from("reserva")
    .select("id_reserva, fecha, hora, cantidad_personas, estado, duracion_min, ocasion, mesa(numero, zona)")
    .eq("id_usuario", idUsuario)
    .order("fecha", { ascending: true })
    .order("hora", { ascending: true });

  if (error) {
    mostrarAviso("aviso-mis", "error", mensajeDeError(error));
    return;
  }

  const proximas = data.filter(esProxima);
  const pasadas = data.filter((r) => !esProxima(r)).reverse();
  pintarGrupo("lista-proximas", proximas, true,
    'No tenés reservas próximas. <a href="reservar.html">Reservá una mesa</a>.');
  pintarGrupo("lista-pasadas", pasadas, false, "Todavía no tenés reservas pasadas.");
}

// Un solo "escuchador" para todos los botones Cancelar
document.getElementById("lista-proximas").addEventListener("click", async (e) => {
  const boton = e.target.closest("[data-cancelar]");
  if (!boton) return;
  if (!confirm("¿Seguro que querés cancelar esta reserva?")) return;

  boton.disabled = true;
  const { error } = await db.rpc("cancelar_mi_reserva", {
    p_id_reserva: Number(boton.dataset.cancelar),
  });

  if (error) {
    mostrarAviso("aviso-mis", "error", mensajeDeError(error));
    boton.disabled = false;
    return;
  }
  mostrarAviso("aviso-mis", "ok", "La reserva fue cancelada.");
  cargarReservas();
});


// ---------- Beneficios (Parte B) ----------
const NOMBRES_BENEFICIO = {
  cumpleanos: "🎂 Regalo de cumpleaños",
  reactivacion: "🌊 Te extrañamos",
  gasto: "🍷 Gracias por elegirnos",
  campana: "✨ Promoción",
};

function estadoBeneficio(b) {
  if (b.usado_en) return { texto: "Usado", clase: "estado-completada" };
  if (b.vence_en < hoyISO()) return { texto: "Vencido", clase: "estado-no_asistio" };
  return { texto: "Vigente", clase: "estado-confirmada" };
}

async function cargarBeneficios() {
  const [lista, resumen] = await Promise.all([
    db.from("beneficio").select("codigo, tipo, descripcion, vence_en, usado_en")
      .eq("id_usuario", idUsuario).order("creado_en", { ascending: false }).limit(12),
    db.rpc("mi_fidelizacion"),
  ]);
  if (lista.error) return;   // si la Parte B todavía no está instalada, no mostramos nada
  document.getElementById("caja-beneficios").classList.remove("oculto");

  const vigentes = lista.data.filter((b) => estadoBeneficio(b).texto === "Vigente");
  const otros = lista.data.filter((b) => estadoBeneficio(b).texto !== "Vigente").slice(0, 4);
  const caja = document.getElementById("lista-beneficios");
  if (!lista.data.length) {
    caja.innerHTML = '<div class="vacio">Todavía no tenés beneficios. ¡Llegan con tu cumpleaños y a medida que nos visitás!</div>';
  } else {
    caja.innerHTML = [...vigentes, ...otros].map((b) => {
      const e = estadoBeneficio(b);
      return `
        <div class="cupon ${e.texto === "Vigente" ? "" : "cupon-apagado"}">
          <div class="cupon-cuerpo">
            <div class="cupon-tipo">${NOMBRES_BENEFICIO[b.tipo] || "Beneficio"}</div>
            <div class="cupon-descripcion">${esc(b.descripcion)}</div>
            <div class="cupon-vence">${e.texto === "Vigente" ? `Válido hasta el ${formatearFecha(b.vence_en)}` : e.texto}</div>
          </div>
          <div class="cupon-codigo">
            <span class="cupon-codigo-texto">${esc(b.codigo)}</span>
            <span class="estado ${e.clase}">${e.texto}</span>
          </div>
        </div>`;
    }).join("");
  }

  const r = resumen.data;
  const progreso = document.getElementById("progreso-regalo");
  if (!r || resumen.error) { progreso.classList.add("oculto"); return; }
  const avance = r.meta_gasto - r.falta;
  document.getElementById("progreso-texto").textContent =
    `Te faltan ${formatearPesos(r.falta)} en consumos para tu próximo regalo: ${r.beneficio_gasto.toLowerCase()}.`;
  document.getElementById("progreso-cifra").textContent =
    `${formatearPesos(avance)} de ${formatearPesos(r.meta_gasto)}`;
  const barra = document.getElementById("progreso-barra");
  barra.max = r.meta_gasto;
  barra.value = avance;
}

(async () => {
  const acceso = await requerirSesion();
  if (!acceso) return;
  idUsuario = acceso.sesion.user.id;
  const nombre = acceso.perfil && acceso.perfil.nombre;
  if (nombre) document.getElementById("saludo").textContent = `Hola, ${nombre}. Estas son tus reservas.`;
  cargarReservas();
  cargarBeneficios();
})();
