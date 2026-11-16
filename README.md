# Goalmetry

Liga española de fútbol «inteligente» sobre **SQL Server 2025**: clasificación, resultados, fichas de equipo, análisis, predicciones de la temporada y, en la versión completa, búsqueda y preguntas en lenguaje natural con una IA que se ejecuta en tu propio ordenador. Datos reales de la temporada 2026-27 de LaLiga, jornada a jornada.

## Míralo sin instalar nada

**https://hectormtudela.github.io/goalmetry/**

Es una versión de solo lectura: clasificación, jornadas, equipos, análisis, predicciones y «Mi equipo». Cada página dice hasta qué jornada llegan los datos. No incluye el buscador inteligente, las preguntas a la IA ni el panel de administración, que necesitan la versión completa.

## Instalar la versión completa

La versión completa funciona **en tu ordenador**, sin cuentas ni servicios de pago, y añade lo que la web de solo lectura no puede: el buscador por significado, las preguntas a la IA, volver a simular las predicciones y el panel de administración.

**Con doble clic:**

1. Descarga el repositorio (botón verde **Code → Download ZIP**) y descomprímelo, por ejemplo en `Documentos`.
2. Haz doble clic en **`Instalar Goalmetry.bat`**. Si Windows avisa de que «protegió su PC» (pantalla azul), pulsa *Más información → Ejecutar de todas formas*: es normal en ficheros descargados.
3. Acepta el permiso de administrador (una sola vez). Te preguntará si quieres instalar también la IA. Espera: la primera vez puede tardar de 20 a 60 minutos, porque descarga SQL Server y, con la IA, dos modelos de unos 3 GB.
4. Al terminar se abre Goalmetry y queda un icono **Goalmetry** en el escritorio. A partir de entonces, basta con ese icono.

**Qué instala, solo si falta** (todo gratuito): SQL Server 2025 edición Developer (gratuita, solo para desarrollo y pruebas), `sqlcmd` y el controlador ODBC, Python 3.12 y, con la IA, Ollama (modelos `bge-m3` y `qwen2.5:3b`) y Caddy. Después crea la base de datos `LigaDB` con los datos y prepara la web.

**Necesitas:** Windows 10 u 11 de 64 bits, unos 15 GB libres, conexión a Internet (solo para instalar) y, para la IA, unos 16 GB de memoria. Sin la IA, todo funciona salvo las preguntas y el buscador por significado.

Si algo falla, vuelve a hacer doble clic: cada paso comprueba lo que ya está hecho, así que se puede repetir sin problema. El detalle queda en `%TEMP%\goalmetry-instalacion.log`.

> Es la primera versión del instalador y todavía no se ha probado en un ordenador completamente limpio. Si algo no funciona, cuéntalo en *Issues*.

Para cargar jornadas nuevas, actualiza los CSV de `data/` y ejecuta `.\actualizar.ps1`.

## Datos y fuentes

- **Datos reales** de la temporada 2026-27, verificados a mano:
  - [futbolfantasy.com](https://www.futbolfantasy.com): calendario, resultados, fechas, árbitros y goles de cada partido.
  - [matchscan.co](https://matchscan.co): jugadores, posiciones, minutos, goles y asistencias.
  - [Wikipedia](https://en.wikipedia.org/wiki/2026%E2%80%9327_La_Liga): ciudades, estadios y capacidades.
- **Datos de apoyo de fuentes externas** (estadísticas por partido, cuotas y calendario), siempre separados de los anteriores y rotulados como tales: [football-data.co.uk](https://www.football-data.co.uk) y [openfootball](https://github.com/openfootball/football.json).
- **Datos ficticios:** solo `ventas.Abonado` y `ventas.Entrada` (abonados y entradas de demostración). Nombres, correos (`correo.example`), DNI y teléfonos no corresponden a nadie.
- Las **predicciones** son estimaciones y así se indican en pantalla. Ningún resultado, gol ni jugador es inventado.

## Aviso

Proyecto personal de Héctor (@hectormtudela). Sin licencia de reutilización: todos los derechos reservados, salvo lo que permiten las condiciones de GitHub (ver y bifurcar el repositorio). Los datos pertenecen a sus fuentes.
