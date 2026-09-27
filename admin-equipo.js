// =========================================================
// Panel admin: Equipo (administradores por invitación)
// Las reglas de seguridad están en la base (sql-8):
// solo admins invitan, el enlace es único, vence y va atado al correo.
// =========================================================

let miIdUsuario = null;

function fechaHora(valor) {
  return new Date(valor).toLocaleString("es-UY", {
    day: "numeric", month: "short", hour: "2-digit", minute: "2-digit",
  });
}

async function cargarEquipo() {
  if (!miIdUsuario) {
    const sesion = await obtenerSesion();
    miIdUsuario = sesion ? sesion.user.id : null;
  }
  const [admins, invitaciones, auditoria] = await Promise.all([
    db.from("usuario").select("id_usuario, nombre, email, telefono").eq("rol", "admin").order("nombre"),
    db.from("invitacion_admin").select("*").order("creada_en", { ascending: false }).limit(15),
    db.from("registro_roles")
      .select("id_usuario, fecha, rol_anterior, rol_nuevo, cambiado_por, usuario(nombre, email)")
      .order("fecha", { ascending: false }).limit(20),
  ]);
  if (admins.error) { avisoAdmin("error", mensajeDeError(admins.error)); return; }

  pintarAdmins(admins.data);
  pintarInvitaciones(invitaciones.data || []);
  pintarAuditoria(auditoria.data || [], admins.data);
}

function pintarAdmins(lista) {
  document.getElementById("lista-admins").innerHTML = lista.map((a) => `
    <div class="fila-equipo">
      <div class="avatar-inicial" aria-hidden="true">${esc((a.nombre || a.email)[0].toUpperCase())}</div>
      <div class="flex-grow-1">
        <div class="celda-principal">${esc(a.nombre || "Sin nombre")}${a.id_usuario === miIdUsuario ? ' <span class="estado estado-completada ms-1">Vos</span>' : ""}</div>
        <div class="celda-secundaria">${esc(a.email)}${a.telefono ? ` · ${esc(a.telefono)}` : ""}</div>
      </div>
      ${a.id_usuario !== miIdUsuario && lista.length > 1
        ? `<button type="button" class="btn-borde btn-peligro" data-quitar="${a.id_usuario}" data-nombre="${esc(a.nombre || a.email)}">Quitar admin</button>`
        : ""}
    </div>`).join("");
}

function estadoInvitacion(i) {
  if (i.usada_en) return { texto: "Aceptada", clase: "estado-confirmada" };
  if (i.revocada) return { texto: "Revocada", clase: "estado-cancelada" };
  if (new Date(i.vence_en) < new Date()) return { texto: "Vencida", clase: "estado-no_asistio" };
  return { texto: "Pendiente", clase: "estado-sentada" };
}

function pintarInvitaciones(lista) {
  const caja = document.getElementById("lista-invitaciones");
  if (!lista.length) {
    caja.innerHTML = `<p class="pagina-bajada mb-0">Todavía no hay invitaciones.</p>`;
    return;
  }
  caja.innerHTML = lista.map((i) => {
    const e = estadoInvitacion(i);
    return `
      <div class="fila-equipo">
        <div class="flex-grow-1">
          <div class="celda-principal">${esc(i.email)}</div>
          <div class="celda-secundaria">Enviada ${fechaHora(i.creada_en)}${e.texto === "Pendiente" ? ` · vence ${fechaHora(i.vence_en)}` : ""}</div>
        </div>
        <span class="estado ${e.clase}">${e.texto}</span>
        ${e.texto === "Pendiente" ? `<button type="button" class="btn-borde btn-peligro" data-revocar="${i.id}">Revocar</button>` : ""}
      </div>`;
  }).join("");
}

function pintarAuditoria(lista, admins) {
  const cuerpo = document.getElementById("tabla-auditoria");
  if (!lista.length) {
    cuerpo.innerHTML = `<tr><td colspan="4" class="text-center py-3 texto-suave">Sin cambios registrados.</td></tr>`;
    return;
  }
  const nombreDe = (id) => {
    if (!id) return "Desde Supabase";
    const a = admins.find((x) => x.id_usuario === id);
    return a ? (a.nombre || a.email) : "Otro usuario";
  };
  cuerpo.innerHTML = lista.map((r) => `
    <tr>
      <td class="celda-fecha">${fechaHora(r.fecha)}</td>
      <td>${esc(r.usuario?.nombre || r.usuario?.email || "–")}</td>
      <td>${esc(r.rol_anterior || "–")} → <b>${esc(r.rol_nuevo)}</b></td>
      <td>${r.cambiado_por && r.cambiado_por === r.id_usuario ? "Aceptó una invitación" : esc(nombreDe(r.cambiado_por))}</td>
    </tr>`).join("");
}

// ---------- Acciones ----------
document.getElementById("form-invitar").addEventListener("submit", async (e) => {
  e.preventDefault();
  const boton = e.target.querySelector("button[type=submit]");
  const campo = document.getElementById("invitar-email");
  boton.disabled = true;
  const { data, error } = await db.rpc("invitar_admin", { p_email: campo.value });
  boton.disabled = false;
  if (error) { avisoAdmin("error", mensajeDeError(error)); return; }
  avisoAdmin("ok", `Invitación enviada a ${data.email}. Vence en 48 horas.`);
  campo.value = "";
  cargarEquipo();
});

document.getElementById("sec-equipo").addEventListener("click", async (e) => {
  const quitar = e.target.closest("[data-quitar]");
  const revocar = e.target.closest("[data-revocar]");
  if (!quitar && !revocar) return;

  let resultado;
  if (quitar) {
    if (!confirm(`¿Quitarle el rol de administrador a ${quitar.dataset.nombre}? Va a quedar como cliente.`)) return;
    resultado = await db.rpc("quitar_admin", { p_id_usuario: quitar.dataset.quitar });
    if (!resultado.error) avisoAdmin("ok", `${quitar.dataset.nombre} ya no es administrador/a.`);
  } else {
    if (!confirm("¿Revocar esta invitación? El enlace deja de funcionar.")) return;
    resultado = await db.rpc("revocar_invitacion", { p_id: revocar.dataset.revocar });
    if (!resultado.error) avisoAdmin("ok", "Invitación revocada.");
  }
  if (resultado.error) avisoAdmin("error", mensajeDeError(resultado.error));
  cargarEquipo();
});
