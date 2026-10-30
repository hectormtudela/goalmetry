"""Acceso a SQL Server para la web de LaLigaDB.

Cada petición abre su propia conexión (autenticación de Windows, sin contraseñas)
y se pone en la piel de un usuario de mínimo privilegio con EXECUTE AS USER:
  - web_publico: solo lectura de la liga, búsqueda y preguntas a la IA.
  - web_admin:   lo anterior + los procedimientos web.usp_* para meter datos.
Se usa WITH NO REVERT y sin pool de conexiones: la conexión no se reutiliza nunca
con otro usuario.
"""
import os
import re

import pyodbc

pyodbc.pooling = False

CADENA_POR_DEFECTO = (
    "DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost;DATABASE=LigaDB;"
    "Trusted_Connection=yes;TrustServerCertificate=yes"
)
USUARIOS = {"web_publico", "web_admin"}

# Errores de SQL Server que se traducen a un mensaje entendible.
MENSAJES = {
    229: "No tienes permiso para hacer eso.",
    547: "Ese dato no cumple las reglas de la base de datos.",
    2601: "Ese dato ya existe.",
    2627: "Ese dato ya existe.",
    15151: "La IA no está configurada en la base de datos.",
    50003: "El partido ya está finalizado. Para corregirlo, marca la casilla de confirmación.",
}


class ErrorDatos(Exception):
    """Error con un mensaje pensado para enseñarlo en la web."""

    def __init__(self, mensaje, numero=None):
        super().__init__(mensaje)
        self.numero = numero


def _traducir(error):
    texto = " ".join(str(a) for a in error.args)
    encontrado = re.findall(r"\[SQL Server\]([^\[]*?)\s*\((\d+)\)", texto)
    if not encontrado:
        if "08001" in texto or "Login" in texto:
            return ErrorDatos("No se puede conectar con la base de datos. ¿Está encendido SQL Server?")
        return ErrorDatos("Error inesperado de la base de datos.")
    mensaje, numero = encontrado[-1][0].strip(), int(encontrado[-1][1])
    if numero in MENSAJES:
        return ErrorDatos(MENSAJES[numero], numero)
    if numero >= 50000:  # errores propios (THROW): ya vienen en español
        return ErrorDatos(mensaje, numero)
    if "external" in mensaje.lower() or "endpoint" in mensaje.lower() or numero in (31600, 31601, 31602):
        return ErrorDatos("No se pudo hablar con la IA. ¿Están encendidos Ollama y Caddy?", numero)
    return ErrorDatos(f"Error de la base de datos ({numero}).", numero)


def consultar(sql, parametros=(), usuario="web_publico"):
    """Ejecuta un lote y devuelve todos sus conjuntos de resultados como listas de dict."""
    if usuario not in USUARIOS:
        raise ValueError(usuario)
    conexion = pyodbc.connect(os.environ.get("LALIGADB_SQL", CADENA_POR_DEFECTO), autocommit=True)
    try:
        cursor = conexion.cursor()
        cursor.execute(f"SET NOCOUNT ON; EXECUTE AS USER = N'{usuario}' WITH NO REVERT;")
        cursor.execute("SET NOCOUNT ON;\n" + sql, parametros)
        conjuntos = []
        while True:
            if cursor.description:
                columnas = [c[0] for c in cursor.description]
                conjuntos.append([dict(zip(columnas, fila)) for fila in cursor.fetchall()])
            if not cursor.nextset():
                break
        return conjuntos
    except pyodbc.Error as error:
        raise _traducir(error) from None
    finally:
        conexion.close()


def filas(sql, parametros=(), usuario="web_publico"):
    """Primer conjunto de resultados (o lista vacía)."""
    conjuntos = consultar(sql, parametros, usuario)
    return conjuntos[0] if conjuntos else []


def ejecutar_como_dbo(sql, parametros=()):
    """Solo para web/crear_admin.py: usa tu usuario de Windows tal cual."""
    conexion = pyodbc.connect(os.environ.get("LALIGADB_SQL", CADENA_POR_DEFECTO), autocommit=True)
    try:
        conexion.cursor().execute(sql, parametros)
    except pyodbc.Error as error:
        raise _traducir(error) from None
    finally:
        conexion.close()
