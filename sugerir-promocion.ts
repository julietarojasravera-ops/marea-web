// =========================================================
// Supabase Edge Function: sugerir-promocion   (PARTE B · IA)
//
// El admin elige un público (segmento, zona favorita, pareja/grupo)
// y la IA (Claude, de Anthropic) le propone una promoción:
// nombre, asunto, mensaje y un beneficio.
//
//  - Solo un administrador puede usarla (lo verifica la base de datos).
//  - A la IA solo le mandamos totales anónimos: nunca nombres ni correos.
//  - La clave de Anthropic vive en los "Secrets" de Supabase, no en el sitio.
//  - Máximo 30 sugerencias por día (lo controla la base).
//
// Dónde va: Supabase > Edge Functions > Deploy a new function > Via Editor
//           nombre: sugerir-promocion   (pegar todo este archivo)
// Secreto:  Edge Functions > Secrets > ANTHROPIC_API_KEY = tu clave
// =========================================================

const MODELO = "claude-haiku-4-5-20251001";   // rápido y barato: ~US$ 0,005 por sugerencia

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function responder(cuerpo: unknown, estado = 200) {
  return new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

const NOMBRES_SEGMENTO: Record<string, string> = {
  todos: "todos los clientes",
  nuevo: "clientes nuevos (0 a 2 visitas)",
  frecuente: "clientes frecuentes (3 o más visitas en el año)",
  vip: "clientes VIP (6 o más visitas en el año)",
  en_riesgo: "clientes en riesgo (hace más de 60 días que no vienen)",
  inactivo: "clientes inactivos (hace más de 150 días que no vienen)",
};

const INSTRUCCIONES = `Sos el responsable de marketing de Marea, un restaurante de cocina de mar
frente al mar en Playa Brava, Punta del Este (Uruguay). Cenas de martes a domingo, de 19 a 00 h.
Ambientes: Ventanal (mesas para 2 frente al mar), Salón (mesas para 4), Barra (mesas largas para 8)
y Fondo (mesas para 6, más tranquilo).
Algunos platos: ceviche de corvina, pulpo a la brasa, pesca del día, risotto de mariscos,
tagliatelle con langostinos, parrillada de mar para compartir, burrata con duraznos,
lemon pie y cheesecake de dulce de leche.

Tu tarea: proponer UNA promoción por correo para el público que te describen, usando sus
preferencias (zona favorita, días, horario, si vienen en pareja o en grupo, ocasiones).
Reglas:
- Español rioplatense con voseo ("reservá", "vení"), cálido y breve. Sin exageraciones.
- El mensaje: 2 a 4 oraciones, máximo 500 caracteres, sin saludo inicial (el correo ya dice "Hola, <nombre>")
  y sin firma. No inventes precios ni fechas exactas.
- El beneficio: concreto y realista para un restaurante (una copa, un postre, un descuento de 10 a 20 %).
  Máximo 80 caracteres.
- El asunto: máximo 70 caracteres, que den ganas de abrirlo.
- El nombre: interno, corto, para que el equipo reconozca la campaña.
- "por_que": una oración que explique al administrador por qué esta idea encaja con ese público.
Respondé SOLO con un JSON válido, sin texto antes ni después, con estas claves:
{"nombre": "...", "asunto": "...", "mensaje": "...", "beneficio": "...", "por_que": "..."}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder({ error: "Método no permitido" }, 405);

  const claveIA = Deno.env.get("ANTHROPIC_API_KEY");
  if (!claveIA) return responder({ error: "Falta configurar ANTHROPIC_API_KEY en los Secrets de Supabase." }, 500);

  const autorizacion = req.headers.get("Authorization") ?? "";
  const apikey = req.headers.get("apikey") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!autorizacion.startsWith("Bearer ")) return responder({ error: "Tenés que iniciar sesión." }, 401);

  let pedido: { segmento?: string; zona?: string; grupo?: string; idea?: string };
  try {
    pedido = await req.json();
  } catch {
    return responder({ error: "Pedido inválido." }, 400);
  }
  const idea = String(pedido.idea ?? "").slice(0, 200);

  // 1) La base verifica que sea admin, controla el límite diario y arma el resumen anónimo
  const resp = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/resumen_para_ia`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey, Authorization: autorizacion },
    body: JSON.stringify({
      p_segmento: pedido.segmento ?? "",
      p_zona: pedido.zona ?? "",
      p_grupo: pedido.grupo ?? "",
    }),
  });
  const resumen = await resp.json();
  if (!resp.ok) return responder({ error: resumen?.message ?? "No se pudo leer el público." }, 403);
  if (!resumen.clientes) return responder({ error: "Ningún cliente coincide con ese público." }, 400);

  // 2) Le pedimos la idea a Claude
  const publico = `Público elegido: ${NOMBRES_SEGMENTO[resumen.segmento] ?? resumen.segmento}` +
    `; zona favorita: ${resumen.zona_elegida}; suelen venir: ${resumen.grupo_elegido}.\n` +
    `Datos (totales anónimos): ${JSON.stringify(resumen)}` +
    (idea ? `\nIdea del administrador para esta promoción: ${idea}` : "");

  const ia = await fetch(Deno.env.get("ANTHROPIC_URL") ?? "https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": claveIA,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: MODELO,
      max_tokens: 600,
      system: INSTRUCCIONES,
      messages: [{ role: "user", content: publico }],
    }),
  });
  const respuesta = await ia.json();
  if (!ia.ok) {
    console.error("Error de Anthropic", respuesta);
    return responder({ error: "La IA no respondió. Revisá la clave y el crédito de Anthropic." }, 502);
  }

  // 3) Sacamos el JSON de la respuesta y lo recortamos a los largos del formulario
  const texto: string = respuesta?.content?.[0]?.text ?? "";
  const inicio = texto.indexOf("{");
  const fin = texto.lastIndexOf("}");
  try {
    const s = JSON.parse(texto.slice(inicio, fin + 1));
    const corto = (v: unknown, n: number) => String(v ?? "").trim().slice(0, n);
    return responder({
      nombre: corto(s.nombre, 80),
      asunto: corto(s.asunto, 120),
      mensaje: corto(s.mensaje, 1000),
      beneficio: corto(s.beneficio, 120),
      por_que: corto(s.por_que, 300),
      publico: { clientes: resumen.clientes, aceptan_correos: resumen.aceptan_correos },
    });
  } catch {
    return responder({ error: "La IA respondió en un formato inesperado. Probá de nuevo." }, 502);
  }
});
