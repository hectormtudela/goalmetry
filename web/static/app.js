// LaLigaDB - comportamiento de las páginas (sin librerías externas).
"use strict";

const csrf = document.querySelector('meta[name="csrf"]').content;

async function pedir(url, datos) {
  const opciones = datos === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
    body: JSON.stringify(datos),
  };
  const respuesta = await fetch(url, opciones);
  let cuerpo = {};
  try { cuerpo = await respuesta.json(); } catch { /* respuesta vacía o HTML */ }
  if (!respuesta.ok) throw new Error(cuerpo.error || "No se ha podido completar la petición.");
  return cuerpo;
}

function cargando(contenedor, texto) {
  contenedor.replaceChildren();
  const p = document.createElement("p");
  p.className = "tarjeta cargando";
  p.textContent = texto;
  contenedor.append(p);
}

function mostrarError(contenedor, mensaje) {
  contenedor.replaceChildren();
  const p = document.createElement("p");
  p.className = "aviso aviso-error";
  p.textContent = mensaje;
  contenedor.append(p);
}

// Menú en el móvil
document.querySelector("[data-menu]")?.addEventListener("click", () => {
  document.getElementById("menu").classList.toggle("abierto");
});

// Desplegables que envían el formulario al cambiar
document.querySelectorAll("[data-auto-enviar]").forEach((s) => s.addEventListener("change", () => s.form.submit()));

// Confirmación antes de borrar
document.querySelectorAll("form[data-confirmar]").forEach((f) => f.addEventListener("submit", (e) => {
  if (!confirm(f.dataset.confirmar)) e.preventDefault();
}));

// Aviso si la IA (Ollama + Caddy) no está encendida
const avisoIA = document.querySelector("[data-estado-ia]");
if (avisoIA) {
  pedir("/api/estado-ia").then((e) => {
    if (e.ollama && e.proxy) return;
    avisoIA.textContent = !e.ollama
      ? "La IA no está encendida en este momento (Ollama). Las búsquedas por significado y las preguntas no funcionarán."
      : "Falta el puente HTTPS de la IA (Caddy). Cierra la web y ábrela de nuevo con iniciar-web.bat.";
    avisoIA.classList.remove("oculto");
  }).catch(() => {});
}

// ---------- Buscador ----------
const buscador = document.querySelector("[data-buscador]");
if (buscador) {
  const zona = document.querySelector("[data-resultados]");
  const plantilla = document.getElementById("plantilla-resultado");
  buscador.addEventListener("submit", async (e) => {
    e.preventDefault();
    const datos = Object.fromEntries(new FormData(buscador));
    const boton = buscador.querySelector("button[type=submit]");
    boton.disabled = true;
    cargando(zona, datos.modo === "texto" ? "Buscando…" : "Buscando… (la primera búsqueda puede tardar un poco mientras la IA arranca)");
    try {
      const r = await pedir("/api/buscar", datos);
      zona.replaceChildren();
      if (!r.resultados.length) {
        mostrarError(zona, "No se ha encontrado nada. Prueba con otras palabras o con la búsqueda por significado.");
        return;
      }
      const resumen = document.createElement("p");
      resumen.className = "nota";
      resumen.textContent = `${r.resultados.length} resultados en ${r.segundos.toLocaleString("es-ES")} s`;
      zona.append(resumen);
      r.resultados.forEach((d, i) => {
        const n = plantilla.content.cloneNode(true);
        n.querySelector(".chip").textContent = d.TipoNombre;
        n.querySelector(".puntuacion").textContent = i === 0 ? "Mejor resultado" : `Resultado ${i + 1}`;
        n.querySelector("h3").textContent = d.Titulo;
        n.querySelector("p").textContent = d.Extracto + (d.Largo > d.Extracto.length ? "…" : "");
        zona.append(n);
      });
    } catch (error) {
      mostrarError(zona, error.message);
    } finally {
      boton.disabled = false;
    }
  });
}

// ---------- Pregunta a la IA ----------
const formPregunta = document.querySelector("[data-pregunta]");
if (formPregunta) {
  const zona = document.querySelector("[data-respuestas]");
  const plantilla = document.getElementById("plantilla-respuesta");
  const area = formPregunta.querySelector("textarea");
  formPregunta.querySelectorAll(".chip-boton").forEach((b) => b.addEventListener("click", () => {
    area.value = b.textContent;
    area.focus();
  }));
  area.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); formPregunta.requestSubmit(); }
  });

  const pintar = (titulo, r, sinDatos) => {
    const n = plantilla.content.cloneNode(true);
    const art = n.querySelector("article");
    if (sinDatos) art.classList.add("sin-datos");
    const chip = n.querySelector(".chip");
    chip.textContent = titulo;
    if (sinDatos) chip.classList.add("chip-aviso");
    n.querySelector(".tiempo").textContent = `${r.segundos.toLocaleString("es-ES")} s`;
    n.querySelector(".texto").textContent = r.respuesta;
    const lista = n.querySelector("ol");
    if (r.fuentes.length) {
      for (const f of r.fuentes) {
        const li = document.createElement("li");
        li.textContent = `${f.Titulo} (${f.Tipo})`;
        lista.append(li);
      }
    } else {
      n.querySelector(".fuentes").remove();
    }
    zona.append(n);
  };

  formPregunta.addEventListener("submit", async (e) => {
    e.preventDefault();
    const pregunta = area.value.trim();
    if (!pregunta) return;
    const comparar = formPregunta.comparar.checked;
    const boton = formPregunta.querySelector("button[type=submit]");
    boton.disabled = true;
    cargando(zona, "Pensando… Buscando en la base de datos y redactando la respuesta. La primera pregunta puede tardar hasta un minuto.");
    try {
      const r = await pedir("/api/preguntar", { pregunta, comparar });
      zona.replaceChildren();
      pintar("Respuesta con los datos de LaLigaDB", r.rag, false);
      if (r.solo) pintar("IA sin consultar la base de datos", r.solo, true);
    } catch (error) {
      mostrarError(zona, error.message);
    } finally {
      boton.disabled = false;
    }
  });
}

// ---------- Admin: formulario de gol ----------
const formGol = document.querySelector("[data-formulario-gol]");
if (formGol) {
  const equipo = formGol.equipo, tipo = formGol.tipo, jugador = formGol.jugador;
  const filtrar = () => {
    // Gol normal o de penalti: jugadores del equipo que marca. En propia puerta: los del rival.
    const propia = tipo.value === "PropiaPuerta";
    for (const o of jugador.options) {
      if (!o.dataset.equipo) continue;
      const delEquipo = o.dataset.equipo === equipo.value;
      o.hidden = propia ? delEquipo : !delEquipo;
    }
    if (jugador.selectedOptions[0]?.hidden) jugador.value = "";
  };
  equipo.addEventListener("change", filtrar);
  tipo.addEventListener("change", filtrar);
  filtrar();
}
