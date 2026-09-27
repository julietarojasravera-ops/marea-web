// =========================================================
// Plano del local: dibuja el salón y las mesas en un SVG.
// Lo usan la página Reservar (elegir mesa) y el panel admin
// (arrastrar las mesas para que el plano sea igual al local).
// Coordenadas: x de 0 a 120, y de 0 a 80.
// =========================================================

const SVG_NS = "http://www.w3.org/2000/svg";
const PLANO_ANCHO = 120;
const PLANO_ALTO = 80;

function nodo(tipo, atributos = {}, texto = null) {
  const el = document.createElementNS(SVG_NS, tipo);
  Object.entries(atributos).forEach(([k, v]) => el.setAttribute(k, v));
  if (texto !== null) el.textContent = texto;
  return el;
}

function formaDe(mesa) {
  if (mesa.forma) return mesa.forma;
  if (mesa.capacidad <= 2) return "redonda";
  if (mesa.capacidad <= 4) return "cuadrada";
  return "rectangular";
}

// Tamaño de la mesa según su forma y capacidad
function medidas(mesa) {
  const forma = formaDe(mesa);
  if (forma === "redonda") return { forma, r: mesa.capacidad <= 2 ? 3.6 : 4.6 };
  if (forma === "cuadrada") return { forma, w: 8, h: 8 };
  const porLado = Math.ceil(mesa.capacidad / 2);
  return { forma, w: Math.max(10, porLado * 4.2 + 2), h: 6.5 };
}

// Posición de cada silla alrededor de la mesa
function sillas(mesa) {
  const m = medidas(mesa);
  const n = mesa.capacidad;
  const lista = [];
  if (m.forma === "redonda") {
    for (let i = 0; i < n; i++) {
      const ang = (Math.PI * 2 * i) / n - Math.PI / 2;
      lista.push([Math.cos(ang) * (m.r + 2.1), Math.sin(ang) * (m.r + 2.1)]);
    }
    return lista;
  }
  const arriba = Math.ceil(n / 2);
  const abajo = n - arriba;
  const fila = (cant, y) => {
    for (let i = 0; i < cant; i++) {
      const x = -m.w / 2 + (m.w / (cant + 1)) * (i + 1);
      lista.push([x, y]);
    }
  };
  fila(arriba, -m.h / 2 - 2);
  fila(abajo, m.h / 2 + 2);
  return lista;
}

// Mesas sin ubicación: se acomodan abajo a la izquierda
function posicion(mesa, indice) {
  if (mesa.pos_x !== null && mesa.pos_x !== undefined && mesa.pos_y !== null && mesa.pos_y !== undefined) {
    return [Number(mesa.pos_x), Number(mesa.pos_y)];
  }
  return [30 + (indice % 5) * 12, 76];
}

function dibujarSala(svg) {
  const g = nodo("g", { class: "plano-fondo" });
  g.appendChild(nodo("rect", { x: 1, y: 3, width: 118, height: 76, rx: 2, class: "plano-sala" }));
  // Ventanal al mar (arriba)
  g.appendChild(nodo("path", {
    d: "M6 1 q2 -1 4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0 t4 0",
    class: "plano-ola",
  }));
  g.appendChild(nodo("rect", { x: 4, y: 1.8, width: 90, height: 2.6, rx: 1, class: "plano-ventanal" }));
  g.appendChild(nodo("text", { x: 49, y: 3.75, class: "plano-etiqueta plano-etiqueta-ventanal", "text-anchor": "middle" }, "VENTANAL AL MAR"));
  // Zonas (texto suave)
  g.appendChild(nodo("text", { x: 3.5, y: 26, class: "plano-zona" }, "SALÓN"));
  g.appendChild(nodo("text", { x: 3.5, y: 62, class: "plano-zona" }, "FONDO"));
  // Barra (derecha)
  g.appendChild(nodo("rect", { x: 104, y: 22, width: 10, height: 36, rx: 1.5, class: "plano-barra" }));
  g.appendChild(nodo("text", { x: 109, y: 40, class: "plano-etiqueta plano-etiqueta-clara", "text-anchor": "middle",
    transform: "rotate(-90 109 40)" }, "BARRA"));
  // Cocina (abajo a la derecha)
  g.appendChild(nodo("rect", { x: 96, y: 62, width: 23, height: 17, class: "plano-cocina" }));
  g.appendChild(nodo("text", { x: 107.5, y: 71.5, class: "plano-etiqueta", "text-anchor": "middle" }, "COCINA"));
  // Entrada (arriba a la derecha)
  g.appendChild(nodo("rect", { x: 100, y: 1.6, width: 15, height: 2.8, class: "plano-entrada" }));
  g.appendChild(nodo("text", { x: 107.5, y: 8.5, class: "plano-etiqueta", "text-anchor": "middle" }, "ENTRADA"));
  svg.appendChild(g);
}

/**
 * opciones:
 *   estados:   { id_mesa: { estado, libre_desde } }  (libre, ocupada, chica, inactiva)
 *   seleccion: id_mesa elegida
 *   alElegir(mesa, estadoInfo)
 *   editable:  true para poder arrastrar (admin)
 *   alMover(mesa, x, y)
 */
function dibujarPlano(svg, mesas, opciones = {}) {
  svg.innerHTML = "";
  svg.setAttribute("viewBox", `0 0 ${PLANO_ANCHO} ${PLANO_ALTO}`);
  svg.classList.toggle("plano-editable", !!opciones.editable);
  dibujarSala(svg);

  mesas.forEach((mesa, i) => {
    const [x, y] = posicion(mesa, i);
    mesa.etiquetaExtra = opciones.etiqueta ? opciones.etiqueta(mesa) : null;
    const info = (opciones.estados && opciones.estados[mesa.id_mesa]) || { estado: mesa.estado === "inactiva" ? "inactiva" : "neutra" };
    const elegida = opciones.seleccion === mesa.id_mesa;
    const marcada = opciones.marcada === mesa.id_mesa;
    const clase = `mesa-plano mesa-${info.estado}${elegida ? " mesa-elegida" : ""}${marcada ? " mesa-marcada" : ""}`;
    const grupo = nodo("g", {
      class: clase,
      transform: `translate(${x} ${y})`,
      tabindex: "0",
      role: "button",
      "data-id": mesa.id_mesa,
      "aria-label": `Mesa ${mesa.numero}, ${mesa.capacidad} personas, ${textoEstadoMesa(info)}`,
    });
    grupo.appendChild(nodo("title", {}, `Mesa ${mesa.numero} · ${mesa.capacidad} personas · ${textoEstadoMesa(info)}`));

    sillas(mesa).forEach(([sx, sy]) => grupo.appendChild(nodo("circle", { cx: sx, cy: sy, r: 1.25, class: "silla" })));
    const m = medidas(mesa);
    if (m.forma === "redonda") {
      grupo.appendChild(nodo("circle", { cx: 0, cy: 0, r: m.r, class: "tabla" }));
    } else {
      grupo.appendChild(nodo("rect", { x: -m.w / 2, y: -m.h / 2, width: m.w, height: m.h, rx: 1.2, class: "tabla" }));
    }
    grupo.appendChild(nodo("text", { x: 0, y: 0.4, class: "mesa-numero", "text-anchor": "middle", "dominant-baseline": "middle" }, mesa.numero));
    if (mesa.etiquetaExtra) {
      const alto = m.forma === "redonda" ? m.r + 5.2 : m.h / 2 + 5.4;
      grupo.appendChild(nodo("text", { x: 0, y: alto, class: "mesa-extra", "text-anchor": "middle" }, mesa.etiquetaExtra));
    }

    if (!opciones.editable && opciones.alElegir) {
      const elegir = () => opciones.alElegir(mesa, info);
      grupo.addEventListener("click", elegir);
      grupo.addEventListener("keydown", (e) => {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); elegir(); }
      });
    }
    if (opciones.editable) activarArrastre(svg, grupo, mesa, opciones.alMover);
    svg.appendChild(grupo);
  });
}

function textoEstadoMesa(info) {
  switch (info.estado) {
    case "libre": return "libre";
    case "ocupada": return info.libre_desde ? `ocupada, se libera a las ${info.libre_desde}` : "ocupada";
    case "chica": return "no entra el grupo";
    case "grande": return "para grupos más grandes";
    case "inactiva": return "no disponible";
    case "reservada": return "reservada";
    case "sentada": return "con clientes";
    case "proxima": return "llegan pronto";
    case "limpieza": return "en limpieza";
    default: return "mesa";
  }
}

// ---------- Arrastrar mesas (admin) ----------
function puntoEnPlano(svg, evento) {
  const p = svg.createSVGPoint();
  p.x = evento.clientX;
  p.y = evento.clientY;
  return p.matrixTransform(svg.getScreenCTM().inverse());
}

function activarArrastre(svg, grupo, mesa, alMover) {
  let arrastrando = false;
  let desplazamiento = [0, 0];
  let actual = [0, 0];

  grupo.addEventListener("pointerdown", (e) => {
    arrastrando = true;
    grupo.setPointerCapture(e.pointerId);
    const p = puntoEnPlano(svg, e);
    const t = grupo.transform.baseVal.getItem(0).matrix;
    desplazamiento = [p.x - t.e, p.y - t.f];
    grupo.classList.add("arrastrando");
  });
  grupo.addEventListener("pointermove", (e) => {
    if (!arrastrando) return;
    const p = puntoEnPlano(svg, e);
    const x = Math.min(PLANO_ANCHO - 4, Math.max(4, p.x - desplazamiento[0]));
    const y = Math.min(PLANO_ALTO - 4, Math.max(8, p.y - desplazamiento[1]));
    actual = [Math.round(x * 2) / 2, Math.round(y * 2) / 2];
    grupo.setAttribute("transform", `translate(${actual[0]} ${actual[1]})`);
  });
  const soltar = () => {
    if (!arrastrando) return;
    arrastrando = false;
    grupo.classList.remove("arrastrando");
    if (alMover && (actual[0] || actual[1])) alMover(mesa, actual[0], actual[1]);
  };
  grupo.addEventListener("pointerup", soltar);
  grupo.addEventListener("pointercancel", soltar);
}
