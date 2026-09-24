// =========================================================
// Panel admin — por ahora solo protege la página.
// Mesas, reservas y dashboard llegan en la segunda tanda.
// =========================================================

(async () => {
  const acceso = await requerirSesion("admin");
  if (!acceso) return;
  const nombre = acceso.perfil && acceso.perfil.nombre;
  document.getElementById("saludo").textContent =
    `Hola${nombre ? ", " + nombre : ""}. Entraste como admin.`;
})();
