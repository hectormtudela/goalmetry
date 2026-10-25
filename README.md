# LigaDB · Liga Española de Fútbol inteligente con SQL Server 2025

Base de datos de la **temporada 2026-27 de LaLiga (jornadas 1-10)** construida sobre **SQL Server 2025**: modelo relacional, T-SQL avanzado y, en las fases siguientes, seguridad, optimización, embeddings, búsqueda semántica y preguntas y respuestas (RAG) con modelos que se ejecutan **en tu propio equipo**.

Mini-proyecto de la Práctica 09 (DP-800) del Máster en Big Data & IA (Tajamar) · Nivel 3 (avanzado).

**Todo es local y gratuito:** SQL Server 2025 Developer, sqlcmd, Ollama. No se usa Azure ni ningún servicio de pago, y el repositorio no contiene contraseñas ni claves (se usa autenticación de Windows).

## Estado del proyecto

| Bloque | Contenido | Estado |
|---|---|---|
| A · Diseño y T-SQL | Tablas, carga de datos, vistas, función, procedimientos, trigger, consultas avanzadas | ✅ Terminado |
| B · SQL con ayuda de IA | Registro en [`docs/ia-log.md`](docs/ia-log.md) | 🔄 Se completa en cada bloque |
| C · Seguridad | Roles, permisos, Row-Level Security, enmascaramiento dinámico | ⏳ Pendiente |
| D · Optimización | Plan de ejecución e índice antes/después | ⏳ Pendiente |
| E · Embeddings | `bge-m3` (Ollama) -> columna `VECTOR(1024)` | ⏳ Pendiente |
| F · Búsqueda inteligente | Vectorial, full-text en español e híbrida | ⏳ Pendiente |
| G · RAG | Preguntas en lenguaje natural con `qwen2.5:3b` | ⏳ Pendiente |

Ahora mismo se puede instalar y usar todo el Bloque A. Este README se irá ampliando con cada bloque.

## Qué hay en la base de datos

| Tabla | Filas | Contenido |
|---|---:|---|
| `liga.Temporada` | 1 | 2026-27 |
| `liga.Equipo` / `liga.Estadio` | 20 / 20 | Los 20 equipos y su estadio |
| `liga.Arbitro` | 21 | Árbitros de la temporada |
| `liga.Jornada` / `liga.Partido` | 10 / 100 | J1-J9 completas; J10 con 3 partidos jugados y 7 programados |
| `liga.Jugador` | 452 | Plantillas con minutos, goles y asistencias |
| `liga.Gol` | 279 | Cada gol: anotador, minuto y tipo (normal, penalti, propia puerta) |
| `liga.PartidoAuditoria` | 0 | Historial de cambios de resultado (lo rellena un trigger) |
| `ventas.Abonado` | 2.000 | **Ficticios**, generados por script |
| `ventas.Entrada` | 200.824 | **Ficticias**, generadas por script |
| `ia.Documento` | 0 | Se rellenará en el Bloque E |

Objetos para consultar y trabajar con los datos:

| Objeto | Para qué sirve |
|---|---|
| `liga.vw_Clasificacion` | Tabla de clasificación actual |
| `liga.vw_MaximosGoleadores` | Ranking de goleadores |
| `liga.fn_PuntosEquipo(@EquipoID, @HastaJornada)` | Puntos de un equipo hasta una jornada |
| `liga.usp_ClasificacionHastaJornada @HastaJornada` | Clasificación tal como estaba tras cualquier jornada |
| `liga.usp_RegistrarResultado` | Registrar o corregir un resultado (con validación y auditoría) |

El modelo completo, con su diagrama, está en [`docs/modelo-datos.md`](docs/modelo-datos.md).

## Requisitos

| Necesitas | Notas |
|---|---|
| Windows 10 u 11 | Probado en Windows 10 Home |
| **SQL Server 2025** (versión 17), instancia **local** | La edición **Developer** es gratuita. Probado en 17.0.1000.7 (RTM). Las versiones anteriores no sirven: el proyecto usa `VECTOR`, `REGEXP_LIKE`, `JSON_ARRAYAGG` y `EDIT_DISTANCE` |
| Tu usuario de Windows con permiso para crear bases de datos | Lo normal en una instalación propia es ser `sysadmin`. Si no, se necesitan `dbcreator` + `bulkadmin` |
| **sqlcmd** | `winget install sqlcmd`, o el que instala SQL Server |
| Git y PowerShell | PowerShell 5.1 (el que trae Windows) o 7 |
| SSMS 22 (opcional) | Para explorar la BD con interfaz gráfica |

Para los bloques E, F y G (cuando estén terminados) hará falta además: la característica **Full-Text Search** de SQL Server, **Ollama** con los modelos `bge-m3` y `qwen2.5:3b`, y **Caddy** como proxy HTTPS local (SQL Server solo llama a modelos externos por HTTPS). La configuración de Caddy está en [`ai/https/Caddyfile`](ai/https/Caddyfile).

## Instalación rápida (un solo comando)

```powershell
git clone https://github.com/hectormtudela/goalmetry goalmetry
cd goalmetry
powershell -ExecutionPolicy Bypass -File .\instalar.ps1
```

El script [`instalar.ps1`](instalar.ps1):
1. Comprueba que `sqlcmd` existe, que te puedes conectar y que el servidor es SQL Server 2025.
2. Te avisa y **pide confirmación** si `LigaDB` ya existe, porque la borra y la vuelve a crear. **Solo toca `LigaDB`**, ninguna otra base de datos.
3. Ejecuta en orden todos los scripts `database/0*.sql` y se para en el primer error.
4. Muestra cuántas filas tiene cada tabla. En un equipo normal tarda unos segundos.

Opciones:

| Opción | Qué hace |
|---|---|
| `-Servidor "localhost\NOMBRE"` | Usa una instancia con nombre (por defecto, `localhost`) |
| `-Consultas` | Al final ejecuta también `database/consultas_avanzadas.sql` (solo lectura) |
| `-IA` | Ejecuta también los scripts de `ai/` (requiere Ollama y Caddy; bloques E-G) |
| `-Forzar` | No pide confirmación antes de volver a crear `LigaDB` |

`-ExecutionPolicy Bypass` solo afecta a esa ejecución: permite lanzar un script descargado sin cambiar la configuración de tu equipo.

## Instalación manual (script a script)

Si prefieres ver cada paso, ejecuta desde la raíz del repositorio, en este orden:

```powershell
sqlcmd -S localhost -E -C -b -i database\01_create_database.sql
sqlcmd -S localhost -E -C -b -i database\02_create_tables.sql
sqlcmd -S localhost -E -C -b -v DataPath="$PWD\data" -i database\03_insert_data.sql
sqlcmd -S localhost -E -C -b -i database\04_views_functions.sql
sqlcmd -S localhost -E -C -b -i database\05_procedures_triggers.sql
sqlcmd -S localhost -E -C -b -i database\consultas_avanzadas.sql     # opcional, solo lectura
```

- `-E`: autenticación de Windows (sin contraseña) · `-C`: confía en el certificado local del servidor · `-b`: devuelve un error si algo falla.
- `03_insert_data.sql` recibe la ruta de los CSV con `-v DataPath=...`; no hay rutas fijas dentro de los scripts.
- **Desde SSMS:** activa *Consulta > Modo SQLCMD* y, en `03_insert_data.sql`, añade al principio `:setvar DataPath "C:\ruta\al\repo\data"`.
- Todos los scripts se pueden ejecutar varias veces: el resultado es siempre el mismo.

## Primeras consultas para probar

```sql
USE LigaDB;

-- Clasificación actual
SELECT * FROM liga.vw_Clasificacion ORDER BY Posicion;

-- Top 10 goleadores
SELECT TOP (10) * FROM liga.vw_MaximosGoleadores ORDER BY Posicion;

-- ¿Cómo iba la liga tras la jornada 5?
EXEC liga.usp_ClasificacionHastaJornada @HastaJornada = 5;

-- Puntos del Barcelona jornada a jornada
SELECT j.Numero, liga.fn_PuntosEquipo(e.EquipoID, j.Numero) AS Puntos
FROM liga.Jornada AS j CROSS JOIN liga.Equipo AS e
WHERE e.NombreCorto = N'Barcelona'
ORDER BY j.Numero;

-- Partidos de la jornada 10 que faltan por jugar
SELECT p.PartidoID, el.Nombre AS Local, ev.Nombre AS Visitante, p.FechaHora
FROM liga.Partido AS p
JOIN liga.Jornada AS j  ON j.JornadaID = p.JornadaID
JOIN liga.Equipo  AS el ON el.EquipoID = p.EquipoLocalID
JOIN liga.Equipo  AS ev ON ev.EquipoID = p.EquipoVisitanteID
WHERE j.Numero = 10 AND p.Estado = 'Programado';

-- Probar a registrar un resultado sin dejarlo guardado (marcador inventado):
BEGIN TRANSACTION;
    EXEC liga.usp_RegistrarResultado @PartidoID = 94, @GolesLocal = 2, @GolesVisitante = 1;
    SELECT * FROM liga.PartidoAuditoria;                      -- el trigger ha guardado el cambio
    SELECT * FROM liga.vw_Clasificacion ORDER BY Posicion;    -- la clasificación ya lo refleja
ROLLBACK TRANSACTION;                                         -- y aquí se deshace
```

En [`database/consultas_avanzadas.sql`](database/consultas_avanzadas.sql) hay más ejemplos: posición de cada equipo tras cada jornada, goles por 90 minutos, fichas de partido en JSON, validación con expresiones regulares y búsqueda aproximada de nombres. Puedes ejecutar y modificar lo que quieras: si rompes algo, `instalar.ps1` deja la base de datos como nueva en unos segundos.

## Estructura del repositorio

```
goalmetry/
├── instalar.ps1               Instalación completa en un solo paso
├── data/                      CSV verificados de la temporada (J1-J10) + LEEME-datos.md
├── database/                  Scripts SQL numerados (01 -> 05) + consultas_avanzadas.sql
├── ai/https/Caddyfile         Proxy HTTPS local delante de Ollama (bloques E-G)
├── docs/
│   ├── README.md              Cómo se ha hecho el proyecto y por qué se decidió cada cosa
│   ├── modelo-datos.md        Modelo de datos y diagrama
│   ├── verificacion.md        Fuentes y comprobaciones de los datos
│   ├── ia-log.md              Registro del desarrollo asistido por IA
│   └── plan.md                Plan de trabajo y estado de cada bloque
├── tests/                     (pendiente) pruebas automáticas
└── presentation/              (pendiente) presentación
```

## Sobre los datos

- **Datos reales (temporada 2026-27, J1-J10)**, extraídos y verificados a mano el 24/10/2026 en estas fuentes:
  - [futbolfantasy.com](https://www.futbolfantasy.com): calendario, resultados, fechas, árbitros y goles de cada partido.
  - [matchscan.co](https://matchscan.co): jugadores, posiciones, minutos, goles y asistencias.
  - [Wikipedia](https://en.wikipedia.org/wiki/2026%E2%80%9327_La_Liga): ciudades, estadios y capacidades.

  Las comprobaciones que se hicieron y las limitaciones conocidas están en [`docs/verificacion.md`](docs/verificacion.md). Ningún resultado, gol ni jugador es inventado.
- **Datos ficticios:** solo `ventas.Abonado` y `ventas.Entrada`. Los genera `03_insert_data.sql` con una semilla fija, así que salen idénticos en cada instalación. Los nombres son combinaciones aleatorias; los emails usan el dominio reservado `correo.example`, y los DNI y teléfonos tienen formato válido pero no corresponden a nadie.
- La temporada está **en curso**: la J10 está incompleta y algunas estadísticas de jugadores llegan solo hasta la J9 (columna `Jugador.UltimaJornada`).

## Solución de problemas

| Síntoma | Solución |
|---|---|
| `No se encuentra 'sqlcmd'` | `winget install sqlcmd` y abre una consola nueva |
| No conecta con `localhost` | Comprueba que el servicio *SQL Server (MSSQLSERVER)* está iniciado. Si tu instancia tiene nombre, usa `-Servidor "localhost\NOMBRE"` |
| Error de certificado al conectar | Asegúrate de usar `-C` (los comandos de este README ya lo incluyen) |
| Error 4861 / «código de error del sistema operativo 5» en `03_insert_data.sql` | SQL Server no puede leer la carpeta `data/`. Clona el repositorio en una ruta sencilla (p. ej. `C:\LigaDB`) o dale permiso de lectura: `icacls .\data /grant "NT Service\MSSQLSERVER:(OI)(CI)R"` |
| `'EDIT_DISTANCE' no es un nombre de función integrada reconocido` | Ejecuta antes `01_create_database.sql`, que activa `PREVIEW_FEATURES` en `LigaDB` (estas funciones están en vista previa en la RTM) |
| `instalar.ps1 no se puede cargar porque la ejecución de scripts está deshabilitada` | Lánzalo como se indica arriba: `powershell -ExecutionPolicy Bypass -File .\instalar.ps1` |
| Error de permisos al crear la base de datos | Tu usuario de Windows necesita `sysadmin`, o `dbcreator` + `bulkadmin`, en la instancia |

## Documentación

- [`docs/README.md`](docs/README.md): **cómo se ha desarrollado el proyecto** y por qué se eligió cada tecnología y cada decisión de diseño.
- [`docs/modelo-datos.md`](docs/modelo-datos.md) · [`docs/verificacion.md`](docs/verificacion.md) · [`docs/ia-log.md`](docs/ia-log.md)

---
