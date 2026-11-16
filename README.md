# Goalmetry

Liga española de fútbol «inteligente» sobre **SQL Server 2025**: clasificación, resultados, fichas de equipo, análisis, predicciones de la temporada y, en la versión completa, búsqueda y preguntas en lenguaje natural con una IA que se ejecuta en tu propio ordenador. Datos reales de la temporada 2026-27 de LaLiga, jornada a jornada.

## Míralo sin instalar nada

**https://hectormtudela.github.io/goalmetry/**

Es una versión de solo lectura: clasificación, jornadas, equipos, análisis, predicciones y «Mi equipo». Cada página dice hasta qué jornada llegan los datos. No incluye el buscador inteligente, las preguntas a la IA ni el panel de administración, que necesitan la versión completa.

## Instalar la versión completa

La versión completa funciona **en tu ordenador**, sin cuentas ni servicios de pago: SQL Server 2025 (edición Developer, gratuita), Python, y la IA con Ollama.

**Necesitas:** Windows 10 u 11 y, para la IA, unos 16 GB de RAM. Sin IA, todo funciona salvo las preguntas y el buscador por significado.

> Esta sección se completa con el instalador de doble clic. De momento, la instalación es con PowerShell, desde la carpeta descargada:

```powershell
powershell -ExecutionPolicy Bypass -File .\instalar.ps1 -IA
web\iniciar-web.bat
```

Necesita SQL Server 2025 (con Full-Text), `sqlcmd`, Python, Ollama (con los modelos `bge-m3` y `qwen2.5:3b`) y Caddy. Para una jornada nueva, actualiza los CSV de `data/` y ejecuta `.\actualizar.ps1`.

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
