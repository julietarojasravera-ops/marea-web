// =========================================================
// Pronóstico del clima (API externa: Open-Meteo)
// https://open-meteo.com — gratis y sin clave, así que no hay nada
// secreto en el sitio. Da el pronóstico hora por hora hasta 16 días.
// Lo usan: la página Reservar (cliente) y el Dashboard (admin).
// =========================================================

const CLIMA_LUGAR = { lat: -34.95, lon: -54.93 };   // Playa Brava, parada 8, Punta del Este
const CLIMA_URL = "https://api.open-meteo.com/v1/forecast";
const climaGuardado = {};   // un pedido por día

// Códigos del tiempo de la OMM (los usa Open-Meteo) → ícono y texto
function describirClima(codigo) {
  if (codigo === 0) return { icono: "☀️", texto: "Despejado" };
  if (codigo <= 2) return { icono: "🌤️", texto: "Algo nublado" };
  if (codigo === 3) return { icono: "☁️", texto: "Nublado" };
  if (codigo <= 48) return { icono: "🌫️", texto: "Niebla" };
  if (codigo <= 57) return { icono: "🌦️", texto: "Llovizna" };
  if (codigo <= 67) return { icono: "🌧️", texto: "Lluvia" };
  if (codigo <= 77) return { icono: "🌨️", texto: "Nieve" };
  if (codigo <= 82) return { icono: "🌦️", texto: "Chaparrones" };
  return { icono: "⛈️", texto: "Tormenta" };
}

function diasHasta(fechaISO) {
  const [a, m, d] = fechaISO.split("-").map(Number);
  const hoy = new Date(); hoy.setHours(0, 0, 0, 0);
  return Math.round((new Date(a, m - 1, d) - hoy) / 86400000);
}

// Devuelve { "19": {...}, "20": {...}, ... } para ese día, o null si no hay pronóstico
async function pronosticoDelDia(fechaISO) {
  const dias = diasHasta(fechaISO);
  if (dias < 0 || dias > 15) return null;
  if (!climaGuardado[fechaISO]) {
    const url = `${CLIMA_URL}?latitude=${CLIMA_LUGAR.lat}&longitude=${CLIMA_LUGAR.lon}` +
      "&hourly=temperature_2m,precipitation_probability,weather_code,wind_speed_10m" +
      `&timezone=America%2FMontevideo&start_date=${fechaISO}&end_date=${fechaISO}`;
    climaGuardado[fechaISO] = fetch(url)
      .then((r) => (r.ok ? r.json() : null))
      .then((datos) => {
        if (!datos || !datos.hourly) return null;
        const h = datos.hourly;
        const porHora = {};
        h.time.forEach((t, i) => {
          porHora[t.slice(11, 13)] = {
            temp: Math.round(h.temperature_2m[i]),
            lluvia: h.precipitation_probability[i] ?? 0,
            viento: Math.round(h.wind_speed_10m[i]),
            ...describirClima(h.weather_code[i]),
          };
        });
        return porHora;
      })
      .catch(() => null);
  }
  return climaGuardado[fechaISO];
}

// ---------- Cliente: al elegir día y hora en Reservar ----------
async function pintarClimaReserva(fechaISO, hora) {
  const caja = document.getElementById("clima-reserva");
  if (!caja || !fechaISO || !hora) return;
  const dias = diasHasta(fechaISO);
  if (dias > 15) {
    caja.className = "clima-reserva";
    caja.textContent = "🌤️ El pronóstico del tiempo aparece 16 días antes.";
    return;
  }
  const porHora = await pronosticoDelDia(fechaISO);
  const h = porHora && porHora[hora.slice(0, 2)];
  if (!h) { caja.className = "clima-reserva oculto"; return; }
  caja.className = "clima-reserva";
  caja.innerHTML = `
    <span class="clima-icono" aria-hidden="true">${h.icono}</span>
    <span><b>Pronóstico para las ${hora} h:</b> ${h.texto.toLowerCase()}, ${h.temp} °C ·
    ${h.lluvia} % de probabilidad de lluvia · viento ${h.viento} km/h</span>`;
}

// ---------- Admin: la noche completa en el Dashboard ----------
async function pintarClimaNoche(fechaISO) {
  const caja = document.getElementById("clima-noche");
  if (!caja || !fechaISO) return;
  const porHora = await pronosticoDelDia(fechaISO);
  const horas = ["19", "20", "21", "22", "23"].filter((x) => porHora && porHora[x]);
  if (!horas.length) { caja.classList.add("oculto"); return; }

  const lista = horas.map((x) => porHora[x]);
  const lluviaMax = Math.max(...lista.map((h) => h.lluvia));
  const vientoMax = Math.max(...lista.map((h) => h.viento));
  const tempMin = Math.min(...lista.map((h) => h.temp));
  let consejo;
  if (lluviaMax >= 50) consejo = { clase: "clima-mal", texto: "Probable lluvia: puede haber cancelaciones y llegadas tarde." };
  else if (vientoMax >= 30) consejo = { clase: "clima-regular", texto: "Noche ventosa: el salón y el ventanal van a estar muy pedidos." };
  else if (tempMin < 14) consejo = { clase: "clima-regular", texto: "Noche fresca: tener mantas para quienes esperan afuera." };
  else consejo = { clase: "clima-bien", texto: "Buena noche: se espera un lindo atardecer desde el ventanal." };

  caja.classList.remove("oculto");
  caja.innerHTML = `
    <div class="clima-noche-cabecera">
      <div><b>Clima de la noche</b> · Playa Brava</div>
      <span class="clima-consejo ${consejo.clase}">${consejo.texto}</span>
    </div>
    <div class="clima-horas">
      ${horas.map((x) => {
        const h = porHora[x];
        return `<div class="clima-hora" title="${h.texto}">
          <span class="clima-hora-nombre">${x}:00</span>
          <span class="clima-icono" aria-hidden="true">${h.icono}</span>
          <span class="clima-temp">${h.temp}°</span>
          <span class="celda-secundaria">💧 ${h.lluvia} % · 💨 ${h.viento}</span>
        </div>`;
      }).join("")}
    </div>
    <div class="celda-secundaria mt-1">Pronóstico de <a href="https://open-meteo.com" target="_blank" rel="noopener">Open-Meteo</a></div>`;
}
