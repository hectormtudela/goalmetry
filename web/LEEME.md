# LaLigaDB · la web

Una página web para consultar LaLigaDB sin abrir ninguna consola, y para que el administrador meta los datos nuevos de cada jornada.

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
| **Buscador** | Busca en las crónicas, fichas de equipo, reglamento y preguntas frecuentes. «Por significado» encuentra cosas aunque no uses las mismas palabras; «Por palabras exactas» es una búsqueda normal; «Inteligente + palabras» mezcla las dos. |
| **Pregunta a la IA** | Escribes una pregunta y la IA responde con los datos de la base de datos. Debajo enseña qué documentos ha consultado. Si marcas «Comparar», también ves qué contesta una IA que no consulta la base de datos, y normalmente se equivoca. |
| **Administración** | Solo con usuario y contraseña. Ver más abajo. |

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

El panel avisa de dos cosas: los partidos que están **pendientes de resultado** y los partidos jugados donde **faltan goleadores** por apuntar. Por ejemplo, en el Rayo–Elche (0-3) de la jornada 10 no hay goleadores en los datos originales.

Todo cambio de un marcador queda en la auditoría del proyecto (`liga.PartidoAuditoria`), con la marca `web_admin`.

## Importante: dónde se guardan los datos que metes
Los datos que metas desde la web se guardan en la base de datos LigaDB. Pero **`instalar.ps1` borra LigaDB y la vuelve a crear a partir de los CSV de `data/`**. Si reinstalas, se pierde lo que hayas metido desde la web, y también la cuenta de administrador, que habría que volver a crear con `crear-admin.bat`.

Mientras no exista una opción para exportar a CSV, **no reinstales** si has metido datos que quieras conservar. Para hacer pruebas sin miedo, `tests\tests_web.sql` lo comprueba todo y lo deshace al final.

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
4. Revisar el nombre: «LaLiga» es una marca registrada. Para algo público conviene un nombre propio.
