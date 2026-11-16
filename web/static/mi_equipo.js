// Goalmetry - «Mi equipo»: se recuerda en este navegador y descarga una imagen con datos reales.
// La imagen se dibuja directamente en un canvas: sin librerías y sin relajar la CSP.
"use strict";

const zonaMiEquipo = document.querySelector("[data-mi-equipo]");
if (zonaMiEquipo) {
  const CLAVE = "goalmetry_mi_equipo";
  const COLOR = { noche: "#0B3D2B", verde: "#0F5C3F", claro: "#E7F3ED", amarillo: "#F2B705", blanco: "#FFFFFF", texto: "#1B2733", gris: "#5A6A78" };
  const FUENTE = '"Segoe UI", system-ui, -apple-system, Arial, sans-serif';
  const selector = zonaMiEquipo.querySelector("select");
  const resumen = zonaMiEquipo.querySelector("[data-resumen]");
  const error = zonaMiEquipo.querySelector("[data-error]");
  let datos = null;

  // El navegador puede tener el almacenamiento bloqueado: entonces solo no se recuerda.
  const leer = () => { try { return localStorage.getItem(CLAVE); } catch { return null; } };
  const guardar = (v) => {
    try { if (v) localStorage.setItem(CLAVE, v); else localStorage.removeItem(CLAVE); } catch { /* sin memoria */ }
  };

  const fraseUltimo = (u) => `Jornada ${u.jornada}: ${u.local ? "en casa" : "fuera"} contra ${u.rival}, ${u.gf}-${u.gc} (${u.resultado.toLowerCase()})`;

  const marcarFila = (id) => {
    document.querySelectorAll(".fila-mi-equipo").forEach((f) => f.classList.remove("fila-mi-equipo"));
    if (id) document.querySelector(`tr[data-equipo-id="${id}"]`)?.classList.add("fila-mi-equipo");
  };

  const pintar = () => {
    zonaMiEquipo.querySelector("[data-nombre]").textContent = datos.equipo;
    zonaMiEquipo.querySelector("[data-ficha]").href = `/equipo/${datos.id}`;
    zonaMiEquipo.querySelector("[data-puesto]").textContent =
      `${datos.posicion}º con ${datos.pts} puntos · ${datos.g} ganados, ${datos.e} empatados y ${datos.p} perdidos · ${datos.gf} goles a favor y ${datos.gc} en contra`;
    zonaMiEquipo.querySelector("[data-ultimo]").textContent = datos.ultimo ? fraseUltimo(datos.ultimo) : "Todavía no ha jugado ningún partido.";
    zonaMiEquipo.querySelector("[data-descargar='partido']").disabled = !datos.ultimo;
    resumen.classList.remove("oculto");
  };

  const cargar = async (id) => {
    error.classList.add("oculto");
    resumen.classList.add("oculto");
    marcarFila(id);
    datos = null;
    if (!id) return;
    try {
      const r = await fetch(urlApi(`/api/mi-equipo/${encodeURIComponent(id)}`));   // urlApi: app.js
      if (!r.ok) throw new Error();
      datos = await r.json();
      pintar();
    } catch {
      error.textContent = "No se han podido cargar los datos de tu equipo.";
      error.classList.remove("oculto");
    }
  };

  // ---------- Imagen ----------
  const lienzo = (alto) => {
    const c = document.createElement("canvas");
    c.width = 1080;
    c.height = alto;
    const g = c.getContext("2d");
    g.fillStyle = COLOR.noche;
    g.fillRect(0, 0, 1080, alto);
    g.fillStyle = COLOR.amarillo;
    g.fillRect(0, 150, 1080, 6);
    g.textBaseline = "alphabetic";
    g.font = `700 54px ${FUENTE}`;
    g.fillStyle = COLOR.blanco;
    g.fillText("Goal", 60, 96);
    const anchoGoal = g.measureText("Goal").width;
    g.fillStyle = COLOR.amarillo;
    g.fillText("metry", 60 + anchoGoal, 96);
    return { c, g };
  };

  // Recorta el texto con «…» si no cabe: los nombres largos no deben salirse de la imagen.
  const ajustar = (g, texto, ancho) => {
    if (g.measureText(texto).width <= ancho) return texto;
    let t = texto;
    while (t.length > 1 && g.measureText(`${t}…`).width > ancho) t = t.slice(0, -1);
    return `${t}…`;
  };

  const piePagina = (g, alto) => {
    g.font = `400 26px ${FUENTE}`;
    g.fillStyle = "#BFD6CA";
    g.textAlign = "left";
    g.fillText(`Datos reales · LaLiga, hasta la jornada ${datos.jornada}`, 60, alto - 50);
  };

  const imagenPartido = () => {
    const u = datos.ultimo;
    const { c, g } = lienzo(1080);
    const local = u.local ? datos.equipo : u.rival, visitante = u.local ? u.rival : datos.equipo;
    const gl = u.local ? u.gf : u.gc, gv = u.local ? u.gc : u.gf;
    g.textAlign = "center";
    g.fillStyle = "#BFD6CA";
    g.font = `600 38px ${FUENTE}`;
    g.fillText(`Jornada ${u.jornada} · ${u.fecha}`, 540, 250);
    g.fillStyle = COLOR.blanco;
    g.font = `700 58px ${FUENTE}`;
    g.fillText(ajustar(g, local, 960), 540, 380);
    g.fillStyle = COLOR.amarillo;
    g.font = `800 190px ${FUENTE}`;
    g.fillText(`${gl} - ${gv}`, 540, 590);
    g.fillStyle = COLOR.blanco;
    g.font = `700 58px ${FUENTE}`;
    g.fillText(ajustar(g, visitante, 960), 540, 700);
    g.fillStyle = COLOR.claro;
    g.font = `400 36px ${FUENTE}`;
    g.fillText(ajustar(g, `${datos.equipo}: ${datos.posicion}º con ${datos.pts} puntos`, 960), 540, 840);
    piePagina(g, 1080);
    return c;
  };

  const imagenClasificacion = () => {
    const filas = datos.clasificacion;
    const alto = 240 + filas.length * 56 + 90;
    const { c, g } = lienzo(alto);
    g.font = `600 26px ${FUENTE}`;
    g.fillStyle = "#BFD6CA";
    g.textAlign = "right";
    g.fillText("PJ", 840, 205);
    g.fillText("DG", 930, 205);
    g.fillText("Pts", 1020, 205);
    filas.forEach((f, i) => {
      const y = 260 + i * 56, mio = f.id === datos.id;
      if (mio) {
        g.fillStyle = COLOR.amarillo;
        g.fillRect(40, y - 40, 1000, 54);
      }
      g.fillStyle = mio ? COLOR.noche : COLOR.blanco;
      g.font = `${mio ? 700 : 400} 32px ${FUENTE}`;
      g.textAlign = "right";
      g.fillText(f.pos, 110, y);
      g.textAlign = "left";
      g.fillText(ajustar(g, f.equipo, 640), 140, y);
      g.textAlign = "right";
      g.fillText(f.pj, 840, y);
      g.fillText(f.dg > 0 ? `+${f.dg}` : f.dg, 930, y);
      g.font = `700 32px ${FUENTE}`;
      g.fillText(f.pts, 1020, y);
    });
    piePagina(g, alto);
    return c;
  };

  const descargar = async (tipo) => {
    if (!datos) return;
    if (document.fonts?.ready) await document.fonts.ready;
    const c = tipo === "partido" ? imagenPartido() : imagenClasificacion();
    c.toBlob((blob) => {
      if (!blob) return;
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = tipo === "partido" ? `goalmetry-jornada-${datos.ultimo.jornada}.png` : `goalmetry-clasificacion-j${datos.jornada}.png`;
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    }, "image/png");
  };

  zonaMiEquipo.querySelectorAll("[data-descargar]").forEach((b) =>
    b.addEventListener("click", () => descargar(b.dataset.descargar)));
  selector.addEventListener("change", () => { guardar(selector.value); cargar(selector.value); });

  const guardado = leer();
  if (guardado && [...selector.options].some((o) => o.value === guardado)) {
    selector.value = guardado;
    cargar(guardado);
  }
}
