// Goalmetry - comportamiento de las páginas (sin librerías externas).
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
    const cob = n.querySelector("[data-cobertura]");
    cob.textContent = r.cobertura.texto;
    cob.classList.add(`cobertura-${r.cobertura.nivel}`);
    if (r.cifras_sin_respaldo.length) {
      const av = n.querySelector("[data-cifras]");
      av.textContent = `Revisa esta respuesta: ${r.cifras_sin_respaldo.join(", ")} no aparece en los datos usados.`;
      av.classList.remove("oculto");
    }
    const usados = n.querySelector(".datos-usados");
    if (r.datos.oficiales || r.datos.documentos) {
      for (const [clave, campo] of [["oficiales", "oficiales"], ["documentos", "documentos"]]) {
        if (r.datos[campo]) n.querySelector(`[data-${clave}]`).textContent = r.datos[campo];
        else { n.querySelector(`[data-${clave}]`).remove(); n.querySelector(`[data-${clave}-titulo]`).remove(); }
      }
    } else {
      usados.remove();
    }
    zona.append(n);
  };

  // Barras enfrentadas de dos equipos: una fila por dato, cada una a escala de su máximo.
  const graficoPares = (columnas, filas) => {
    const NS = "http://www.w3.org/2000/svg";
    const el = (tag, attrs, texto) => {
      const x = document.createElementNS(NS, tag);
      for (const [k, v] of Object.entries(attrs)) x.setAttribute(k, v);
      if (texto !== undefined) x.textContent = texto;
      return x;
    };
    const alto = 26, ancho = 520, centro = ancho / 2, media = 150;
    const svg = el("svg", { viewBox: `0 0 ${ancho} ${alto * filas.length + 26}`, class: "pares", role: "img",
                            "aria-label": `Comparación entre ${columnas[1]} y ${columnas[2]}` });
    svg.append(el("text", { x: centro - 60, y: 14, "text-anchor": "end", class: "pares-cab" }, columnas[1]));
    svg.append(el("text", { x: centro + 60, y: 14, "text-anchor": "start", class: "pares-cab" }, columnas[2]));
    filas.forEach(([dato, a, b], i) => {
      const y = 24 + i * alto, max = Math.max(a, b, 1);
      const la = (media * a) / max, lb = (media * b) / max;
      svg.append(el("rect", { x: centro - 60 - la, y, width: la, height: 16, class: "pares-a" }));
      svg.append(el("rect", { x: centro + 60, y, width: lb, height: 16, class: "pares-b" }));
      svg.append(el("text", { x: centro, y: y + 12, "text-anchor": "middle", class: "pares-dato" }, dato));
      svg.append(el("text", { x: centro - 66 - la, y: y + 12, "text-anchor": "end", class: "pares-num" }, a));
      svg.append(el("text", { x: centro + 66 + lb, y: y + 12, "text-anchor": "start", class: "pares-num" }, b));
    });
    return svg;
  };

  const pintarTarjeta = (t, pregunta) => {
    const n = document.getElementById("plantilla-tarjeta").content.cloneNode(true);
    n.querySelector("[data-titulo]").textContent = t.titulo;
    n.querySelector("[data-texto]").textContent = t.texto;
    const cab = n.querySelector("thead tr");
    t.columnas.forEach((c, i) => {
      const th = document.createElement("th");
      th.textContent = c;
      if (typeof t.filas[0][i] === "number") th.className = "num";
      cab.append(th);
    });
    const cuerpo = n.querySelector("tbody");
    for (const fila of t.filas) {
      const tr = document.createElement("tr");
      for (const v of fila) {
        const td = document.createElement("td");
        td.textContent = v;
        if (typeof v === "number") td.className = "num";
        tr.append(td);
      }
      cuerpo.append(tr);
    }
    if (t.grafico === "pares") n.querySelector("[data-grafico]").append(graficoPares(t.columnas, t.filas));
    if (t.enlace) {
      const a = n.querySelector("[data-enlace]");
      a.href = t.enlace;
      a.classList.remove("oculto");
    }
    n.querySelector("[data-a-la-ia]").addEventListener("click", () => enviar(pregunta, false, true));
    zona.append(n);
  };

  const enviar = async (pregunta, comparar, rag) => {
    const boton = formPregunta.querySelector("button[type=submit]");
    boton.disabled = true;
    cargando(zona, "Pensando… Buscando en la base de datos y redactando la respuesta. La primera pregunta puede tardar hasta un minuto.");
    try {
      const r = await pedir("/api/preguntar", { pregunta, comparar, rag });
      zona.replaceChildren();
      if (r.tarjeta) { pintarTarjeta(r.tarjeta, pregunta); return; }
      pintar("Respuesta con los datos de la liga", r.rag, false);
      if (r.solo) pintar("IA sin consultar la base de datos", r.solo, true);
    } catch (error) {
      mostrarError(zona, error.message);
    } finally {
      boton.disabled = false;
    }
  };

  formPregunta.addEventListener("submit", (e) => {
    e.preventDefault();
    const pregunta = area.value.trim();
    if (pregunta) enviar(pregunta, formPregunta.comparar.checked, false);
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

// ---------- Predicciones ----------
const paginaPred = document.querySelector("[data-predicciones]");
if (paginaPred) {
  const $ = (s) => paginaPred.querySelector(s);
  const pct = (v) => `${v.toLocaleString("es-ES", { minimumFractionDigits: 1, maximumFractionDigits: 1 })} %`;
  const celda = (fila, texto, clase) => {
    const td = fila.insertCell();
    td.textContent = texto;
    if (clase) td.className = clase;
    return td;
  };
  let resultado = null, curiosidades = [], iCuriosidad = 0, relojCuriosidad = null, relojEstado = null, condiciones = [];

  // --- Tabla: una fila por puesto; al pulsar, todos los candidatos a ese puesto ---
  function pintarTabla(tabla) {
    const cuerpo = $("[data-tabla]");
    cuerpo.replaceChildren();
    for (const f of tabla) {
      const tr = cuerpo.insertRow();
      tr.className = `fila-puesto ${f.puesto <= 4 ? "zona-champions" : f.puesto <= 6 ? "zona-europa" : f.puesto >= 18 ? "zona-descenso" : ""}`;
      tr.tabIndex = 0;
      tr.setAttribute("aria-expanded", "false");
      celda(tr, f.puesto, "num");
      celda(tr, f.equipo, "equipo");
      const opcion = tr.insertCell();
      const caja = document.createElement("div");
      caja.className = "opcion";
      const barra = document.createElement("div");
      barra.className = "barra";
      const relleno = document.createElement("span");
      relleno.style.width = `${f.prob}%`;
      barra.append(relleno);
      const valor = document.createElement("b");
      valor.textContent = pct(f.prob);
      caja.append(valor, barra);
      opcion.append(caja);
      celda(tr, f.puntos.toLocaleString("es-ES", { maximumFractionDigits: 1 }), "num puntos");
      celda(tr, pct(f.campeon), "num");
      celda(tr, pct(f.top4), "num ocultar-movil");
      celda(tr, pct(f.top6), "num ocultar-movil");
      celda(tr, pct(f.descenso), "num");

      const detalle = cuerpo.insertRow();
      detalle.hidden = true;
      const td = detalle.insertCell();
      td.colSpan = 8;
      const lista = document.createElement("ul");
      lista.className = "candidatos";
      for (const c of f.candidatos) {
        const li = document.createElement("li");
        const n = document.createElement("span"), p = document.createElement("span");
        n.textContent = c.equipo;
        p.textContent = pct(c.prob);
        li.append(n, p);
        lista.append(li);
      }
      td.append(lista);
      const alternar = () => {
        detalle.hidden = !detalle.hidden;
        tr.setAttribute("aria-expanded", String(!detalle.hidden));
      };
      tr.addEventListener("click", alternar);
      tr.addEventListener("keydown", (e) => {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); alternar(); }
      });
    }
  }

  // --- ¿Y si...? ---
  const nombreEquipo = (id) => resultado.equiposPorId[id];
  function rellenarVisitantes() {
    const local = Number($("[data-ysi-local]").value);
    const sel = $("[data-ysi-visitante]");
    sel.replaceChildren();
    resultado.pendientes.filter((p) => p.LocalID === local)
      .map((p) => p.VisitanteID)
      .sort((a, b) => nombreEquipo(a).localeCompare(nombreEquipo(b), "es"))
      .forEach((id) => sel.add(new Option(nombreEquipo(id), id)));
  }
  async function aplicarYSi() {
    const lista = $("[data-ysi-lista]"), nota = $("[data-ysi-nota]");
    lista.replaceChildren();
    for (const [i, c] of condiciones.entries()) {
      const li = document.createElement("li");
      const texto = c.S === "1" ? `gana ${nombreEquipo(c.L)}` : c.S === "2" ? `gana ${nombreEquipo(c.V)}` : "empate";
      li.append(`${nombreEquipo(c.L)} - ${nombreEquipo(c.V)}: ${texto}`);
      const quitar = document.createElement("button");
      quitar.type = "button";
      quitar.textContent = "×";
      quitar.setAttribute("aria-label", "Quitar este resultado");
      quitar.addEventListener("click", () => { condiciones.splice(i, 1); aplicarYSi(); });
      li.append(quitar);
      lista.append(li);
    }
    $("[data-ysi-anadir]").disabled = condiciones.length >= 3;
    const titulo = $("[data-titulo-tabla]");
    if (!condiciones.length) {
      titulo.textContent = "Clasificación prevista";
      nota.textContent = "";
      pintarTabla(resultado.tabla);
      return;
    }
    try {
      const r = await pedir("/api/predicciones/ysi", { condiciones });
      if (!r.temporadas) {
        nota.textContent = "Esa combinación no ha salido en ninguna temporada simulada. Prueba con otra.";
        return;
      }
      titulo.textContent = "Clasificación prevista si pasa eso";
      const margen = (98 / Math.sqrt(r.temporadas)).toLocaleString("es-ES", { maximumFractionDigits: 1 });
      nota.textContent = `Se ha dado en ${r.temporadas.toLocaleString("es-ES")} de ${resultado.temporadas.toLocaleString("es-ES")} temporadas simuladas. Margen de error: hasta ±${margen} puntos porcentuales.`
        + (r.temporadas < 200 ? " Son pocas temporadas: tómalo con cautela." : "");
      pintarTabla(r.tabla);
    } catch (error) {
      nota.textContent = error.message;
    }
  }

  // --- Evolución: el equipo elegido, resaltado; el resto, de contexto en gris ---
  function pintarEvolucion() {
    const medida = $("[data-evo-medida]").value, equipo = Number($("[data-evo-equipo]").value);
    const puntos = resultado.evolucion;
    const jornadas = [...new Set(puntos.map((p) => p.j))].sort((a, b) => a - b);
    const caja = $("[data-evo-grafico]");
    caja.replaceChildren();
    const A = 760, H = 300, mI = 44, mD = 150, mS = 14, mB = 30;
    const x = (j) => jornadas.length > 1 ? mI + (A - mI - mD) * jornadas.indexOf(j) / (jornadas.length - 1) : mI;
    const y = (v) => mS + (H - mS - mB) * (1 - v / 100);
    const NS = "http://www.w3.org/2000/svg";
    const el = (tag, attrs, texto) => {
      const n = document.createElementNS(NS, tag);
      Object.entries(attrs).forEach(([k, v]) => n.setAttribute(k, v));
      if (texto !== undefined) n.textContent = texto;
      return n;
    };
    const nombreMedida = $("[data-evo-medida]").selectedOptions[0].textContent;
    const svg = el("svg", { viewBox: `0 0 ${A} ${H}`, role: "img",
      "aria-label": `Opciones de ${nombreEquipo(equipo)} (${nombreMedida}) tras cada jornada` });
    for (const v of [0, 25, 50, 75, 100]) {
      svg.append(el("line", { class: "rejilla", x1: mI, x2: A - mD, y1: y(v), y2: y(v) }));
      svg.append(el("text", { x: mI - 8, y: y(v) + 4, "text-anchor": "end" }, `${v} %`));
    }
    for (const j of jornadas) svg.append(el("text", { x: x(j), y: H - 8, "text-anchor": "middle" }, `J${j}`));
    const linea = (id) => puntos.filter((p) => p.e === id).sort((a, b) => a.j - b.j)
      .map((p, i) => `${i ? "L" : "M"}${x(p.j).toFixed(1)} ${y(p[medida]).toFixed(1)}`).join(" ");
    for (const id of new Set(puntos.map((p) => p.e))) {
      if (id !== equipo) svg.append(el("path", { class: "contexto", d: linea(id) }));
    }
    svg.append(el("path", { class: "serie", d: linea(equipo) }));
    const delEquipo = puntos.filter((p) => p.e === equipo).sort((a, b) => a.j - b.j);
    const ultimo = delEquipo[delEquipo.length - 1];
    if (ultimo) {
      svg.append(el("circle", { class: "punto", cx: x(ultimo.j), cy: y(ultimo[medida]), r: 5 }));
      const yEtiqueta = Math.max(mS + 10, Math.min(H - mB - 10, y(ultimo[medida]) + 4));
      svg.append(el("text", { class: "rotulo", x: x(ultimo.j) + 10, y: yEtiqueta },
        `${nombreEquipo(equipo).slice(0, 15)} ${pct(ultimo[medida])}`));
    }
    const guia = el("line", { class: "guia oculto", y1: mS, y2: H - mB });
    const marca = el("circle", { class: "punto oculto", r: 5 });
    svg.append(guia, marca);
    caja.append(svg);
    const ayuda = document.createElement("div");
    ayuda.className = "grafico-ayuda oculto";
    caja.append(ayuda);
    svg.addEventListener("pointermove", (e) => {
      const r = svg.getBoundingClientRect();
      const px = (e.clientX - r.left) * A / r.width;
      const cerca = jornadas.reduce((m, j) => Math.abs(x(j) - px) < Math.abs(x(m) - px) ? j : m, jornadas[0]);
      const p = delEquipo.find((d) => d.j === cerca);
      if (!p) return;
      guia.setAttribute("x1", x(cerca)); guia.setAttribute("x2", x(cerca));
      marca.setAttribute("cx", x(cerca)); marca.setAttribute("cy", y(p[medida]));
      guia.classList.remove("oculto"); marca.classList.remove("oculto"); ayuda.classList.remove("oculto");
      ayuda.textContent = `Tras la J${cerca}: ${pct(p[medida])}`;
      ayuda.style.left = `${x(cerca) * r.width / A}px`;
      ayuda.style.top = `${y(p[medida]) * r.height / H}px`;
    });
    svg.addEventListener("pointerleave", () => {
      guia.classList.add("oculto"); marca.classList.add("oculto"); ayuda.classList.add("oculto");
    });

    const tabla = $("[data-evo-tabla]");
    tabla.replaceChildren();
    const cab = tabla.createTHead().insertRow();
    for (const t of ["Tras la jornada", nombreMedida]) { const th = document.createElement("th"); th.textContent = t; cab.append(th); }
    const cuerpo = tabla.createTBody();
    for (const p of delEquipo) { const f = cuerpo.insertRow(); celda(f, `J${p.j}`); celda(f, pct(p[medida])); }
  }

  // --- Pantalla de carga ---
  function siguienteCuriosidad() {
    if (!curiosidades.length) return;
    $("[data-curiosidad]").textContent = curiosidades[iCuriosidad % curiosidades.length];
    iCuriosidad += 1;
  }
  async function vigilar() {
    try {
      const e = await pedir("/api/predicciones/estado");
      if (e.error) { terminarCarga(); mostrarAviso(e.error); return; }
      if (!e.simulando) { terminarCarga(); cargar(); return; }
      const paso = e.paso;
      if (paso) {
        const hecho = paso.temporadas ? Math.round(100 * paso.hechas / paso.temporadas) : 0;
        $("[data-carga-paso]").textContent = paso.tipo === "Principal"
          ? `${paso.hechas.toLocaleString("es-ES")} de ${paso.temporadas.toLocaleString("es-ES")} temporadas`
          : `Calculando cómo iba la liga tras la jornada ${paso.jornada}`;
        $("[data-carga-barra] span").style.width = `${hecho}%`;
        $("[data-carga-barra]").setAttribute("aria-valuenow", hecho);
        $("[data-carga-lider]").textContent = e.lider
          ? `De momento, ${e.lider.equipo} es campeón en el ${pct(e.lider.pct)} de las temporadas.` : "";
      }
    } catch { /* un fallo puntual de red: se reintenta en el siguiente ciclo */ }
  }
  function terminarCarga() {
    clearInterval(relojCuriosidad); clearInterval(relojEstado);
    $("[data-carga]").classList.add("oculto");
  }
  async function empezarCarga() {
    $("[data-vacio]").classList.add("oculto");
    $("[data-contenido]").classList.add("oculto");
    $("[data-desfasado]").classList.add("oculto");
    $("[data-simular]").classList.add("oculto");
    $("[data-carga]").classList.remove("oculto");
    if (!curiosidades.length) {
      try {
        curiosidades = (await pedir("/api/predicciones/curiosidades")).curiosidades.sort(() => Math.random() - 0.5);
      } catch { curiosidades = []; }
    }
    siguienteCuriosidad();
    clearInterval(relojCuriosidad); clearInterval(relojEstado);
    relojCuriosidad = setInterval(siguienteCuriosidad, 5000);
    relojEstado = setInterval(vigilar, 800);
  }
  function mostrarAviso(mensaje) {
    const a = $("[data-error]");
    a.textContent = mensaje;
    a.classList.remove("oculto");
    $("[data-simular]").classList.remove("oculto");
  }

  $("[data-simular]").addEventListener("click", async () => {
    $("[data-error]").classList.add("oculto");
    try {
      await pedir("/api/predicciones/simular", {});
      condiciones = [];
      empezarCarga();
    } catch (error) {
      mostrarAviso(error.message);
    }
  });
  $("[data-ysi-local]").addEventListener("change", rellenarVisitantes);
  $("[data-ysi-anadir]").addEventListener("click", () => {
    const c = { L: Number($("[data-ysi-local]").value), V: Number($("[data-ysi-visitante]").value), S: $("[data-ysi-signo]").value };
    if (!c.V || condiciones.some((o) => o.L === c.L && o.V === c.V)) return;
    condiciones.push(c);
    aplicarYSi();
  });
  $("[data-evo-medida]").addEventListener("change", pintarEvolucion);
  $("[data-evo-equipo]").addEventListener("change", pintarEvolucion);

  async function cargar() {
    try {
      const d = await pedir("/api/predicciones");
      if (d.simulando) { empezarCarga(); return; }
      const boton = $("[data-simular]");
      boton.classList.remove("oculto");
      if (!d.resultado) {
        $("[data-vacio]").classList.remove("oculto");
        return;
      }
      resultado = d.resultado;
      resultado.equiposPorId = Object.fromEntries(d.equipos.map((e) => [e.EquipoID, e.Nombre]));
      boton.textContent = "Volver a simular";
      $("[data-meta]").textContent = `${resultado.temporadas.toLocaleString("es-ES")} temporadas simuladas con los partidos jugados hasta la jornada ${resultado.hastaJornada} · ${resultado.fecha}`;
      $("[data-desfasado]").classList.toggle("oculto", resultado.alDia);
      $("[data-contenido]").classList.remove("oculto");

      const locales = [...new Set(resultado.pendientes.map((p) => p.LocalID))]
        .sort((a, b) => nombreEquipo(a).localeCompare(nombreEquipo(b), "es"));
      const selLocal = $("[data-ysi-local]");
      selLocal.replaceChildren(...locales.map((id) => new Option(nombreEquipo(id), id)));
      rellenarVisitantes();
      const selEquipo = $("[data-evo-equipo]");
      selEquipo.replaceChildren(...d.equipos.map((e) => new Option(e.Nombre, e.EquipoID)));
      selEquipo.value = resultado.tabla[0].equipoId;
      pintarEvolucion();
      aplicarYSi();
    } catch (error) {
      mostrarAviso(error.message);
    }
  }
  cargar();
}
