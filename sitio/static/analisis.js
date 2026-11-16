// Goalmetry - comportamiento de las pantallas de análisis (sin librerías externas).
"use strict";

// ---------- Posiciones por jornada: dejar marcado un equipo ----------
document.querySelectorAll("[data-bump] .bump-linea").forEach((g) => {
  const alternar = () => {
    const estaba = g.classList.contains("fijada");
    document.querySelectorAll("[data-bump] .fijada").forEach((o) => o.classList.remove("fijada"));
    if (!estaba) { g.classList.add("fijada"); g.parentNode.append(g); }
  };
  g.addEventListener("click", alternar);
  g.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); alternar(); } });
});

// Jugadores parecidos: elegir un jugador lleva directamente a su comparación.
document.querySelectorAll("[data-enviar-al-cambiar]").forEach((s) =>
  s.addEventListener("change", () => { if (s.value) s.form.requestSubmit(); }));

// Asistente de jornada: seguir la actualización en marcha.
const zonaProceso = document.querySelector("[data-proceso]");
if (zonaProceso) {
  const seguir = async () => {
    try {
      const r = await fetch(zonaProceso.dataset.url);
      const e = await r.json();
      zonaProceso.querySelector("[data-proceso-estado]").textContent = e.texto;
      zonaProceso.querySelector("[data-proceso-registro]").textContent = e.registro;
      if (!e.terminado) setTimeout(seguir, 3000);
    } catch { setTimeout(seguir, 8000); }
  };
  seguir();
}
