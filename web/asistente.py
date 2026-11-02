"""Goalmetry - asistente de jornada nueva: valida unos CSV subidos y los fusiona en data/.

No toca la base de datos: los CSV son la fuente de verdad, y actualizar.ps1 los carga después.
Sigue las reglas de data/LEEME-datos.md: filas nuevas al final, cambios en su sitio, nada se borra
ni se renumera. No inventa nada: lo que no cuadra es un error y no se puede confirmar.
"""
import csv
import io
import shutil
from datetime import datetime
from pathlib import Path

CAMPOS_PARTIDOS = ["partido_id", "jornada_id", "equipo_local_id", "equipo_visitante_id", "estadio_id",
                   "arbitro_principal_id", "fecha_hora", "goles_local", "goles_visitante", "estado"]
CAMPOS_GOLES = ["gol_id", "partido_id", "equipo_id", "jugador_id", "anotador", "minuto", "tipo"]
CAMPOS_JORNADAS = ["jornada_id", "temporada_id", "numero"]
MAX_FILAS = 2000


def leer_csv(texto):
    """Devuelve (campos, filas) de un texto CSV."""
    lector = csv.DictReader(io.StringIO(texto))
    return lector.fieldnames or [], list(lector)


def leer_fichero(carpeta, nombre):
    ruta = Path(carpeta) / nombre
    return leer_csv(ruta.read_text(encoding="utf-8"))[1] if ruta.exists() else []


def decodificar(contenido):
    """Texto de un fichero subido, o None si no es UTF-8 (Excel lo guarda así si no se elige «CSV UTF-8»)."""
    try:
        return contenido.decode("utf-8-sig").replace("\r\n", "\n")
    except UnicodeDecodeError:
        return None


def _entero(valor):
    try:
        return int(valor)
    except (TypeError, ValueError):
        return None


class Informe:
    def __init__(self):
        self.errores, self.avisos = [], []
        self.partidos_nuevos, self.partidos_cambian, self.goles_nuevos, self.goles_cambian, self.jornadas_nuevas = [], [], [], [], []
        self.partidos_sin_cambio = 0
        self.goles_sin_cambio = 0

    @property
    def valido(self):
        return not self.errores

    @property
    def hay_cambios(self):
        return bool(self.partidos_nuevos or self.partidos_cambian or self.goles_nuevos or self.goles_cambian)


def _comprobar_cabecera(informe, nombre, campos, esperados):
    if campos == esperados:
        return True
    if campos and ";" in campos[0]:
        informe.errores.append(f"{nombre}: está separado por punto y coma. Guárdalo separado por comas.")
    else:
        informe.errores.append(f"{nombre}: las columnas deben ser exactamente: {', '.join(esperados)}.")
    return False


def validar(carpeta, texto_partidos, texto_goles, ahora=None):
    """Comprueba los CSV subidos contra data/. No escribe nada."""
    informe = Informe()
    ahora = ahora or datetime.now()
    campos_p, subidos_p = leer_csv(texto_partidos) if texto_partidos else (CAMPOS_PARTIDOS, [])
    campos_g, subidos_g = leer_csv(texto_goles) if texto_goles else (CAMPOS_GOLES, [])
    if not subidos_p and not subidos_g and not texto_partidos and not texto_goles:
        informe.errores.append("No has subido ningún fichero.")
        return informe
    ok_p = _comprobar_cabecera(informe, "Partidos", campos_p, CAMPOS_PARTIDOS)
    ok_g = _comprobar_cabecera(informe, "Goles", campos_g, CAMPOS_GOLES)
    if not (ok_p and ok_g):
        return informe
    if len(subidos_p) + len(subidos_g) > MAX_FILAS:
        informe.errores.append(f"Demasiadas filas: el máximo son {MAX_FILAS}.")
        return informe

    equipos = {_entero(e["equipo_id"]): e["nombre"] for e in leer_fichero(carpeta, "equipos.csv")}
    estadios = {_entero(e["equipo_id"]): _entero(e["estadio_id"]) for e in leer_fichero(carpeta, "estadios.csv")}
    arbitros = {_entero(a["arbitro_id"]) for a in leer_fichero(carpeta, "arbitros.csv")}
    jugadores = {_entero(j["jugador_id"]): j for j in leer_fichero(carpeta, "jugadores.csv")}
    jornadas = {_entero(j["jornada_id"]): j for j in leer_fichero(carpeta, "jornadas.csv")}
    partidos = {_entero(p["partido_id"]): p for p in leer_fichero(carpeta, "partidos.csv")}
    goles = {_entero(g["gol_id"]): g for g in leer_fichero(carpeta, "goles.csv")}

    # ---------- Partidos ----------
    max_partido, max_jornada = max(partidos, default=0), max(jornadas, default=0)
    vistos, finales = set(), dict(partidos)
    for n, f in enumerate(subidos_p, start=2):
        donde = f"Partidos, fila {n}"
        pid, jid = _entero(f["partido_id"]), _entero(f["jornada_id"])
        local, visitante = _entero(f["equipo_local_id"]), _entero(f["equipo_visitante_id"])
        if pid is None or jid is None or local is None or visitante is None:
            informe.errores.append(f"{donde}: partido, jornada y equipos deben ser números.")
            continue
        if pid in vistos:
            informe.errores.append(f"{donde}: el partido {pid} está repetido en el fichero.")
            continue
        vistos.add(pid)
        for equipo in (local, visitante):
            if equipo not in equipos:
                informe.errores.append(f"{donde}: el equipo {equipo} no existe. Revisa equipos.csv.")
        if local == visitante:
            informe.errores.append(f"{donde}: un equipo no puede jugar contra sí mismo.")
        if jid not in jornadas and jid != max_jornada + 1:
            informe.errores.append(f"{donde}: la jornada {jid} no existe y no es la siguiente ({max_jornada + 1}).")
        if local in estadios and _entero(f["estadio_id"]) != estadios[local]:
            informe.errores.append(f"{donde}: el estadio debe ser el del equipo local ({estadios[local]}).")
        arbitro = f["arbitro_principal_id"].strip()
        if arbitro and _entero(arbitro) not in arbitros:
            informe.errores.append(f"{donde}: el árbitro {arbitro} no existe. Añádelo antes a arbitros.csv.")
        try:
            fecha = datetime.strptime(f["fecha_hora"].strip(), "%Y-%m-%d %H:%M:%S")
        except ValueError:
            informe.errores.append(f"{donde}: la fecha debe tener la forma 2026-11-08 21:00:00.")
            fecha = None
        gl, gv = f["goles_local"].strip(), f["goles_visitante"].strip()
        if f["estado"] == "Finalizado":
            if _entero(gl) is None or _entero(gv) is None or int(gl) < 0 or int(gv) < 0:
                informe.errores.append(f"{donde}: un partido finalizado necesita su marcador.")
            if fecha and fecha > ahora:
                informe.avisos.append(f"{donde}: está finalizado, pero su fecha aún no ha llegado.")
        elif f["estado"] == "Programado":
            if gl or gv:
                informe.errores.append(f"{donde}: un partido programado no lleva marcador.")
        else:
            informe.errores.append(f"{donde}: el estado debe ser Finalizado o Programado.")
        # Nuevo, cambio o igual
        nombre = f"{equipos.get(local, local)} - {equipos.get(visitante, visitante)}"
        if pid in partidos:
            anterior = partidos[pid]
            if all(anterior[c] == f[c] for c in CAMPOS_PARTIDOS):
                informe.partidos_sin_cambio += 1
            else:
                informe.partidos_cambian.append(f"{nombre}: {anterior['goles_local'] or '-'}-{anterior['goles_visitante'] or '-'} ({anterior['estado']}) pasa a {gl or '-'}-{gv or '-'} ({f['estado']})")
                if anterior["estado"] == "Finalizado" and (anterior["goles_local"] != gl or anterior["goles_visitante"] != gv):
                    informe.avisos.append(f"{donde}: corrige el marcador de un partido ya finalizado ({nombre}).")
                if anterior["equipo_local_id"] != f["equipo_local_id"] or anterior["equipo_visitante_id"] != f["equipo_visitante_id"]:
                    informe.errores.append(f"{donde}: el partido {pid} ya existe con otros equipos.")
        elif pid <= max_partido:
            informe.errores.append(f"{donde}: el partido {pid} no existe y su número no es de los siguientes a {max_partido}.")
        else:
            informe.partidos_nuevos.append(nombre)
        finales[pid] = f

    if any(i not in partidos for i in vistos):
        nuevos = sorted(i for i in vistos if i not in partidos)
        if nuevos != list(range(max_partido + 1, max_partido + 1 + len(nuevos))):
            informe.errores.append(f"Los partidos nuevos deben numerarse seguidos desde {max_partido + 1}.")
    for jid in sorted({_entero(f["jornada_id"]) for f in subidos_p} - set(jornadas) - {None}):
        informe.jornadas_nuevas.append(jid)

    # Cruces repetidos y equipos dos veces en una jornada, ya con el resultado de la fusión
    cruces, por_jornada = {}, {}
    for pid, f in finales.items():
        pareja = (f["equipo_local_id"], f["equipo_visitante_id"])
        if pareja in cruces and (pid in vistos or cruces[pareja] in vistos):
            informe.errores.append(f"El cruce {equipos.get(_entero(pareja[0]))} - {equipos.get(_entero(pareja[1]))} ya está en el partido {cruces[pareja]}.")
        cruces[pareja] = pid
        contados = por_jornada.setdefault(f["jornada_id"], {})
        for equipo in pareja:
            contados[equipo] = contados.get(equipo, 0) + 1
    for jid in {f["jornada_id"] for f in subidos_p}:
        for equipo, veces in por_jornada.get(jid, {}).items():
            if veces > 1:
                informe.errores.append(f"Jornada {jid}: {equipos.get(_entero(equipo), equipo)} juega {veces} partidos.")

    # ---------- Goles ----------
    max_gol, vistos_g, goles_finales = max(goles, default=0), set(), dict(goles)
    for n, f in enumerate(subidos_g, start=2):
        donde = f"Goles, fila {n}"
        gid, pid, equipo = _entero(f["gol_id"]), _entero(f["partido_id"]), _entero(f["equipo_id"])
        if gid is None or pid is None or equipo is None:
            informe.errores.append(f"{donde}: gol, partido y equipo deben ser números.")
            continue
        if gid in vistos_g:
            informe.errores.append(f"{donde}: el gol {gid} está repetido en el fichero.")
            continue
        vistos_g.add(gid)
        if pid not in finales:
            informe.errores.append(f"{donde}: el partido {pid} no existe.")
            continue
        p = finales[pid]
        if p["estado"] != "Finalizado":
            informe.errores.append(f"{donde}: el partido {pid} no está finalizado.")
        en_partido = {_entero(p["equipo_local_id"]), _entero(p["equipo_visitante_id"])}
        if equipo not in en_partido:
            informe.errores.append(f"{donde}: el equipo {equipo} no juega el partido {pid}.")
        minuto = _entero(f["minuto"])
        if minuto is None or not 1 <= minuto <= 130:
            informe.errores.append(f"{donde}: el minuto debe estar entre 1 y 130.")
        if f["tipo"] not in ("Normal", "Penalti", "PropiaPuerta"):
            informe.errores.append(f"{donde}: el tipo debe ser Normal, Penalti o PropiaPuerta.")
        if not f["anotador"].strip():
            informe.errores.append(f"{donde}: falta el nombre del anotador.")
        jugador_id = f["jugador_id"].strip()
        if jugador_id:
            j = jugadores.get(_entero(jugador_id))
            if j is None:
                informe.errores.append(f"{donde}: el jugador {jugador_id} no existe. Añádelo a jugadores.csv o deja el campo vacío.")
            else:
                if j["nombre"] != f["anotador"].strip():
                    informe.avisos.append(f"{donde}: el anotador es «{f['anotador']}», pero el jugador {jugador_id} se llama «{j['nombre']}».")
                # En propia puerta, equipo_id es el beneficiado: el jugador es del otro equipo.
                propio = _entero(j["equipo_id"])
                if f["tipo"] == "PropiaPuerta":
                    if propio == equipo:
                        informe.errores.append(f"{donde}: en propia puerta, el equipo debe ser el beneficiado, no el del jugador.")
                elif propio != equipo:
                    informe.avisos.append(f"{donde}: {j['nombre']} figura en otro equipo. ¿Ha cambiado de equipo?")
        else:
            informe.avisos.append(f"{donde}: «{f['anotador']}» queda sin ficha de jugador (no reconocido).")
        if gid in goles:
            if all(goles[gid][c] == f[c] for c in CAMPOS_GOLES):
                informe.goles_sin_cambio += 1
            else:
                informe.goles_cambian.append(f"Gol {gid}: {f['anotador']}, minuto {f['minuto']}")
        elif gid <= max_gol:
            informe.errores.append(f"{donde}: el gol {gid} no existe y su número no es de los siguientes a {max_gol}.")
        else:
            informe.goles_nuevos.append(f"{f['anotador']}, minuto {f['minuto']}")
        goles_finales[gid] = f

    nuevos_g = sorted(i for i in vistos_g if i not in goles)
    if nuevos_g != list(range(max_gol + 1, max_gol + 1 + len(nuevos_g))):
        informe.errores.append(f"Los goles nuevos deben numerarse seguidos desde {max_gol + 1}.")

    # Cada partido tocado: los goles deben sumar el marcador
    tocados = {_entero(f["partido_id"]) for f in subidos_g} | {i for i in vistos if finales[i]["estado"] == "Finalizado"}
    for pid in sorted(t for t in tocados if t in finales):
        p = finales[pid]
        if p["estado"] != "Finalizado":
            continue
        local, visitante = _entero(p["equipo_local_id"]), _entero(p["equipo_visitante_id"])
        de = [g for g in goles_finales.values() if _entero(g["partido_id"]) == pid]
        gl = sum(1 for g in de if _entero(g["equipo_id"]) == local)
        gv = sum(1 for g in de if _entero(g["equipo_id"]) == visitante)
        if (gl, gv) != (_entero(p["goles_local"]), _entero(p["goles_visitante"])):
            informe.errores.append(f"{equipos.get(local)} - {equipos.get(visitante)}: el marcador es {p['goles_local']}-{p['goles_visitante']}, pero los goles suman {gl}-{gv}.")
    if informe.valido and not informe.hay_cambios:
        informe.avisos.append("No hay nada nuevo: todo lo subido ya está en los CSV.")
    return informe


def _escribir(ruta, campos, filas):
    salida = io.StringIO()
    escritor = csv.writer(salida, lineterminator="\n")
    escritor.writerow(campos)
    for f in filas:
        escritor.writerow([f[c] for c in campos])
    temporal = ruta.with_suffix(".tmp")
    temporal.write_text(salida.getvalue(), encoding="utf-8", newline="\n")
    temporal.replace(ruta)


def fusionar_filas(existentes, nuevas, clave):
    """Cambios en su sitio y filas nuevas al final. Nada se borra."""
    resultado = [dict(f) for f in existentes]
    indice = {f[clave]: i for i, f in enumerate(resultado)}
    for f in nuevas:
        if f[clave] in indice:
            resultado[indice[f[clave]]] = dict(f)
        else:
            indice[f[clave]] = len(resultado)
            resultado.append(dict(f))
    return resultado


def jornadas_con(existentes, nuevas_ids):
    """Las jornadas nuevas: el número sigue al ID y la temporada es la de la última."""
    resultado = [dict(j) for j in existentes]
    temporada = existentes[-1]["temporada_id"] if existentes else "1"
    for jid in nuevas_ids:
        resultado.append({"jornada_id": str(jid), "temporada_id": temporada, "numero": str(jid)})
    return resultado


def aplicar(carpeta, texto_partidos, texto_goles, ahora=None):
    """Valida de nuevo y fusiona en data/, con copia previa. Devuelve el informe y la carpeta de la copia."""
    carpeta = Path(carpeta)
    informe = validar(carpeta, texto_partidos, texto_goles, ahora)
    if not informe.valido or not informe.hay_cambios:
        return informe, None
    copia = carpeta / "_copias" / datetime.now().strftime("%Y%m%d-%H%M%S")
    copia.mkdir(parents=True, exist_ok=True)
    for nombre in ("partidos.csv", "goles.csv", "jornadas.csv", "CAMBIOS.md"):
        if (carpeta / nombre).exists():
            shutil.copy2(carpeta / nombre, copia / nombre)
    _, subidos_p = leer_csv(texto_partidos) if texto_partidos else ([], [])
    _, subidos_g = leer_csv(texto_goles) if texto_goles else ([], [])
    if informe.jornadas_nuevas:
        _escribir(carpeta / "jornadas.csv", CAMPOS_JORNADAS, jornadas_con(leer_fichero(carpeta, "jornadas.csv"), informe.jornadas_nuevas))
    if subidos_p:
        _escribir(carpeta / "partidos.csv", CAMPOS_PARTIDOS, fusionar_filas(leer_fichero(carpeta, "partidos.csv"), subidos_p, "partido_id"))
    if subidos_g:
        _escribir(carpeta / "goles.csv", CAMPOS_GOLES, fusionar_filas(leer_fichero(carpeta, "goles.csv"), subidos_g, "gol_id"))
    with (carpeta / "CAMBIOS.md").open("a", encoding="utf-8", newline="\n") as f:
        f.write(f"\n## {datetime.now():%d/%m/%Y} · Asistente de jornada nueva\n\n"
                f"- {len(informe.partidos_nuevos)} partidos nuevos, {len(informe.partidos_cambian)} cambiados, "
                f"{len(informe.goles_nuevos)} goles nuevos. Subido desde el panel de administración.\n")
    return informe, copia


def exportar(carpeta, partidos_bd, goles_bd, jornadas_bd):
    """CSV completos con lo que hay en la base de datos y no en data/ (lo introducido en el panel).
    Recibe filas con las columnas de los CSV. Devuelve {nombre: texto} y un resumen."""
    resumen, textos = {}, {}
    for nombre, campos, clave, bd in (("partidos.csv", CAMPOS_PARTIDOS, "partido_id", partidos_bd),
                                      ("goles.csv", CAMPOS_GOLES, "gol_id", goles_bd),
                                      ("jornadas.csv", CAMPOS_JORNADAS, "jornada_id", jornadas_bd)):
        existentes = leer_fichero(carpeta, nombre)
        actuales = {f[clave]: f for f in existentes}
        distintas = [f for f in bd if f[clave] not in actuales or any(actuales[f[clave]][c] != f[c] for c in campos)]
        resumen[nombre] = {"nuevas": sum(1 for f in distintas if f[clave] not in actuales),
                           "cambian": sum(1 for f in distintas if f[clave] in actuales)}
        salida = io.StringIO()
        escritor = csv.writer(salida, lineterminator="\n")
        escritor.writerow(campos)
        for f in fusionar_filas(existentes, distintas, clave):
            escritor.writerow([f[c] for c in campos])
        textos[nombre] = salida.getvalue()
    return textos, resumen
