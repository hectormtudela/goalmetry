"""Goalmetry - aplicación web.

Arranque:  iniciar-web.bat (doble clic)  o  .venv\\Scripts\\python app.py
Abre http://localhost:8080. Solo escucha en este ordenador (127.0.0.1).
"""
import json
import os
import re
import secrets
import socket
import sys
import threading
import time
import webbrowser
from datetime import datetime, timedelta
from functools import wraps
from pathlib import Path

from flask import (Flask, abort, flash, jsonify, redirect, render_template, request,
                   session, url_for)
from werkzeug.security import check_password_hash

from db import ErrorDatos, consultar, filas

CARPETA = Path(__file__).resolve().parent
NOMBRE_APP = "Goalmetry"


# ---------------------------------------------------------------- configuración
def cargar_env():
    """Lee web/.env (ignorado por git). Si no hay clave de sesión, la genera."""
    ruta = CARPETA / ".env"
    if ruta.exists():
        for linea in ruta.read_text(encoding="utf-8").splitlines():
            if "=" in linea and not linea.lstrip().startswith("#"):
                clave, valor = linea.split("=", 1)
                os.environ.setdefault(clave.strip(), valor.strip())
    if not os.environ.get("LALIGADB_SECRET"):
        nueva = secrets.token_hex(32)
        with ruta.open("a", encoding="utf-8") as f:
            f.write(f"# Clave para firmar las sesiones. Generada automáticamente; no la compartas.\n"
                    f"LALIGADB_SECRET={nueva}\n")
        os.environ["LALIGADB_SECRET"] = nueva


cargar_env()
app = Flask(__name__)
app.config.update(
    SECRET_KEY=os.environ["LALIGADB_SECRET"],
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.environ.get("LALIGADB_HTTPS") == "1",  # activar al publicarla con HTTPS
    PERMANENT_SESSION_LIFETIME=timedelta(hours=2),
    MAX_CONTENT_LENGTH=64 * 1024,
)


# ------------------------------------------------------------------- seguridad
@app.before_request
def comprobar_csrf():
    if request.method == "POST":
        enviado = request.form.get("csrf") or request.headers.get("X-CSRF-Token")
        if not enviado or not secrets.compare_digest(enviado, session.get("csrf", "")):
            abort(400, "La página ha caducado. Recárgala e inténtalo de nuevo.")


@app.after_request
def cabeceras(respuesta):
    respuesta.headers["Content-Security-Policy"] = (
        "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; "
        "frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
    respuesta.headers["X-Content-Type-Options"] = "nosniff"
    respuesta.headers["Referrer-Policy"] = "same-origin"
    return respuesta


@app.context_processor
def comunes():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(32)
    return {"csrf_token": session["csrf"], "app_nombre": NOMBRE_APP, "admin": session.get("admin")}


class Limitador:
    """Límite sencillo en memoria: como mucho `maximo` usos por IP cada `segundos`."""

    def __init__(self, maximo, segundos):
        self.maximo, self.segundos, self.usos, self.cerrojo = maximo, segundos, {}, threading.Lock()

    def permitir(self, clave):
        ahora = time.monotonic()
        with self.cerrojo:
            recientes = [t for t in self.usos.get(clave, []) if ahora - t < self.segundos]
            if len(recientes) >= self.maximo:
                self.usos[clave] = recientes
                return False
            self.usos[clave] = recientes + [ahora]
            return True


limite_login = Limitador(10, 15 * 60)
limite_ia = Limitador(8, 60)
modelo_ocupado = threading.Semaphore(1)  # el modelo local atiende una pregunta cada vez


def solo_admin(vista):
    @wraps(vista)
    def envoltura(*args, **kwargs):
        if not session.get("admin"):
            return redirect(url_for("entrar", siguiente=request.path))
        return vista(*args, **kwargs)
    return envoltura


# ------------------------------------------------------------------ utilidades
def jornadas():
    return filas("""SELECT j.JornadaID, j.Numero,
                           COUNT(p.PartidoID) AS Partidos,
                           SUM(CASE WHEN p.Estado = 'Finalizado' THEN 1 ELSE 0 END) AS Finalizados
                    FROM liga.Jornada AS j LEFT JOIN liga.Partido AS p ON p.JornadaID = j.JornadaID
                    GROUP BY j.JornadaID, j.Numero ORDER BY j.Numero""")


def puerto_abierto(puerto):
    try:
        with socket.create_connection(("127.0.0.1", puerto), timeout=0.5):
            return True
    except OSError:
        return False


def entero(valor, defecto=None):
    try:
        return int(valor)
    except (TypeError, ValueError):
        return defecto


@app.errorhandler(ErrorDatos)
def error_datos(error):
    if request.path.startswith("/api/"):
        return jsonify(error=str(error)), 400
    return render_template("error.html", mensaje=str(error)), 500


@app.errorhandler(400)
def error_400(error):
    return render_template("error.html", mensaje=error.description), 400


@app.errorhandler(404)
def error_404(error):
    return render_template("error.html", mensaje="Esta página no existe."), 404


# ------------------------------------------------------------- páginas públicas
@app.get("/")
def clasificacion():
    lista = jornadas()
    jugadas = [j["Numero"] for j in lista if j["Finalizados"]]
    hasta = entero(request.args.get("hasta"))
    if hasta and hasta in jugadas:
        tabla = filas("EXEC liga.usp_ClasificacionHastaJornada @HastaJornada = ?", (hasta,))
    else:
        hasta = None
        tabla = filas("SELECT * FROM liga.vw_Clasificacion ORDER BY Posicion, Equipo")
    goleadores = filas("""SELECT TOP (15) Posicion, Anotador, Equipo, Goles, Penaltis
                          FROM liga.vw_MaximosGoleadores ORDER BY Posicion, Anotador""")
    resumen = filas("""SELECT (SELECT COUNT(*) FROM liga.Partido WHERE Estado = 'Finalizado') AS Jugados,
                              (SELECT COUNT(*) FROM liga.Partido WHERE Estado = 'Programado') AS Pendientes,
                              (SELECT COUNT(*) FROM liga.Gol) AS Goles,
                              (SELECT Nombre FROM liga.Temporada
                               WHERE TemporadaID = (SELECT MAX(TemporadaID) FROM liga.Temporada)) AS Temporada""")[0]
    ids = {e["Nombre"]: e["EquipoID"] for e in filas("SELECT EquipoID, Nombre FROM liga.Equipo")}
    datos_curiosos = filas("""SELECT TOP (3) Titulo, Texto FROM analisis.Curiosidad
                               WHERE Categoria <> 'Simulacion' ORDER BY NEWID()""")
    return render_template("clasificacion.html", tabla=tabla, goleadores=goleadores, jugadas=jugadas,
                           hasta=hasta, resumen=resumen, ids=ids, curiosidades=datos_curiosos)


SQL_PARTIDOS = """
SELECT p.PartidoID, p.FechaHora, p.Estado, p.GolesLocal, p.GolesVisitante,
       p.EquipoLocalID, p.EquipoVisitanteID,
       el.Nombre AS Local, ev.Nombre AS Visitante, es.Nombre AS Estadio, a.Nombre AS Arbitro
FROM liga.Partido AS p
JOIN liga.Jornada AS j  ON j.JornadaID  = p.JornadaID
JOIN liga.Equipo  AS el ON el.EquipoID  = p.EquipoLocalID
JOIN liga.Equipo  AS ev ON ev.EquipoID  = p.EquipoVisitanteID
JOIN liga.Estadio AS es ON es.EstadioID = p.EstadioID
LEFT JOIN liga.Arbitro AS a ON a.ArbitroID = p.ArbitroPrincipalID
WHERE j.JornadaID = ?
ORDER BY CASE WHEN p.FechaHora IS NULL THEN 1 ELSE 0 END, p.FechaHora, p.PartidoID;
SELECT g.GolID, g.PartidoID, g.EquipoID, g.Anotador, g.Minuto, g.Tipo
FROM liga.Gol AS g JOIN liga.Partido AS p ON p.PartidoID = g.PartidoID
WHERE p.JornadaID = ?
ORDER BY g.Minuto, g.GolID;
"""


def partidos_de(jornada_id, usuario="web_publico"):
    partidos, goles = consultar(SQL_PARTIDOS, (jornada_id, jornada_id), usuario)
    for p in partidos:
        p["Goles"] = [g for g in goles if g["PartidoID"] == p["PartidoID"]]
    return partidos


@app.get("/jornadas")
@app.get("/jornadas/<int:numero>")
def ver_jornadas(numero=None):
    lista = jornadas()
    if not lista:
        return render_template("jornadas.html", lista=[], actual=None, partidos=[])
    if numero is None:  # la última con algún partido jugado
        con_partidos = [j for j in lista if j["Finalizados"]] or lista
        numero = con_partidos[-1]["Numero"]
    actual = next((j for j in lista if j["Numero"] == numero), None)
    if actual is None:
        abort(404)
    return render_template("jornadas.html", lista=lista, actual=actual,
                           partidos=partidos_de(actual["JornadaID"]))


TIPOS_DOCUMENTO = {"": "Todos", "cronica_partido": "Crónicas", "resumen_jornada": "Resúmenes de jornada",
                   "ficha_equipo": "Fichas de equipo", "reglamento": "Reglamento", "faq": "Preguntas frecuentes"}


@app.get("/buscar")
def buscar():
    return render_template("buscar.html", tipos=TIPOS_DOCUMENTO)


@app.get("/preguntar")
def preguntar():
    return render_template("preguntar.html")


@app.get("/api/estado-ia")
def estado_ia():
    return jsonify(ollama=puerto_abierto(11434), proxy=puerto_abierto(11443))


@app.post("/api/buscar")
def api_buscar():
    datos = request.get_json(silent=True) or {}
    consulta = (datos.get("consulta") or "").strip()[:300]
    modo = datos.get("modo") if datos.get("modo") in ("vectorial", "texto", "hibrida") else "hibrida"
    tipo = datos.get("tipo") if datos.get("tipo") in TIPOS_DOCUMENTO and datos.get("tipo") else None
    if not consulta:
        return jsonify(error="Escribe qué quieres buscar."), 400
    if not limite_ia.permitir(request.remote_addr):
        return jsonify(error="Demasiadas búsquedas seguidas. Espera un minuto."), 429
    inicio = time.perf_counter()
    resultados = filas("""
        DECLARE @r TABLE (DocumentoID INT, Tipo VARCHAR(20), Titulo NVARCHAR(150), Puntuacion DECIMAL(9,6),
                          RangoVectorial INT, RangoTexto INT);
        INSERT INTO @r EXEC ia.usp_BuscarDocumentos @Consulta = ?, @Modo = ?, @Top = 8, @Tipo = ?;
        SELECT r.DocumentoID, r.Tipo, r.Titulo, r.Puntuacion, r.RangoVectorial, r.RangoTexto,
               LEFT(d.Texto, 360) AS Extracto, LEN(d.Texto) AS Largo
        FROM @r AS r JOIN ia.Documento AS d ON d.DocumentoID = r.DocumentoID
        ORDER BY r.Puntuacion DESC, r.DocumentoID;""", (consulta, modo, tipo))
    for r in resultados:
        r["Puntuacion"] = float(r["Puntuacion"])
        r["TipoNombre"] = TIPOS_DOCUMENTO.get(r["Tipo"], r["Tipo"])
    return jsonify(resultados=resultados, segundos=round(time.perf_counter() - inicio, 1))


def cobertura(sin_contexto, texto, oficiales, documentos):
    """Cuánto respaldo tiene la respuesta, para decirlo en pantalla sin adornos."""
    if sin_contexto:
        return {"nivel": "ninguna", "texto": "Sin respaldo: esta IA no ha consultado la base de datos."}
    if texto.startswith("No tengo ese dato") or texto.startswith("No tengo datos"):
        return {"nivel": "ninguna", "texto": "Sin datos sobre esto: no se ha podido responder."}
    if oficiales:
        return {"nivel": "alta", "texto": "Ha consultado datos exactos de las tablas de la liga: los tienes en «Datos usados»."}
    if documentos:
        return {"nivel": "media", "texto": "Ha consultado solo documentos (crónicas o reglamento), sin datos exactos de las tablas."}
    return {"nivel": "ninguna", "texto": "Sin respaldo en la base de datos."}


def responder(pregunta, sin_contexto):
    _, documentos, contexto, respuesta = consultar(
        "EXEC ia.usp_PreguntarLiga @Pregunta = ?, @SinContexto = ?, @Mostrar = 1;",
        (pregunta, 1 if sin_contexto else 0))
    fuentes = [{"Titulo": d["Titulo"], "Tipo": TIPOS_DOCUMENTO.get(d["Tipo"], d["Tipo"])} for d in documentos]
    # Lo que SQL pasó de verdad al modelo: documentos y datos exactos de ia.usp_DatosOficiales.
    usado, _, oficiales = (contexto[0]["Contexto"] or "").partition("[Datos oficiales]")
    usado, oficiales = usado.strip(), oficiales.strip()
    if oficiales:
        fuentes.insert(0, {"Titulo": "Datos oficiales de la base de datos", "Tipo": "tablas de la liga"})
    texto = respuesta[0]["Respuesta"] or ""
    # Cifras de la respuesta que no están en lo que se le pasó ni en la pregunta.
    conocidas = set(re.findall(r"\d+", f"{usado} {oficiales} {pregunta}"))
    sin_respaldo = [] if sin_contexto else sorted(set(re.findall(r"\d+", texto)) - conocidas, key=int)
    return {"respuesta": texto, "segundos": round(respuesta[0]["Milisegundos"] / 1000, 1), "fuentes": fuentes,
            "datos": {"oficiales": oficiales, "documentos": usado},
            "cobertura": cobertura(sin_contexto, texto, oficiales, usado), "cifras_sin_respaldo": sin_respaldo}


def tarjeta_de(pregunta):
    """La tarjeta de datos de esta pregunta, o None si debe responder el RAG."""
    try:
        resultados = consultar("EXEC ia.usp_TarjetaPregunta @Pregunta = ?;", (pregunta,))
    except ErrorDatos:
        return None
    cabecera = resultados[0][0]
    if not cabecera["Intencion"] or len(resultados) < 2 or not resultados[1]:
        return None
    columnas = list(resultados[1][0].keys())
    return {"titulo": cabecera["Titulo"], "texto": cabecera["Texto"], "enlace": cabecera["Enlace"], "grafico": cabecera["Grafico"],
            "columnas": columnas, "filas": [[f[c] for c in columnas] for f in resultados[1]]}


@app.post("/api/preguntar")
def api_preguntar():
    datos = request.get_json(silent=True) or {}
    pregunta = (datos.get("pregunta") or "").strip()[:400]
    if not pregunta:
        return jsonify(error="Escribe una pregunta."), 400
    if not limite_ia.permitir(request.remote_addr):
        return jsonify(error="Demasiadas preguntas seguidas. Espera un minuto."), 429
    if not modelo_ocupado.acquire(timeout=120):
        return jsonify(error="La IA está ocupada con otra pregunta. Prueba dentro de un momento."), 503
    try:
        # Sin LLM si la base de datos reconoce la pregunta; datos["rag"] es «Preguntar a la IA» desde la tarjeta.
        if not datos.get("comparar") and not datos.get("rag"):
            tarjeta = tarjeta_de(pregunta)
            if tarjeta:
                return jsonify(tarjeta=tarjeta)
        resultado = {"rag": responder(pregunta, False)}
        if datos.get("comparar"):
            resultado["solo"] = responder(pregunta, True)
        return jsonify(resultado)
    finally:
        modelo_ocupado.release()


# ------------------------------------------------------------------------ análisis
SECCIONES_ANALISIS = [
    ("Rankings por 90 minutos", "/rankings", "Goles y asistencias por 90 minutos, con filtros por posición y minutos."),
    ("Árbitros", "/arbitros", "Partidos dirigidos, goles y victorias locales, junto a la media de la liga."),
    ("Posición jornada a jornada", "/posiciones", "Cómo ha subido y bajado cada equipo en la clasificación."),
    ("Curiosidades y remontadas", "/curiosidades", "Mayor goleada, gol más tardío, rachas y partidos remontados."),
    ("¿Cuánto fiarse de las predicciones?", "/fiabilidad", "Aciertos, Brier y calibración frente a referencias simples."),
    ("Jugadores parecidos", "/parecidos", "Los más cercanos por goles, asistencias y minutos. Similitud estadística."),
    #@@SECCIONES@@
]


@app.get("/analisis")
def analisis():
    return render_template("analisis.html", secciones=SECCIONES_ANALISIS)


@app.get("/rankings")
def rankings():
    posicion = request.args.get("posicion") if request.args.get("posicion") in ("PT", "DF", "MC", "DL") else None
    minutos = max(0, min(4000, entero(request.args.get("minutos"), 360)))
    orden = "minutos" if request.args.get("orden") == "minutos" else "ga"
    jugadores = filas("EXEC analisis.usp_Rankings @Posicion = ?, @MinMinutos = ?, @Orden = ?;", (posicion, minutos, orden))
    return render_template("rankings.html", jugadores=jugadores, posicion=posicion, minutos=minutos, orden=orden)


@app.get("/arbitros")
def arbitros():
    return render_template("arbitros.html", arbitros=filas("SELECT * FROM analisis.vw_Arbitro ORDER BY Partidos DESC, Nombre"))


@app.get("/arbitro/<int:arbitro_id>")
def arbitro(arbitro_id):
    if not filas("SELECT 1 AS Hay FROM liga.Arbitro WHERE ArbitroID = ?", (arbitro_id,)):
        abort(404)
    perfil, media, partidos = consultar("EXEC analisis.usp_PerfilArbitro @ArbitroID = ?;", (arbitro_id,))
    return render_template("arbitro.html", a=perfil[0], m=media[0], partidos=partidos)


@app.get("/posiciones")
def posiciones():
    datos = filas("SELECT Jornada, EquipoID, Nombre, Pts, Posicion, Fila FROM analisis.vw_PosicionJornada ORDER BY EquipoID, Jornada")
    jornadas_vistas = sorted({d["Jornada"] for d in datos})
    ancho, fila, x0, y0, xn = 900, 26, 60, 40, 710
    def x(j):
        return round(x0 + (xn - x0) * jornadas_vistas.index(j) / ((len(jornadas_vistas) - 1) or 1), 1)
    series = {}
    for d in datos:
        s = series.setdefault(d["EquipoID"], {"id": d["EquipoID"], "nombre": d["Nombre"], "puntos": []})
        s["puntos"].append({"x": x(d["Jornada"]), "y": y0 + fila * (d["Fila"] - 1), "j": d["Jornada"], "pos": d["Posicion"], "pts": d["Pts"]})
    for s in series.values():
        s["d"] = " ".join(f"{'M' if i == 0 else 'L'}{p['x']} {p['y']}" for i, p in enumerate(s["puntos"]))
        s["yfin"] = s["puntos"][-1]["y"] if s["puntos"] else y0
    return render_template("posiciones.html", series=list(series.values()), jornadas=jornadas_vistas, ancho=ancho,
                           alto=y0 + fila * 20, fila=fila, x0=x0, y0=y0, xn=xn)


@app.get("/curiosidades")
def curiosidades():
    datos = filas("SELECT Titulo, Texto FROM analisis.Curiosidad WHERE Categoria <> 'Simulacion' ORDER BY CuriosidadID")
    remontadas = filas("SELECT Titulo, MaxDesventaja FROM analisis.Remontada ORDER BY MaxDesventaja DESC, Jornada DESC")
    return render_template("curiosidades.html", curiosidades=datos, remontadas=remontadas)


MODELOS = {
    "Poisson": ("Poisson", "El modelo de Predicciones: goles a favor y en contra de cada equipo."),
    "Frecuencias": ("Frecuencias de la liga", "Referencia simple: da a todos los partidos el reparto medio de 1, X y 2."),
    "Un tercio": ("Un tercio cada resultado", "Referencia simple: no sabe nada."),
    #@@MODELOS@@
}


@app.get("/fiabilidad")
def fiabilidad():
    modelos = filas("SELECT Modelo, Tipo, Partidos, Brier, LogLoss, Aciertos FROM simulacion.vw_FiabilidadModelo ORDER BY Tipo, Brier")
    for m in modelos:
        m["Nombre"], m["Explicacion"] = MODELOS.get(m["Modelo"], (m["Modelo"], ""))
    calibracion = filas("SELECT Tramo, Casos, Previsto, Ocurrido FROM simulacion.vw_Calibracion WHERE Modelo = 'Poisson' ORDER BY Tramo")
    total = max((m["Partidos"] for m in modelos), default=0)
    congeladas = sum(m["Partidos"] for m in modelos if m["Tipo"] == "Congelada" and m["Modelo"] == "Poisson")
    return render_template("fiabilidad.html", modelos=modelos, calibracion=calibracion, total=total, congeladas=congeladas)


@app.get("/parecidos")
def parecidos():
    grupos = {"PT": "Porteros", "DF": "Defensas", "MC": "Centrocampistas", "DL": "Delanteros"}
    opciones = {}
    for j in filas("EXEC analisis.usp_JugadoresConPerfil;"):
        opciones.setdefault(grupos[j["Posicion"]], []).append(j)
    jugador, cercanos = None, []
    jugador_id = entero(request.args.get("jugador"))
    if jugador_id is not None:
        try:
            datos, cercanos = consultar("EXEC analisis.usp_Parecidos @JugadorID = ?;", (jugador_id,))
        except ErrorDatos:
            abort(404)
        jugador = datos[0]
    return render_template("parecidos.html", opciones=list(opciones.items()), jugador=jugador, parecidos=cercanos)


@app.get("/equipo/<int:equipo_id>")
def equipo(equipo_id):
    if not filas("SELECT 1 AS Hay FROM liga.Equipo WHERE EquipoID = ?", (equipo_id,)):
        abort(404)
    ficha, partidos, goleadores = consultar("EXEC analisis.usp_FichaEquipo @EquipoID = ?;", (equipo_id,))
    f = ficha[0]
    racha = None
    if f["RachaPartidos"]:
        n = f["RachaPartidos"]
        palabra = {"V": ("victoria", "victorias seguidas"), "E": ("empate", "empates seguidos"),
                   "D": ("derrota", "derrotas seguidas")}[f["RachaTipo"]]
        racha = f"Última racha: {n} {palabra[0] if n == 1 else palabra[1]}"
        if f["PartidosSinPerder"] > n:
            racha += f" · {f['PartidosSinPerder']} sin perder"
    tramos = filas("EXEC analisis.usp_MinutosGol @EquipoID = ?;", (equipo_id,))
    return render_template("equipo.html", f=f, partidos=partidos, goleadores=goleadores, racha=racha, tramos=tramos)


# ------------------------------------------------------------------ predicciones
limite_simular = Limitador(6, 60 * 60)
simulacion_web = {"hilo": None, "error": None}


def clasificacion_prevista(veces, equipos, temporadas):
    """Una fila por puesto, con cada equipo una sola vez: se reparte empezando por la pareja
    (equipo, puesto) más probable de todas. Cada fila lleva además todos los candidatos a ese puesto."""
    pares = sorted(((veces.get((e, p), (0, 0))[0], p, e) for e in equipos for p in range(1, 21)),
                   key=lambda x: (-x[0], x[1], equipos[x[2]]))
    equipo_de, usados = {}, set()
    for n, puesto, equipo in pares:
        if puesto not in equipo_de and equipo not in usados:
            equipo_de[puesto] = equipo
            usados.add(equipo)

    def pct(valor):
        return round(100.0 * valor / temporadas, 1) if temporadas else 0.0

    resumen = {}
    for e in equipos:
        filas_e = [veces.get((e, p), (0, 0)) for p in range(1, 21)]
        suma_top = lambda desde, hasta: sum(filas_e[p - 1][0] for p in range(desde, hasta + 1))
        resumen[e] = {"campeon": pct(suma_top(1, 1)), "top4": pct(suma_top(1, 4)), "top6": pct(suma_top(1, 6)),
                      "descenso": pct(suma_top(18, 20)),
                      "puntos": round(sum(f[1] for f in filas_e) / temporadas, 1) if temporadas else 0.0}
    tabla = []
    for puesto in sorted(equipo_de):
        e = equipo_de[puesto]
        candidatos = sorted(((veces[(c, puesto)][0], equipos[c]) for c in equipos if (c, puesto) in veces),
                            key=lambda x: (-x[0], x[1]))
        tabla.append({"puesto": puesto, "equipoId": e, "equipo": equipos[e], "prob": pct(veces.get((e, puesto), (0, 0))[0]),
                      **resumen[e], "candidatos": [{"equipo": n, "prob": pct(v)} for v, n in candidatos]})
    return tabla


def ejecucion_en_curso():
    return filas("""SELECT TOP (1) Tipo, HastaJornada, Temporadas, Hechas FROM simulacion.Ejecucion
                    WHERE Estado = 'En curso' AND Tipo <> 'Validacion' ORDER BY EjecucionID DESC""")


def simulando():
    hilo = simulacion_web["hilo"]
    return hilo is not None and hilo.is_alive()


@app.get("/predicciones")
def predicciones():
    return render_template("predicciones.html")


@app.get("/api/predicciones")
def api_predicciones():
    ultima, equipos, datos = consultar("""
        SELECT TOP (1) e.EjecucionID, e.HastaJornada, e.Temporadas, e.Fin,
               CASE WHEN e.HuellaDatos = (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(PartidoID, GolesLocal, GolesVisitante, Estado)) FROM liga.Partido)
                    THEN 1 ELSE 0 END AS AlDia
        FROM simulacion.Ejecucion AS e WHERE e.Tipo = 'Principal' AND e.Estado = 'Terminada'
        ORDER BY e.EjecucionID DESC;
        SELECT EquipoID, Nombre FROM liga.Equipo ORDER BY Nombre;
        SELECT MAX(j.Numero) AS Ultima, COUNT(*) AS Jugados FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        WHERE p.Estado = 'Finalizado';""")
    nombres = {e["EquipoID"]: e["Nombre"] for e in equipos}
    respuesta = {"simulando": simulando() or bool(ejecucion_en_curso()), "equipos": equipos, "resultado": None}
    if not ultima:
        return jsonify(respuesta)
    u = ultima[0]
    prob, pendientes, evolucion = consultar("""
        SELECT EquipoID, Puesto, Veces, SumaPuntos FROM simulacion.Probabilidad WHERE EjecucionID = ?;
        SELECT DISTINCT LocalID, VisitanteID FROM simulacion.PartidoSimulado WHERE Sim = 1;
        SELECT e.HastaJornada, p.EquipoID,
               100.0 * SUM(CASE WHEN p.Puesto = 1 THEN p.Veces ELSE 0 END) / e.Temporadas AS Campeon,
               100.0 * SUM(CASE WHEN p.Puesto <= 4 THEN p.Veces ELSE 0 END) / e.Temporadas AS Top4,
               100.0 * SUM(CASE WHEN p.Puesto >= 18 THEN p.Veces ELSE 0 END) / e.Temporadas AS Descenso
        FROM simulacion.Ejecucion AS e JOIN simulacion.Probabilidad AS p ON p.EjecucionID = e.EjecucionID
        WHERE e.Estado = 'Terminada' AND e.Tipo <> 'Validacion'
        GROUP BY e.HastaJornada, e.Temporadas, p.EquipoID
        ORDER BY e.HastaJornada, p.EquipoID;""", (u["EjecucionID"],))
    veces = {(p["EquipoID"], p["Puesto"]): (p["Veces"], p["SumaPuntos"]) for p in prob}
    respuesta["resultado"] = {
        "temporadas": u["Temporadas"], "hastaJornada": u["HastaJornada"], "alDia": bool(u["AlDia"]),
        "fecha": u["Fin"].strftime("%d/%m/%Y %H:%M") if u["Fin"] else "",
        "tabla": clasificacion_prevista(veces, nombres, u["Temporadas"]),
        "pendientes": pendientes,
        "evolucion": [{"j": e["HastaJornada"], "e": e["EquipoID"], "campeon": round(float(e["Campeon"]), 1),
                       "top4": round(float(e["Top4"]), 1), "descenso": round(float(e["Descenso"]), 1)} for e in evolucion],
    }
    return jsonify(respuesta)


@app.post("/api/predicciones/simular")
def api_simular():
    if simulando() or ejecucion_en_curso():
        return jsonify(ok=True, yaEnMarcha=True)
    if not limite_simular.permitir(request.remote_addr):
        return jsonify(error="Ya has simulado varias veces en la última hora. Prueba más tarde."), 429
    simulacion_web["error"] = None

    def trabajo():
        try:
            consultar("EXEC simulacion.usp_ActualizarPredicciones;")
        except ErrorDatos as error:
            simulacion_web["error"] = str(error)

    simulacion_web["hilo"] = threading.Thread(target=trabajo, daemon=True)
    simulacion_web["hilo"].start()
    return jsonify(ok=True)


@app.get("/api/predicciones/estado")
def api_estado_simulacion():
    actual = ejecucion_en_curso()
    respuesta = {"simulando": simulando() or bool(actual), "error": simulacion_web["error"], "paso": None}
    if actual:
        a = actual[0]
        respuesta["paso"] = {"tipo": a["Tipo"], "jornada": a["HastaJornada"], "temporadas": a["Temporadas"], "hechas": a["Hechas"]}
        if a["Tipo"] == "Principal" and a["Hechas"]:
            lider = filas("""SELECT TOP (1) q.Nombre, p.Veces FROM simulacion.Probabilidad AS p
                             JOIN liga.Equipo AS q ON q.EquipoID = p.EquipoID
                             WHERE p.Puesto = 1 AND p.EjecucionID = (SELECT MAX(EjecucionID) FROM simulacion.Ejecucion WHERE Tipo = 'Principal')
                             ORDER BY p.Veces DESC""")
            if lider:
                respuesta["lider"] = {"equipo": lider[0]["Nombre"], "pct": round(100.0 * lider[0]["Veces"] / a["Hechas"], 1)}
    return jsonify(respuesta)


@app.get("/api/predicciones/curiosidades")
def api_curiosidades():
    return jsonify(curiosidades=[f["Texto"] for f in filas("EXEC simulacion.usp_Curiosidades;")])


@app.post("/api/predicciones/ysi")
def api_ysi():
    datos = request.get_json(silent=True) or {}
    condiciones = [{"L": entero(c.get("L")), "V": entero(c.get("V")), "S": str(c.get("S"))}
                   for c in (datos.get("condiciones") or [])[:3] if isinstance(c, dict)]
    temporadas, detalle = consultar("EXEC simulacion.usp_YSi @Condiciones = ?;", (json.dumps(condiciones),))
    total = temporadas[0]["Temporadas"]
    nombres = {e["EquipoID"]: e["Nombre"] for e in filas("SELECT EquipoID, Nombre FROM liga.Equipo")}
    veces = {(d["EquipoID"], d["Puesto"]): (d["Veces"], d["SumaPuntos"]) for d in detalle}
    return jsonify(temporadas=total, tabla=clasificacion_prevista(veces, nombres, total) if total else [])


# ------------------------------------------------------------------------ admin
@app.route("/admin/entrar", methods=["GET", "POST"])
def entrar():
    if request.method == "POST":
        if not limite_login.permitir(request.remote_addr):
            flash("Demasiados intentos. Espera unos minutos.", "error")
            return render_template("admin/entrar.html"), 429
        nombre = request.form.get("usuario", "").strip()[:50]
        clave = request.form.get("clave", "")
        datos = filas("EXEC web.usp_DatosAcceso @Nombre = ?", (nombre,))
        cuenta = datos[0] if datos else None
        if cuenta and cuenta["BloqueadoHasta"]:
            flash("Cuenta bloqueada 15 minutos por demasiados intentos fallidos.", "error")
        elif cuenta and cuenta["Activo"] and check_password_hash(cuenta["HashClave"], clave):
            consultar("EXEC web.usp_RegistrarAcceso @Nombre = ?, @Exito = 1", (nombre,))
            session.clear()
            session.permanent = True
            session["admin"] = cuenta["Nombre"]
            session["csrf"] = secrets.token_urlsafe(32)
            destino = request.args.get("siguiente", "")
            return redirect(destino if destino.startswith("/admin") else url_for("panel"))
        else:
            if cuenta:
                consultar("EXEC web.usp_RegistrarAcceso @Nombre = ?, @Exito = 0", (nombre,))
            flash("Usuario o contraseña incorrectos.", "error")
    return render_template("admin/entrar.html")


@app.post("/admin/salir")
def salir():
    session.clear()
    return redirect(url_for("clasificacion"))


def admin_sql(sql, parametros=(), ok=None):
    """Ejecuta una escritura como web_admin y deja el mensaje para la siguiente página."""
    try:
        resultado = consultar(sql, parametros, usuario="web_admin")
        if ok:
            flash(ok, "ok")
        return resultado
    except ErrorDatos as error:
        flash(str(error), "error")
        return None


@app.get("/admin")
@solo_admin
def panel():
    pendientes = filas("""SELECT TOP (20) p.PartidoID, j.Numero, el.Nombre AS Local, ev.Nombre AS Visitante, p.FechaHora
                          FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
                          JOIN liga.Equipo AS el ON el.EquipoID = p.EquipoLocalID
                          JOIN liga.Equipo AS ev ON ev.EquipoID = p.EquipoVisitanteID
                          WHERE p.Estado <> 'Finalizado'
                          ORDER BY j.Numero, p.FechaHora, p.PartidoID""", usuario="web_admin")
    descuadres = filas("""SELECT p.PartidoID, j.Numero, el.Nombre AS Local, ev.Nombre AS Visitante,
                                 p.GolesLocal + p.GolesVisitante AS Marcador, COUNT(g.GolID) AS Registrados
                          FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
                          JOIN liga.Equipo AS el ON el.EquipoID = p.EquipoLocalID
                          JOIN liga.Equipo AS ev ON ev.EquipoID = p.EquipoVisitanteID
                          LEFT JOIN liga.Gol AS g ON g.PartidoID = p.PartidoID
                          WHERE p.Estado = 'Finalizado'
                          GROUP BY p.PartidoID, j.Numero, el.Nombre, ev.Nombre, p.GolesLocal, p.GolesVisitante
                          HAVING COUNT(g.GolID) <> p.GolesLocal + p.GolesVisitante
                          ORDER BY j.Numero, p.PartidoID""", usuario="web_admin")
    lista = jornadas()
    siguiente = (max((j["Numero"] for j in lista), default=0) + 1)
    return render_template("admin/panel.html", lista=lista, pendientes=pendientes,
                           descuadres=descuadres, siguiente=min(siguiente, 38))


@app.post("/admin/jornada/crear")
@solo_admin
def crear_jornada():
    numero = entero(request.form.get("numero"))
    admin_sql("EXEC web.usp_CrearJornada @Numero = ?", (numero,), ok=f"Jornada {numero} creada.")
    return redirect(url_for("panel"))


def opciones_partido():
    equipos, arbitros = consultar("""SELECT EquipoID, Nombre FROM liga.Equipo ORDER BY Nombre;
                                     SELECT ArbitroID, Nombre FROM liga.Arbitro ORDER BY Nombre;""")
    return equipos, arbitros


@app.get("/admin/jornada/<int:jornada_id>")
@solo_admin
def admin_jornada(jornada_id):
    actual = next((j for j in jornadas() if j["JornadaID"] == jornada_id), None)
    if actual is None:
        abort(404)
    partidos = partidos_de(jornada_id, "web_admin")
    ocupados = {p["EquipoLocalID"] for p in partidos} | {p["EquipoVisitanteID"] for p in partidos}
    equipos, arbitros = opciones_partido()
    libres = [e for e in equipos if e["EquipoID"] not in ocupados]
    return render_template("admin/jornada.html", actual=actual, partidos=partidos,
                           libres=libres, arbitros=arbitros)


def fecha_formulario(texto):
    if not texto:
        return None
    try:
        return datetime.strptime(texto, "%Y-%m-%dT%H:%M")
    except ValueError:
        return None


@app.post("/admin/partido/crear")
@solo_admin
def crear_partido():
    f = request.form
    jornada_id = entero(f.get("jornada"))
    admin_sql("EXEC web.usp_CrearPartido @JornadaID = ?, @LocalID = ?, @VisitanteID = ?, @FechaHora = ?, @ArbitroID = ?",
              (jornada_id, entero(f.get("local")), entero(f.get("visitante")),
               fecha_formulario(f.get("fecha")), entero(f.get("arbitro"))), ok="Partido creado.")
    return redirect(url_for("admin_jornada", jornada_id=jornada_id))


@app.get("/admin/partido/<int:partido_id>")
@solo_admin
def admin_partido(partido_id):
    partido = filas("""SELECT p.*, j.Numero, el.Nombre AS Local, ev.Nombre AS Visitante, es.Nombre AS Estadio
                       FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
                       JOIN liga.Equipo AS el ON el.EquipoID = p.EquipoLocalID
                       JOIN liga.Equipo AS ev ON ev.EquipoID = p.EquipoVisitanteID
                       JOIN liga.Estadio AS es ON es.EstadioID = p.EstadioID
                       WHERE p.PartidoID = ?""", (partido_id,), "web_admin")
    if not partido:
        abort(404)
    partido = partido[0]
    goles, jugadores = consultar("""
        SELECT GolID, EquipoID, Anotador, Minuto, Tipo, JugadorID FROM liga.Gol WHERE PartidoID = ? ORDER BY Minuto, GolID;
        SELECT JugadorID, EquipoID, Nombre, Posicion FROM liga.Jugador WHERE EquipoID IN (?, ?) ORDER BY Nombre;""",
        (partido_id, partido["EquipoLocalID"], partido["EquipoVisitanteID"]), "web_admin")
    _, arbitros = opciones_partido()
    return render_template("admin/partido.html", p=partido, goles=goles, jugadores=jugadores, arbitros=arbitros)


@app.post("/admin/partido/<int:partido_id>/resultado")
@solo_admin
def guardar_resultado(partido_id):
    f = request.form
    admin_sql("EXEC liga.usp_RegistrarResultado @PartidoID = ?, @GolesLocal = ?, @GolesVisitante = ?, "
              "@Estado = ?, @PermitirCorreccion = ?",
              (partido_id, entero(f.get("local")), entero(f.get("visitante")), f.get("estado", "Finalizado"),
               1 if f.get("correccion") else 0), ok="Resultado guardado.")
    return redirect(url_for("admin_partido", partido_id=partido_id))


@app.post("/admin/partido/<int:partido_id>/editar")
@solo_admin
def editar_partido(partido_id):
    f = request.form
    admin_sql("EXEC web.usp_EditarPartido @PartidoID = ?, @FechaHora = ?, @ArbitroID = ?",
              (partido_id, fecha_formulario(f.get("fecha")), entero(f.get("arbitro"))), ok="Partido actualizado.")
    return redirect(url_for("admin_partido", partido_id=partido_id))


@app.post("/admin/partido/<int:partido_id>/borrar")
@solo_admin
def borrar_partido(partido_id):
    jornada_id = entero(request.form.get("jornada"))
    if admin_sql("EXEC web.usp_BorrarPartido @PartidoID = ?", (partido_id,), ok="Partido borrado.") is None:
        return redirect(url_for("admin_partido", partido_id=partido_id))
    return redirect(url_for("admin_jornada", jornada_id=jornada_id))


@app.post("/admin/partido/<int:partido_id>/gol")
@solo_admin
def anadir_gol(partido_id):
    f = request.form
    admin_sql("EXEC web.usp_AnadirGol @PartidoID = ?, @EquipoID = ?, @Minuto = ?, @Tipo = ?, @JugadorID = ?, @Anotador = ?",
              (partido_id, entero(f.get("equipo")), entero(f.get("minuto")), f.get("tipo", "Normal"),
               entero(f.get("jugador")), f.get("anotador") or None), ok="Gol añadido.")
    return redirect(url_for("admin_partido", partido_id=partido_id))


@app.post("/admin/gol/<int:gol_id>/borrar")
@solo_admin
def borrar_gol(gol_id):
    admin_sql("EXEC web.usp_BorrarGol @GolID = ?", (gol_id,), ok="Gol borrado.")
    return redirect(url_for("admin_partido", partido_id=entero(request.form.get("partido"), 0)))


@app.get("/admin/jugadores")
@solo_admin
def admin_jugadores():
    equipos = filas("SELECT EquipoID, Nombre FROM liga.Equipo ORDER BY Nombre", usuario="web_admin")
    equipo = entero(request.args.get("equipo"), equipos[0]["EquipoID"] if equipos else None)
    jugadores = filas("""SELECT JugadorID, EquipoID, Nombre, Posicion, MinutosJugados, Goles, Asistencias, UltimaJornada
                         FROM liga.Jugador WHERE EquipoID = ?
                         ORDER BY CASE Posicion WHEN 'PT' THEN 1 WHEN 'DF' THEN 2 WHEN 'MC' THEN 3 WHEN 'DL' THEN 4 ELSE 5 END,
                                  Nombre""", (equipo,), "web_admin")
    editar = next((j for j in jugadores if j["JugadorID"] == entero(request.args.get("editar"))), None)
    return render_template("admin/jugadores.html", equipos=equipos, equipo=equipo, jugadores=jugadores, editar=editar)


@app.post("/admin/jugador/guardar")
@solo_admin
def guardar_jugador():
    f = request.form
    equipo = entero(f.get("equipo"))
    admin_sql("""EXEC web.usp_GuardarJugador @JugadorID = ?, @EquipoID = ?, @Nombre = ?, @Posicion = ?,
                 @MinutosJugados = ?, @Goles = ?, @Asistencias = ?, @UltimaJornada = ?""",
              (entero(f.get("jugador")), equipo, f.get("nombre", ""), f.get("posicion") or None,
               entero(f.get("minutos"), 0), entero(f.get("goles"), 0), entero(f.get("asistencias"), 0),
               entero(f.get("ultima"))), ok="Jugador guardado.")
    return redirect(url_for("admin_jugadores", equipo=equipo))


@app.get("/admin/arbitros")
@solo_admin
def admin_arbitros():
    arbitros = filas("""SELECT a.ArbitroID, a.Nombre, COUNT(p.PartidoID) AS Partidos
                        FROM liga.Arbitro AS a LEFT JOIN liga.Partido AS p ON p.ArbitroPrincipalID = a.ArbitroID
                        GROUP BY a.ArbitroID, a.Nombre ORDER BY a.Nombre""", usuario="web_admin")
    return render_template("admin/arbitros.html", arbitros=arbitros)


@app.post("/admin/arbitro/crear")
@solo_admin
def crear_arbitro():
    admin_sql("EXEC web.usp_CrearArbitro @Nombre = ?", (request.form.get("nombre", ""),), ok="Árbitro añadido.")
    return redirect(url_for("admin_arbitros"))


# ----------------------------------------------------------------------- inicio
if __name__ == "__main__":
    from waitress import serve

    host = os.environ.get("LALIGADB_HOST", "127.0.0.1")
    puerto = int(os.environ.get("LALIGADB_PUERTO", "8080"))
    print(f"\n  {NOMBRE_APP} en marcha:  http://localhost:{puerto}\n  Para pararla, cierra esta ventana.\n")
    if "--abrir" in sys.argv:
        threading.Timer(1.5, webbrowser.open, (f"http://localhost:{puerto}",)).start()
    serve(app, host=host, port=puerto, threads=8)
