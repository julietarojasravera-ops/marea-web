// =========================================================
// Efectos de la portada: menú que se vuelve sólido al bajar
// y secciones que aparecen suavemente al hacer scroll.
// No depende de Supabase: si algo falla, la página se ve igual.
// =========================================================

(() => {
  const nav = document.getElementById("nav");
  if (nav) {
    const actualizar = () => nav.classList.toggle("nav-solida", window.scrollY > 40);
    actualizar();
    window.addEventListener("scroll", actualizar, { passive: true });
  }

  const elementos = document.querySelectorAll(".revelar");
  const sinMovimiento = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!elementos.length || sinMovimiento || !("IntersectionObserver" in window)) return;

  // Recién ahora ocultamos: sin JavaScript, todo queda visible
  document.documentElement.classList.add("con-animacion");
  const observador = new IntersectionObserver((entradas) => {
    entradas.forEach((entrada) => {
      if (entrada.isIntersecting) {
        entrada.target.classList.add("visible");
        observador.unobserve(entrada.target);
      }
    });
  }, { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
  elementos.forEach((el) => observador.observe(el));
})();

// ---------- Banda "Club Marea": texto del regalo y botón según la sesión ----------
(async () => {
  if (typeof db === "undefined") return;
  try {
    const regalo = await textoBienvenida();
    const p = document.getElementById("beneficio-regalo");
    if (p) p.textContent = regalo.endsWith(".") ? regalo : `${regalo}.`;
    const sesion = await obtenerSesion();
    if (!sesion) return;
    const { data: u } = await db.from("usuario").select("rol, acepta_promociones").eq("id_usuario", sesion.user.id).single();
    const cta = document.getElementById("beneficios-cta");
    if (!u || u.rol !== "cliente" || u.acepta_promociones) {
      document.getElementById("beneficios").classList.add("oculto");
    } else if (cta) {
      cta.textContent = "Quiero recibir beneficios";
      cta.href = "perfil.html";
    }
  } catch (e) { /* la portada se ve igual */ }
})();
