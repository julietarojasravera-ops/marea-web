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
        <div class="reserva-fecha">${formatearFecha(r.fecha)} · ${formatearHora(r.hora)}</div>
        <div class="reserva-detalle">${personas} · Reserva n.º ${r.id_reserva}</div>
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
    .select("id_reserva, fecha, hora, cantidad_personas, estado")
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

(async () => {
  const acceso = await requerirSesion();
  if (!acceso) return;
  idUsuario = acceso.sesion.user.id;
  const nombre = acceso.perfil && acceso.perfil.nombre;
  if (nombre) document.getElementById("saludo").textContent = `Hola, ${nombre}. Estas son tus reservas.`;
  cargarReservas();
})();
