/* =============================================================================
   08_web.sql
   Goalmetry - Base de datos para la web (carpeta web/)
   Crea lo que necesita la aplicación web, sin tocar nada de los scripts 01-07:
     1. Esquema web y tabla web.Usuario (la cuenta de administrador; solo se guarda
        el hash de la contraseña, nunca la contraseña).
     2. Usuarios WITHOUT LOGIN con los que trabaja la web (mínimo privilegio):
          web_publico -> solo lectura de la liga y búsqueda/IA.
          web_admin   -> lo anterior + los procedimientos de alta y edición.
        La web se conecta con Windows y hace EXECUTE AS USER con uno de ellos.
     3. Procedimientos web.usp_* con los que el administrador mete datos. Validan
        todo antes de escribir; los errores son THROW 50401-50430 con un mensaje
        en español que la web enseña tal cual.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\08_web.sql
   Idempotente: se puede ejecutar las veces que haga falta. No borra la cuenta de
   administrador si ya existe.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

IF SCHEMA_ID(N'web') IS NULL EXEC (N'CREATE SCHEMA web AUTHORIZATION dbo;');
GO

/* ---------- 1. Tabla de usuarios de la web ---------- */
IF OBJECT_ID(N'web.Usuario', N'U') IS NULL
CREATE TABLE web.Usuario
(
    UsuarioID        INT IDENTITY(1,1) NOT NULL,
    Nombre           NVARCHAR(50)      NOT NULL,
    HashClave        VARCHAR(255)      NOT NULL,   -- scrypt (werkzeug); nunca la contraseña
    Activo           BIT               NOT NULL CONSTRAINT DF_Usuario_Activo   DEFAULT (1),
    IntentosFallidos TINYINT           NOT NULL CONSTRAINT DF_Usuario_Intentos DEFAULT (0),
    BloqueadoHasta   DATETIME2(0)      NULL,
    UltimoAcceso     DATETIME2(0)      NULL,
    FechaAlta        DATETIME2(0)      NOT NULL CONSTRAINT DF_Usuario_Alta     DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_Usuario        PRIMARY KEY (UsuarioID),
    CONSTRAINT UQ_Usuario_Nombre UNIQUE (Nombre),
    CONSTRAINT CK_Usuario_Nombre CHECK (LEN(Nombre) >= 3)
);
GO

/* ---------- 2. Usuarios y roles de la web ----------
   Los nombres no empiezan por u_ para no mezclarse con los usuarios del Bloque C. */
IF DATABASE_PRINCIPAL_ID(N'web_publico') IS NULL CREATE USER web_publico WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'web_admin')   IS NULL CREATE USER web_admin   WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NULL CREATE ROLE rol_web_publico;
IF DATABASE_PRINCIPAL_ID(N'rol_web_admin')   IS NULL CREATE ROLE rol_web_admin;
GO
IF IS_ROLEMEMBER(N'rol_web_publico', N'web_publico') = 0 ALTER ROLE rol_web_publico ADD MEMBER web_publico;
IF IS_ROLEMEMBER(N'rol_web_publico', N'web_admin')   = 0 ALTER ROLE rol_web_publico ADD MEMBER web_admin;
IF IS_ROLEMEMBER(N'rol_web_admin',   N'web_admin')   = 0 ALTER ROLE rol_web_admin   ADD MEMBER web_admin;
GO

-- Público: leer la liga (no la auditoría ni las ventas) y usar la búsqueda y el RAG.
GRANT SELECT  ON SCHEMA::liga TO rol_web_publico;
DENY  SELECT  ON OBJECT::liga.PartidoAuditoria TO rol_web_publico;
DENY  SELECT  ON SCHEMA::ventas TO rol_web_publico;
GRANT SELECT  ON OBJECT::ia.Documento TO rol_web_publico;
GRANT EXECUTE ON SCHEMA::ia   TO rol_web_publico;   -- usp_BuscarDocumentos, usp_PreguntarLiga
GRANT EXECUTE ON OBJECT::liga.usp_ClasificacionHastaJornada TO rol_web_publico;
-- La búsqueda y el RAG llaman a Ollama: hace falta el permiso de llamar a endpoints externos.
GRANT EXECUTE ANY EXTERNAL ENDPOINT TO rol_web_publico;
-- ...y usar el modelo de embeddings. Si aún no existe (instalación sin -IA), lo da
-- ai\create_external_model.sql cuando lo crea.
IF EXISTS (SELECT 1 FROM sys.external_models WHERE name = N'bge_m3_ollama')
    GRANT EXECUTE ON EXTERNAL MODEL::bge_m3_ollama TO rol_web_publico;
-- Admin: solo escribe a través de procedimientos (no tiene INSERT/UPDATE/DELETE directos).
GRANT EXECUTE ON SCHEMA::web TO rol_web_admin;
GRANT EXECUTE ON OBJECT::liga.usp_RegistrarResultado TO rol_web_admin;
GO

/* ---------- 3. Acceso del administrador ---------- */

-- Datos para comprobar el inicio de sesión (la comparación del hash la hace la web).
CREATE OR ALTER PROCEDURE web.usp_DatosAcceso
    @Nombre NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UsuarioID, Nombre, HashClave, Activo,
           CASE WHEN BloqueadoHasta > SYSDATETIME() THEN BloqueadoHasta END AS BloqueadoHasta
    FROM web.Usuario
    WHERE Nombre = @Nombre;
END;
GO

-- Apunta el resultado de un intento: 5 fallos seguidos bloquean la cuenta 15 minutos.
CREATE OR ALTER PROCEDURE web.usp_RegistrarAcceso
    @Nombre NVARCHAR(50),
    @Exito  BIT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Exito = 1
        UPDATE web.Usuario
        SET IntentosFallidos = 0, BloqueadoHasta = NULL, UltimoAcceso = SYSDATETIME()
        WHERE Nombre = @Nombre;
    ELSE
        UPDATE web.Usuario
        SET IntentosFallidos = CASE WHEN IntentosFallidos >= 4 THEN 0 ELSE IntentosFallidos + 1 END,
            BloqueadoHasta   = CASE WHEN IntentosFallidos >= 4 THEN DATEADD(MINUTE, 15, SYSDATETIME()) END
        WHERE Nombre = @Nombre;
END;
GO

-- Crea o cambia la cuenta de administrador. Solo lo ejecuta dbo (web/crear_admin.py):
-- no se da permiso a los usuarios de la web. Hay una sola cuenta.
CREATE OR ALTER PROCEDURE web.usp_GuardarAdmin
    @Nombre    NVARCHAR(50),
    @HashClave VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    IF LEN(@HashClave) < 20
        THROW 50430, N'Hash de contraseña no válido.', 1;
    IF EXISTS (SELECT 1 FROM web.Usuario)
        UPDATE web.Usuario
        SET Nombre = @Nombre, HashClave = @HashClave, Activo = 1, IntentosFallidos = 0, BloqueadoHasta = NULL;
    ELSE
        INSERT INTO web.Usuario (Nombre, HashClave) VALUES (@Nombre, @HashClave);
END;
GO
DENY EXECUTE ON OBJECT::web.usp_GuardarAdmin TO rol_web_admin;   -- ni siquiera desde la web
GRANT EXECUTE ON OBJECT::web.usp_DatosAcceso    TO rol_web_publico;
GRANT EXECUTE ON OBJECT::web.usp_RegistrarAcceso TO rol_web_publico;
GO

/* ---------- 4. Alta y edición de datos de la liga ---------- */

-- Nueva jornada de la temporada actual (la última creada).
CREATE OR ALTER PROCEDURE web.usp_CrearJornada
    @Numero TINYINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @TemporadaID SMALLINT = (SELECT MAX(TemporadaID) FROM liga.Temporada);
    IF @Numero IS NULL OR @Numero NOT BETWEEN 1 AND 38
        THROW 50401, N'El número de jornada debe estar entre 1 y 38.', 1;
    IF EXISTS (SELECT 1 FROM liga.Jornada WHERE TemporadaID = @TemporadaID AND Numero = @Numero)
        THROW 50402, N'Esa jornada ya existe.', 1;
    INSERT INTO liga.Jornada (TemporadaID, Numero) VALUES (@TemporadaID, @Numero);
END;
GO

-- Nuevo partido programado. El estadio es siempre el del equipo local.
CREATE OR ALTER PROCEDURE web.usp_CrearPartido
    @JornadaID   INT,
    @LocalID     INT,
    @VisitanteID INT,
    @FechaHora   DATETIME2(0) = NULL,
    @ArbitroID   INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @EstadioID INT = (SELECT EstadioID FROM liga.Estadio WHERE EquipoID = @LocalID);
    IF NOT EXISTS (SELECT 1 FROM liga.Jornada WHERE JornadaID = @JornadaID)
        THROW 50403, N'La jornada no existe.', 1;
    IF @LocalID = @VisitanteID
        THROW 50404, N'Un equipo no puede jugar contra sí mismo.', 1;
    IF @EstadioID IS NULL OR NOT EXISTS (SELECT 1 FROM liga.Equipo WHERE EquipoID = @VisitanteID)
        THROW 50405, N'Equipo no válido.', 1;
    IF EXISTS (SELECT 1 FROM liga.Partido
               WHERE JornadaID = @JornadaID
                 AND (EquipoLocalID IN (@LocalID, @VisitanteID) OR EquipoVisitanteID IN (@LocalID, @VisitanteID)))
        THROW 50406, N'Alguno de los dos equipos ya tiene partido en esa jornada.', 1;
    INSERT INTO liga.Partido (JornadaID, EquipoLocalID, EquipoVisitanteID, EstadioID, ArbitroPrincipalID, FechaHora)
    VALUES (@JornadaID, @LocalID, @VisitanteID, @EstadioID, @ArbitroID, @FechaHora);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS PartidoID;
END;
GO

-- Cambia la fecha y el árbitro de un partido (no el marcador: eso va por liga.usp_RegistrarResultado).
CREATE OR ALTER PROCEDURE web.usp_EditarPartido
    @PartidoID INT,
    @FechaHora DATETIME2(0) = NULL,
    @ArbitroID INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM liga.Partido WHERE PartidoID = @PartidoID)
        THROW 50407, N'El partido no existe.', 1;
    UPDATE liga.Partido SET FechaHora = @FechaHora, ArbitroPrincipalID = @ArbitroID
    WHERE PartidoID = @PartidoID;
END;
GO

-- Borra un partido creado por error: solo si sigue programado y nada depende de él.
CREATE OR ALTER PROCEDURE web.usp_BorrarPartido
    @PartidoID INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM liga.Partido WHERE PartidoID = @PartidoID AND Estado = 'Programado')
        THROW 50408, N'Solo se pueden borrar partidos que siguen programados.', 1;
    IF EXISTS (SELECT 1 FROM ventas.Entrada  WHERE PartidoID = @PartidoID)
       OR EXISTS (SELECT 1 FROM ia.Documento WHERE PartidoID = @PartidoID)
       OR EXISTS (SELECT 1 FROM liga.PartidoAuditoria WHERE PartidoID = @PartidoID)
        THROW 50409, N'No se puede borrar: el partido tiene entradas, documentos o historial.', 1;
    DELETE FROM liga.Partido WHERE PartidoID = @PartidoID;
END;
GO

-- Añade un gol. Comprueba que encaja con el marcador ya registrado.
--   Normal / Penalti: el jugador (si se indica) es del equipo que marca.
--   PropiaPuerta:     el gol cuenta para @EquipoID y el jugador es del rival.
CREATE OR ALTER PROCEDURE web.usp_AnadirGol
    @PartidoID INT,
    @EquipoID  INT,
    @Minuto    TINYINT,
    @Tipo      VARCHAR(12)   = 'Normal',
    @JugadorID INT           = NULL,
    @Anotador  NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Local INT, @Visitante INT, @GL TINYINT, @GV TINYINT, @Estado VARCHAR(12), @EquipoJugador INT;

    BEGIN TRANSACTION;
    SELECT @Local = EquipoLocalID, @Visitante = EquipoVisitanteID,
           @GL = GolesLocal, @GV = GolesVisitante, @Estado = Estado
    FROM liga.Partido WITH (UPDLOCK, HOLDLOCK)
    WHERE PartidoID = @PartidoID;

    IF @Estado IS NULL
        THROW 50410, N'El partido no existe.', 1;
    IF @Estado = 'Programado'
        THROW 50411, N'Primero hay que registrar el marcador del partido.', 1;
    IF @EquipoID NOT IN (@Local, @Visitante)
        THROW 50412, N'El equipo no juega este partido.', 1;
    IF @Tipo IS NULL OR @Tipo NOT IN ('Normal', 'Penalti', 'PropiaPuerta')
        THROW 50413, N'Tipo de gol no válido.', 1;
    IF @Minuto IS NULL OR @Minuto NOT BETWEEN 1 AND 130
        THROW 50414, N'El minuto debe estar entre 1 y 130.', 1;

    IF @JugadorID IS NOT NULL
    BEGIN
        SELECT @EquipoJugador = EquipoID, @Anotador = Nombre FROM liga.Jugador WHERE JugadorID = @JugadorID;
        IF @EquipoJugador IS NULL
            THROW 50415, N'El jugador no existe.', 1;
        IF (@Tipo <> 'PropiaPuerta' AND @EquipoJugador <> @EquipoID)
           OR (@Tipo = 'PropiaPuerta' AND @EquipoJugador = @EquipoID)
            THROW 50416, N'El jugador no es del equipo correcto (en propia puerta, el jugador es del rival).', 1;
    END;
    SET @Anotador = NULLIF(LTRIM(RTRIM(@Anotador)), N'');
    IF @Anotador IS NULL
        THROW 50417, N'Indica el jugador o escribe el nombre del anotador.', 1;

    IF (SELECT COUNT(*) FROM liga.Gol WHERE PartidoID = @PartidoID AND EquipoID = @EquipoID)
       >= CASE WHEN @EquipoID = @Local THEN @GL ELSE @GV END
        THROW 50418, N'Ese equipo ya tiene todos los goles de su marcador. Corrige antes el resultado.', 1;

    INSERT INTO liga.Gol (PartidoID, EquipoID, JugadorID, Anotador, Minuto, Tipo)
    VALUES (@PartidoID, @EquipoID, @JugadorID, @Anotador, @Minuto, @Tipo);
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE web.usp_BorrarGol
    @GolID INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM liga.Gol WHERE GolID = @GolID;
    IF @@ROWCOUNT = 0
        THROW 50419, N'El gol no existe.', 1;
END;
GO

-- Alta (@JugadorID NULL) o edición de un jugador.
CREATE OR ALTER PROCEDURE web.usp_GuardarJugador
    @JugadorID      INT           = NULL,
    @EquipoID       INT,
    @Nombre         NVARCHAR(100),
    @Posicion       CHAR(2)       = NULL,
    @MinutosJugados INT           = 0,
    @Goles          SMALLINT      = 0,
    @Asistencias    SMALLINT      = 0,
    @UltimaJornada  TINYINT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Nombre = NULLIF(LTRIM(RTRIM(@Nombre)), N'');
    IF @Nombre IS NULL
        THROW 50420, N'El nombre del jugador es obligatorio.', 1;
    IF NOT EXISTS (SELECT 1 FROM liga.Equipo WHERE EquipoID = @EquipoID)
        THROW 50421, N'Equipo no válido.', 1;
    IF @Posicion IS NOT NULL AND @Posicion NOT IN ('PT', 'DF', 'MC', 'DL')
        THROW 50422, N'Posición no válida (PT, DF, MC o DL).', 1;
    IF @MinutosJugados < 0 OR @Goles < 0 OR @Asistencias < 0
        THROW 50423, N'Los minutos, goles y asistencias no pueden ser negativos.', 1;

    IF @JugadorID IS NULL
    BEGIN
        INSERT INTO liga.Jugador (EquipoID, Nombre, Posicion, MinutosJugados, Goles, Asistencias, UltimaJornada)
        VALUES (@EquipoID, @Nombre, @Posicion, @MinutosJugados, @Goles, @Asistencias, @UltimaJornada);
    END
    ELSE
    BEGIN
        UPDATE liga.Jugador
        SET EquipoID = @EquipoID, Nombre = @Nombre, Posicion = @Posicion, MinutosJugados = @MinutosJugados,
            Goles = @Goles, Asistencias = @Asistencias, UltimaJornada = @UltimaJornada
        WHERE JugadorID = @JugadorID;
        IF @@ROWCOUNT = 0
            THROW 50424, N'El jugador no existe.', 1;
    END;
END;
GO

CREATE OR ALTER PROCEDURE web.usp_CrearArbitro
    @Nombre NVARCHAR(80)
AS
BEGIN
    SET NOCOUNT ON;
    SET @Nombre = NULLIF(LTRIM(RTRIM(@Nombre)), N'');
    IF @Nombre IS NULL
        THROW 50425, N'El nombre del árbitro es obligatorio.', 1;
    IF EXISTS (SELECT 1 FROM liga.Arbitro WHERE Nombre = @Nombre)
        THROW 50426, N'Ese árbitro ya existe.', 1;
    INSERT INTO liga.Arbitro (Nombre) VALUES (@Nombre);
END;
GO

/* ============================== Comprobación ============================== */
SELECT p.name AS Principal, p.type_desc AS Tipo,
       STRING_AGG(r.name, N', ') AS Roles
FROM sys.database_principals AS p
LEFT JOIN sys.database_role_members AS m ON m.member_principal_id = p.principal_id
LEFT JOIN sys.database_principals  AS r ON r.principal_id = m.role_principal_id
WHERE p.name IN (N'web_publico', N'web_admin')
GROUP BY p.name, p.type_desc;

SELECT o.name AS Procedimiento FROM sys.procedures AS o
WHERE o.schema_id = SCHEMA_ID(N'web') ORDER BY o.name;

SELECT COUNT(*) AS CuentasAdmin FROM web.Usuario;

-- Prueba de mínimo privilegio: web_publico no puede escribir ni ver las ventas.
DECLARE @Pruebas TABLE (Caso NVARCHAR(80), Esperado NVARCHAR(20), Obtenido NVARCHAR(20));
EXECUTE AS USER = N'web_publico';
BEGIN TRY DECLARE @n INT = (SELECT COUNT(*) FROM liga.Partido);
          INSERT @Pruebas VALUES (N'web_publico lee liga.Partido', N'Sin error', N'Sin error'); END TRY
BEGIN CATCH INSERT @Pruebas VALUES (N'web_publico lee liga.Partido', N'Sin error', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
BEGIN TRY DECLARE @a INT = (SELECT COUNT(*) FROM ventas.Abonado);
          INSERT @Pruebas VALUES (N'web_publico lee ventas.Abonado', N'Error 229', N'Sin error'); END TRY
BEGIN CATCH INSERT @Pruebas VALUES (N'web_publico lee ventas.Abonado', N'Error 229', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
BEGIN TRY EXEC web.usp_CrearArbitro @Nombre = N'(prueba)';
          INSERT @Pruebas VALUES (N'web_publico ejecuta web.usp_CrearArbitro', N'Error 229', N'Sin error'); END TRY
BEGIN CATCH INSERT @Pruebas VALUES (N'web_publico ejecuta web.usp_CrearArbitro', N'Error 229', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
REVERT;
EXECUTE AS USER = N'web_admin';
BEGIN TRY UPDATE liga.Partido SET FechaHora = FechaHora WHERE PartidoID = 1;
          INSERT @Pruebas VALUES (N'web_admin hace UPDATE directo', N'Error 229', N'Sin error'); END TRY
BEGIN CATCH INSERT @Pruebas VALUES (N'web_admin hace UPDATE directo', N'Error 229', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
BEGIN TRY EXEC web.usp_GuardarAdmin @Nombre = N'x', @HashClave = 'x';
          INSERT @Pruebas VALUES (N'web_admin cambia la cuenta de admin', N'Error 229', N'Sin error'); END TRY
BEGIN CATCH INSERT @Pruebas VALUES (N'web_admin cambia la cuenta de admin', N'Error 229', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
REVERT;
SELECT Caso, Esperado, Obtenido, CASE WHEN Esperado = Obtenido THEN N'Correcto' ELSE N'FALLO' END AS Resultado FROM @Pruebas;
IF EXISTS (SELECT 1 FROM @Pruebas WHERE Esperado <> Obtenido)
    THROW 50431, N'Fallan las pruebas de permisos de la web.', 1;
GO
