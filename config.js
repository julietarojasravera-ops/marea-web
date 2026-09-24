// =========================================================
// CONFIGURACIÓN — el único archivo que tenés que editar
// =========================================================
// 1. En Supabase andá a: Project Settings → API Keys
//    (o tocá el botón verde "Connect" arriba del panel).
// 2. Copiá la clave "anon" / "public" (la larga que empieza con eyJ...
//    o la "publishable" que empieza con sb_publishable_...).
// 3. Ya está pegada abajo. Si algún día cambia, se reemplaza ahí.
//
// Esta clave es pública a propósito: la seguridad la dan las reglas
// (RLS) que cargamos en la base. NUNCA pegues acá la "service_role".
// =========================================================

window.MAREA_CONFIG = {
  supabaseUrl: "https://owoidgtsnrqynlzquiug.supabase.co",
  supabaseAnonKey: "sb_publishable_FBzwKpjmPBB9nD4qarFWhg_-NcSzRVE",
};
