# Goalmetry · la web

Goalmetry es la página web para consultar la base de datos LigaDB sin abrir ninguna consola. Tiene además un panel de administración para hacer correcciones en tu instalación; los datos nuevos llegan por los CSV de `data/` (ver más abajo).

## Cómo se usa

### Abrirla
1. Doble clic en **`iniciar-web.bat`**.
2. La primera vez tarda un minuto, porque prepara Python. Las siguientes veces arranca al momento.
3. Se abre el navegador en **http://localhost:8080**.
4. Para cerrarla, cierra la ventana negra que se ha abierto.

El `.bat` también enciende Caddy, el puente HTTPS de la IA, si no lo estaba. Ollama tiene que estar abierto, igual que para el resto del proyecto. Si no lo está, la web funciona igual y solo avisa de que el buscador inteligente y las preguntas no están disponibles.

### Qué hay en cada pantalla

| Pantalla | Para qué sirve |
|---|---|
| **Clasificación** | La tabla de la liga y los máximos goleadores. El desplegable enseña cómo iba la liga tras una jornada concreta. |
| **Jornadas** | Los resultados de cada jornada, con quién marcó y en qué minuto. Los partidos sin jugar salen como «Programado». |
| **Predicciones** | Simula 10.000 veces lo que queda de temporada y enseña las opciones de cada equipo. Mientras calcula salen curiosidades reales de la liga. Ver más abajo. |
| **Buscador** | Busca en las crónicas, fichas de equipo, reglamento y preguntas frecuentes. «Por significado» encuentra cosas aunque no uses las mismas palabras; «Por palabras exactas» es una búsqueda normal; «Inteligente + palabras» mezcla las dos. |
| **Pregunta a la IA** | Escribes una pregunta y la IA responde con los datos de la base de datos. Debajo enseña qué documentos ha consultado. Si marcas «Comparar», también ves qué contesta una IA que no consulta la base de datos, y normalmente se equivoca. |
| **Administración** | Solo con usuario y contraseña. Ver más abajo. |

### Predicciones
- **Clasificación prevista:** cada puesto muestra el equipo con más opciones de acabar ahí, y cada equipo sale una sola vez (se reparte empezando por la pareja equipo-puesto más probable). Si pulsas una fila, ves todos los candidatos a ese puesto. En la zona media las opciones son muy parecidas, así que el orden puede no coincidir con el de la columna de puntos: es normal.
- **¿Y si...?:** eliges hasta 3 resultados de partidos que faltan y la tabla se recalcula al momento, con las temporadas simuladas en las que pasó eso.
- **Evolución:** cómo han cambiado las opciones de un equipo jornada a jornada.
- **Volver a simular:** cada simulación usa una semilla nueva, así que las cifras varían alrededor de 1 punto. Es el azar de la simulación, no un cambio en los datos.

Son estimaciones, no resultados reales. Al final de la página está cómo se calculan y cuánto fiarse.

### Pantallas de análisis y asistente

Están explicadas en la sección «Pantallas nuevas» del README de la raíz. Sus pruebas: `tests\tests_analisis.sql`, `tests\tests_pantallas.py` y `tests\tests_asistente.py`. Las de la IA: `tests\tests_temas.sql` (sin modelo) y `tests\intenciones_evaluacion.sql` (solo embeddings).

### La cuenta de administrador
Solo hay una cuenta y se crea así:
1. Abre la web una vez con `iniciar-web.bat` y ciérrala.
2. Doble clic en **`crear-admin.bat`**.
3. Escribe un usuario y una contraseña de al menos 10 caracteres. La contraseña no se ve mientras la escribes.

Si la vuelves a ejecutar, **cambia** la cuenta: sirve para cambiar la contraseña o recuperarla si se te olvida.

La contraseña no se guarda en ningún sitio. En la base de datos solo queda una «huella» (un *hash*) a partir de la cual no se puede sacar la contraseña. Tras 5 intentos fallidos seguidos, la cuenta se bloquea 15 minutos.

### Qué puede hacer el administrador
- **Crear jornadas nuevas** (de la 1 a la 38).
- **Añadir partidos a una jornada**: local, visitante, fecha y árbitro. El estadio se pone solo, porque es el del equipo local. No deja que un equipo juegue dos veces en la misma jornada.
- **Meter el resultado** de un partido programado, o corregir uno ya jugado (hay que marcar una casilla de confirmación).
- **Apuntar los goles**: minuto, jugador y tipo (normal, penalti o en propia puerta). No deja apuntar más goles de los que dice el marcador.
- **Cambiar la fecha o el árbitro** de un partido, y **borrar un partido** creado por error (solo si aún no se ha jugado).
- **Dar de alta y editar jugadores** con sus estadísticas, y **añadir árbitros**.

El panel avisa de dos cosas: los partidos que están **pendientes de resultado** y los partidos jugados donde **faltan goleadores** por apuntar. Con los datos actuales (J1-J10 completas) las dos listas están vacías.

Todo cambio de un marcador queda en la auditoría del proyecto (`liga.PartidoAuditoria`), con la marca `web_admin`.

## Importante: el panel no es la vía principal para meter datos
La fuente de verdad de Goalmetry son los **CSV de `data/`**: las jornadas nuevas se publican ahí, y cada usuario las carga con `git pull` y `actualizar.ps1`. El panel de administración sirve para corregir algo o hacer pruebas en tu propia instalación, pero lo que metas desde él **solo existe en tu base de datos**:

- `actualizar.ps1` compara la base de datos con los CSV. Si encuentra filas que no están en los CSV (por ejemplo, un partido o un árbitro creado desde el panel), **se para sin cambiar nada** y te enseña cuáles son. Para seguir, o las añades a los CSV, o reinstalas.
- `instalar.ps1` borra LigaDB y la vuelve a crear desde los CSV, así que se pierde lo metido desde la web y también la cuenta de administrador (se vuelve a crear con `crear-admin.bat`).

Para hacer pruebas sin miedo, `tests\tests_web.sql` lo comprueba todo y lo deshace al final.

## Cómo funciona por dentro

```
Navegador ──► web (Python + Flask, en este ordenador) ──► SQL Server (LigaDB)
                                                             │
                                                             └──► Caddy ──► Ollama (IA local)
```

- **`app.py`**: las páginas y los formularios.
- **`db.py`**: la conexión a SQL Server, que usa tu usuario de Windows (no hay contraseñas de la base de datos).
- **`templates/`**: el HTML de cada página.
- **`static/`**: estilos con los colores de la presentación, JavaScript y el icono.
- **`database\08_web.sql`**: lo que la web necesita dentro de LigaDB.
- **`database\09_simulacion.sql`**: el motor de las predicciones.

### Seguridad (pensada para cuando sea pública)
- **Mínimo privilegio.** La web nunca trabaja como administrador de la base de datos. Cada petición se ejecuta como uno de estos dos usuarios:
  - `web_publico`: solo puede leer la liga y usar la búsqueda. No puede ver las ventas ni la auditoría.
  - `web_admin`: además puede ejecutar los procedimientos `web.usp_*`. **No tiene permiso para escribir directamente en las tablas**: todo pasa por procedimientos que validan los datos antes de guardarlos.

  Aunque alguien encontrara un fallo en la web, no podría tocar las ventas ni la seguridad.
- **Formularios protegidos contra CSRF.** Cada formulario lleva un código secreto de la sesión, para que otra web no pueda enviar formularios en tu nombre.
- **Límites de uso.** Hay un máximo de búsquedas y preguntas por minuto, y la IA atiende una pregunta cada vez (corre en tu ordenador).
- **Solo escucha en este ordenador** (`127.0.0.1`). Nadie de tu red puede entrar.
- **Sin secretos en el repositorio.** La clave que firma las sesiones se genera sola la primera vez y se guarda en `web/.env`, que git ignora.

### Pruebas
```powershell
sqlcmd -S localhost -E -C -b -i tests\tests_web.sql
```
Hace 24 pruebas: un recorrido completo (jornada, partido, resultado, goles, jugador y árbitro) más todos los errores que debe rechazar. No deja nada guardado.

### Configuración opcional (`web/.env`)
| Variable | Para qué | Por defecto |
|---|---|---|
| `LALIGADB_PUERTO` | Puerto de la web | `8080` |
| `LALIGADB_HOST` | Desde dónde se puede entrar | `127.0.0.1` (solo este ordenador) |
| `LALIGADB_SQL` | Cadena de conexión ODBC | SQL Server local con Windows |
| `LALIGADB_HTTPS` | Pon `1` cuando se sirva por HTTPS | desactivado |
| `LALIGADB_SECRET` | Clave de las sesiones | se genera sola |

## Para publicarla en el futuro
Todo puede seguir funcionando en tu ordenador, incluidos SQL Server, Caddy y Ollama. Solo hace falta un «túnel» que conecte tu dominio con la web, sin abrir puertos del router. Por ejemplo, Cloudflare Tunnel tiene un plan gratuito. Antes de hacerlo habría que:
1. Activar `LALIGADB_HTTPS=1`.
2. Hacer que los límites de uso miren la IP real del visitante, que llega a través del túnel.
3. Asumir que la IA solo responde mientras tu ordenador esté encendido.
