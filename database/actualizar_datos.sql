/* =============================================================================
   actualizar_datos.sql
   Goalmetry - Actualización incremental de la liga desde los CSV de data\
   Para una LigaDB ya instalada: carga SOLO lo nuevo o lo que ha cambiado en los CSV,
   sin borrar ni recrear la base de datos. Lo ejecuta actualizar.ps1.
     1. Carga los CSV en staging (todo texto), igual que 03_insert_data.sql.
     2. Valida antes de tocar nada: tipos, referencias y que no falte nada.
        Los CSV mandan: si en la base de datos hay filas que no están en los CSV (por
        ejemplo, metidas desde el panel de administración de la web), se para y las
        lista. No borra nada por su cuenta.
     3. En UNA transacción: por cada tabla, inserta las filas nuevas y actualiza solo
        las que han cambiado (así la auditoría solo registra cambios reales).
     4. Comprueba que la base de datos ha quedado igual que los CSV.
   No toca las ventas (ventas.Abonado / ventas.Entrada): son ficticias y fijas.
   Los documentos y embeddings se actualizan después con ai\generate_embeddings.sql.
   Ejecución:  sqlcmd -S localhost -E -C -b -v DataPath="C:\ruta\data" Simular=0 -i database\actualizar_datos.sql
               Simular=1: enseña lo que cambiaría y lo deshace todo (ROLLBACK).
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;
USE LigaDB;
GO

/* ===================== 1. CSV -> staging ===================== */
DROP TABLE IF EXISTS staging.temporadas, staging.equipos, staging.estadios, staging.arbitros,
                     staging.jornadas, staging.partidos, staging.jugadores, staging.goles;

CREATE TABLE staging.temporadas (temporada_id NVARCHAR(20), nombre NVARCHAR(20));
CREATE TABLE staging.equipos    (equipo_id NVARCHAR(20), nombre NVARCHAR(100), nombre_corto NVARCHAR(100), ciudad NVARCHAR(100));
CREATE TABLE staging.estadios   (estadio_id NVARCHAR(20), nombre NVARCHAR(100), capacidad NVARCHAR(20), equipo_id NVARCHAR(20));
CREATE TABLE staging.arbitros   (arbitro_id NVARCHAR(20), nombre NVARCHAR(100));
CREATE TABLE staging.jornadas   (jornada_id NVARCHAR(20), temporada_id NVARCHAR(20), numero NVARCHAR(20));
CREATE TABLE staging.partidos   (partido_id NVARCHAR(20), jornada_id NVARCHAR(20), equipo_local_id NVARCHAR(20),
                                 equipo_visitante_id NVARCHAR(20), estadio_id NVARCHAR(20), arbitro_principal_id NVARCHAR(20),
                                 fecha_hora NVARCHAR(30), goles_local NVARCHAR(20), goles_visitante NVARCHAR(20), estado NVARCHAR(30));
CREATE TABLE staging.jugadores  (jugador_id NVARCHAR(20), equipo_id NVARCHAR(20), nombre NVARCHAR(150), posicion NVARCHAR(10),
                                 minutos_jugados NVARCHAR(20), goles NVARCHAR(20), asistencias NVARCHAR(20), ultima_jornada NVARCHAR(20));
CREATE TABLE staging.goles      (gol_id NVARCHAR(20), partido_id NVARCHAR(20), equipo_id NVARCHAR(20), jugador_id NVARCHAR(20),
                                 anotador NVARCHAR(150), minuto NVARCHAR(20), tipo NVARCHAR(30));

BULK INSERT staging.temporadas FROM '$(DataPath)\temporadas.csv' WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.equipos    FROM '$(DataPath)\equipos.csv'    WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.estadios   FROM '$(DataPath)\estadios.csv'   WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.arbitros   FROM '$(DataPath)\arbitros.csv'   WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.jornadas   FROM '$(DataPath)\jornadas.csv'   WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.partidos   FROM '$(DataPath)\partidos.csv'   WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.jugadores  FROM '$(DataPath)\jugadores.csv'  WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.goles      FROM '$(DataPath)\goles.csv'      WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);

-- Por si un CSV llega con CRLF: el CR quedaría pegado a la última columna.
UPDATE staging.temporadas SET nombre         = REPLACE(nombre,         NCHAR(13), N'');
UPDATE staging.equipos    SET ciudad         = REPLACE(ciudad,         NCHAR(13), N'');
UPDATE staging.estadios   SET equipo_id      = REPLACE(equipo_id,      NCHAR(13), N'');
UPDATE staging.arbitros   SET nombre         = REPLACE(nombre,         NCHAR(13), N'');
UPDATE staging.jornadas   SET numero         = REPLACE(numero,         NCHAR(13), N'');
UPDATE staging.partidos   SET estado         = REPLACE(estado,         NCHAR(13), N'');
UPDATE staging.jugadores  SET ultima_jornada = REPLACE(ultima_jornada, NCHAR(13), N'');
UPDATE staging.goles      SET tipo           = REPLACE(tipo,           NCHAR(13), N'');
GO

/* ===================== 2-4. Validar, aplicar y comprobar (un solo lote) ===================== */
-- Tipos: CONVERT (no TRY_CONVERT), igual que el 03: si un valor no encaja, se para con error.
SELECT CONVERT(SMALLINT, temporada_id) AS TemporadaID, nombre AS Nombre
INTO #Temporada FROM staging.temporadas;
SELECT CONVERT(INT, equipo_id) AS EquipoID, nombre AS Nombre, nombre_corto AS NombreCorto, ciudad AS Ciudad
INTO #Equipo FROM staging.equipos;
SELECT CONVERT(INT, estadio_id) AS EstadioID, nombre AS Nombre, CONVERT(INT, capacidad) AS Capacidad, CONVERT(INT, equipo_id) AS EquipoID
INTO #Estadio FROM staging.estadios;
SELECT CONVERT(INT, arbitro_id) AS ArbitroID, nombre AS Nombre
INTO #Arbitro FROM staging.arbitros;
SELECT CONVERT(INT, jornada_id) AS JornadaID, CONVERT(SMALLINT, temporada_id) AS TemporadaID, CONVERT(TINYINT, numero) AS Numero
INTO #Jornada FROM staging.jornadas;
SELECT CONVERT(INT, partido_id) AS PartidoID, CONVERT(INT, jornada_id) AS JornadaID,
       CONVERT(INT, equipo_local_id) AS EquipoLocalID, CONVERT(INT, equipo_visitante_id) AS EquipoVisitanteID,
       CONVERT(INT, estadio_id) AS EstadioID, CONVERT(INT, NULLIF(arbitro_principal_id, N'')) AS ArbitroPrincipalID,
       CONVERT(DATETIME2(0), NULLIF(fecha_hora, N''), 120) AS FechaHora,
       CONVERT(TINYINT, NULLIF(goles_local, N'')) AS GolesLocal, CONVERT(TINYINT, NULLIF(goles_visitante, N'')) AS GolesVisitante,
       CONVERT(VARCHAR(12), estado) AS Estado
INTO #Partido FROM staging.partidos;
SELECT CONVERT(INT, jugador_id) AS JugadorID, CONVERT(INT, equipo_id) AS EquipoID, nombre AS Nombre,
       CONVERT(CHAR(2), NULLIF(posicion, N'')) AS Posicion,
       CONVERT(INT, minutos_jugados) AS MinutosJugados, CONVERT(SMALLINT, goles) AS Goles,
       CONVERT(SMALLINT, asistencias) AS Asistencias, CONVERT(TINYINT, NULLIF(ultima_jornada, N'')) AS UltimaJornada
INTO #Jugador FROM staging.jugadores;
SELECT CONVERT(INT, gol_id) AS GolID, CONVERT(INT, partido_id) AS PartidoID, CONVERT(INT, equipo_id) AS EquipoID,
       CONVERT(INT, NULLIF(jugador_id, N'')) AS JugadorID, anotador AS Anotador,
       CONVERT(TINYINT, minuto) AS Minuto, CONVERT(VARCHAR(12), tipo) AS Tipo
INTO #Gol FROM staging.goles;

-- 2. Filas que están en la base de datos y no en los CSV: no se borran; se para y se listan.
DECLARE @Conflictos TABLE (Tabla NVARCHAR(30), ID INT, Detalle NVARCHAR(300));
INSERT @Conflictos SELECT N'liga.Temporada', t.TemporadaID, t.Nombre FROM liga.Temporada AS t WHERE NOT EXISTS (SELECT 1 FROM #Temporada AS s WHERE s.TemporadaID = t.TemporadaID);
INSERT @Conflictos SELECT N'liga.Equipo',    t.EquipoID,    t.Nombre FROM liga.Equipo    AS t WHERE NOT EXISTS (SELECT 1 FROM #Equipo    AS s WHERE s.EquipoID    = t.EquipoID);
INSERT @Conflictos SELECT N'liga.Estadio',   t.EstadioID,   t.Nombre FROM liga.Estadio   AS t WHERE NOT EXISTS (SELECT 1 FROM #Estadio   AS s WHERE s.EstadioID   = t.EstadioID);
INSERT @Conflictos SELECT N'liga.Arbitro',   t.ArbitroID,   t.Nombre FROM liga.Arbitro   AS t WHERE NOT EXISTS (SELECT 1 FROM #Arbitro   AS s WHERE s.ArbitroID   = t.ArbitroID);
INSERT @Conflictos SELECT N'liga.Jornada',   t.JornadaID,   CONCAT(N'Jornada ', t.Numero) FROM liga.Jornada AS t WHERE NOT EXISTS (SELECT 1 FROM #Jornada AS s WHERE s.JornadaID = t.JornadaID);
INSERT @Conflictos SELECT N'liga.Partido',   t.PartidoID,   CONCAT(N'Local ', t.EquipoLocalID, N' - visitante ', t.EquipoVisitanteID, N', jornada ', t.JornadaID)
                   FROM liga.Partido AS t WHERE NOT EXISTS (SELECT 1 FROM #Partido AS s WHERE s.PartidoID = t.PartidoID);
INSERT @Conflictos SELECT N'liga.Jugador',   t.JugadorID,   t.Nombre FROM liga.Jugador   AS t WHERE NOT EXISTS (SELECT 1 FROM #Jugador   AS s WHERE s.JugadorID   = t.JugadorID);
INSERT @Conflictos SELECT N'liga.Gol',       t.GolID,       CONCAT(t.Anotador, N', minuto ', t.Minuto, N', partido ', t.PartidoID)
                   FROM liga.Gol AS t WHERE NOT EXISTS (SELECT 1 FROM #Gol AS s WHERE s.GolID = t.GolID);

IF EXISTS (SELECT 1 FROM @Conflictos)
BEGIN
    PRINT N'*** La base de datos tiene filas que NO están en los CSV (¿metidas desde el panel de la web?).';
    PRINT N'*** No se ha cambiado nada. Opciones: añadirlas a los CSV, o reinstalar con instalar.ps1.';
    SELECT Tabla, ID, Detalle FROM @Conflictos ORDER BY Tabla, ID;
    THROW 50601, N'Hay filas en la base de datos que no están en los CSV. No se ha cambiado nada.', 1;
END;

-- 3. Aplicar. @Cambios es una variable de tabla: sobrevive al ROLLBACK de la simulación.
DECLARE @Cambios TABLE (Orden INT, Tabla NVARCHAR(30), Nuevas INT, Cambiadas INT);
DECLARE @n INT, @c INT;

BEGIN TRANSACTION;

    -- Temporada
    UPDATE t SET Nombre = s.Nombre FROM liga.Temporada AS t JOIN #Temporada AS s ON s.TemporadaID = t.TemporadaID
    WHERE EXISTS (SELECT t.Nombre EXCEPT SELECT s.Nombre);
    SET @c = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Temporada ON;
    INSERT INTO liga.Temporada (TemporadaID, Nombre)
    SELECT s.TemporadaID, s.Nombre FROM #Temporada AS s WHERE NOT EXISTS (SELECT 1 FROM liga.Temporada AS t WHERE t.TemporadaID = s.TemporadaID);
    SET @n = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Temporada OFF;
    INSERT @Cambios VALUES (1, N'liga.Temporada', @n, @c);

    -- Equipo
    UPDATE t SET Nombre = s.Nombre, NombreCorto = s.NombreCorto, Ciudad = s.Ciudad
    FROM liga.Equipo AS t JOIN #Equipo AS s ON s.EquipoID = t.EquipoID
    WHERE EXISTS (SELECT t.Nombre, t.NombreCorto, t.Ciudad EXCEPT SELECT s.Nombre, s.NombreCorto, s.Ciudad);
    SET @c = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Equipo ON;
    INSERT INTO liga.Equipo (EquipoID, Nombre, NombreCorto, Ciudad)
    SELECT s.EquipoID, s.Nombre, s.NombreCorto, s.Ciudad FROM #Equipo AS s WHERE NOT EXISTS (SELECT 1 FROM liga.Equipo AS t WHERE t.EquipoID = s.EquipoID);
    SET @n = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Equipo OFF;
    INSERT @Cambios VALUES (2, N'liga.Equipo', @n, @c);

    -- Estadio
    UPDATE t SET Nombre = s.Nombre, Capacidad = s.Capacidad, EquipoID = s.EquipoID
    FROM liga.Estadio AS t JOIN #Estadio AS s ON s.EstadioID = t.EstadioID
    WHERE EXISTS (SELECT t.Nombre, t.Capacidad, t.EquipoID EXCEPT SELECT s.Nombre, s.Capacidad, s.EquipoID);
    SET @c = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Estadio ON;
    INSERT INTO liga.Estadio (EstadioID, Nombre, Capacidad, EquipoID)
    SELECT s.EstadioID, s.Nombre, s.Capacidad, s.EquipoID FROM #Estadio AS s WHERE NOT EXISTS (SELECT 1 FROM liga.Estadio AS t WHERE t.EstadioID = s.EstadioID);
    SET @n = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Estadio OFF;
    INSERT @Cambios VALUES (3, N'liga.Estadio', @n, @c);

    -- Arbitro
    UPDATE t SET Nombre = s.Nombre FROM liga.Arbitro AS t JOIN #Arbitro AS s ON s.ArbitroID = t.ArbitroID
    WHERE EXISTS (SELECT t.Nombre EXCEPT SELECT s.Nombre);
    SET @c = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Arbitro ON;
    INSERT INTO liga.Arbitro (ArbitroID, Nombre)
    SELECT s.ArbitroID, s.Nombre FROM #Arbitro AS s WHERE NOT EXISTS (SELECT 1 FROM liga.Arbitro AS t WHERE t.ArbitroID = s.ArbitroID);
    SET @n = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Arbitro OFF;
    INSERT @Cambios VALUES (4, N'liga.Arbitro', @n, @c);

    -- Jornada
    UPDATE t SET TemporadaID = s.TemporadaID, Numero = s.Numero FROM liga.Jornada AS t JOIN #Jornada AS s ON s.JornadaID = t.JornadaID
    WHERE EXISTS (SELECT t.TemporadaID, t.Numero EXCEPT SELECT s.TemporadaID, s.Numero);
    SET @c = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Jornada ON;
    INSERT INTO liga.Jornada (JornadaID, TemporadaID, Numero)
    SELECT s.JornadaID, s.TemporadaID, s.Numero FROM #Jornada AS s WHERE NOT EXISTS (SELECT 1 FROM liga.Jornada AS t WHERE t.JornadaID = s.JornadaID);
    SET @n = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Jornada OFF;
    INSERT @Cambios VALUES (5, N'liga.Jornada', @n, @c);

    -- Partido (el trigger de auditoría registra los cambios de marcador y de estado)
    UPDATE t SET JornadaID = s.JornadaID, EquipoLocalID = s.EquipoLocalID, EquipoVisitanteID = s.EquipoVisitanteID,
                 EstadioID = s.EstadioID, ArbitroPrincipalID = s.ArbitroPrincipalID, FechaHora = s.FechaHora,
                 GolesLocal = s.GolesLocal, GolesVisitante = s.GolesVisitante, Estado = s.Estado
    FROM liga.Partido AS t JOIN #Partido AS s ON s.PartidoID = t.PartidoID
    WHERE EXISTS (SELECT t.JornadaID, t.EquipoLocalID, t.EquipoVisitanteID, t.EstadioID, t.ArbitroPrincipalID,
                         t.FechaHora, t.GolesLocal, t.GolesVisitante, t.Estado
                  EXCEPT
                  SELECT s.JornadaID, s.EquipoLocalID, s.EquipoVisitanteID, s.EstadioID, s.ArbitroPrincipalID,
                         s.FechaHora, s.GolesLocal, s.GolesVisitante, s.Estado);
    SET @c = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Partido ON;
    INSERT INTO liga.Partido (PartidoID, JornadaID, EquipoLocalID, EquipoVisitanteID, EstadioID,
                              ArbitroPrincipalID, FechaHora, GolesLocal, GolesVisitante, Estado)
    SELECT s.PartidoID, s.JornadaID, s.EquipoLocalID, s.EquipoVisitanteID, s.EstadioID,
           s.ArbitroPrincipalID, s.FechaHora, s.GolesLocal, s.GolesVisitante, s.Estado
    FROM #Partido AS s WHERE NOT EXISTS (SELECT 1 FROM liga.Partido AS t WHERE t.PartidoID = s.PartidoID);
    SET @n = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Partido OFF;
    INSERT @Cambios VALUES (6, N'liga.Partido', @n, @c);

    -- Jugador
    UPDATE t SET EquipoID = s.EquipoID, Nombre = s.Nombre, Posicion = s.Posicion, MinutosJugados = s.MinutosJugados,
                 Goles = s.Goles, Asistencias = s.Asistencias, UltimaJornada = s.UltimaJornada
    FROM liga.Jugador AS t JOIN #Jugador AS s ON s.JugadorID = t.JugadorID
    WHERE EXISTS (SELECT t.EquipoID, t.Nombre, t.Posicion, t.MinutosJugados, t.Goles, t.Asistencias, t.UltimaJornada
                  EXCEPT
                  SELECT s.EquipoID, s.Nombre, s.Posicion, s.MinutosJugados, s.Goles, s.Asistencias, s.UltimaJornada);
    SET @c = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Jugador ON;
    INSERT INTO liga.Jugador (JugadorID, EquipoID, Nombre, Posicion, MinutosJugados, Goles, Asistencias, UltimaJornada)
    SELECT s.JugadorID, s.EquipoID, s.Nombre, s.Posicion, s.MinutosJugados, s.Goles, s.Asistencias, s.UltimaJornada
    FROM #Jugador AS s WHERE NOT EXISTS (SELECT 1 FROM liga.Jugador AS t WHERE t.JugadorID = s.JugadorID);
    SET @n = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Jugador OFF;
    INSERT @Cambios VALUES (7, N'liga.Jugador', @n, @c);

    -- Gol
    UPDATE t SET PartidoID = s.PartidoID, EquipoID = s.EquipoID, JugadorID = s.JugadorID, Anotador = s.Anotador,
                 Minuto = s.Minuto, Tipo = s.Tipo
    FROM liga.Gol AS t JOIN #Gol AS s ON s.GolID = t.GolID
    WHERE EXISTS (SELECT t.PartidoID, t.EquipoID, t.JugadorID, t.Anotador, t.Minuto, t.Tipo
                  EXCEPT
                  SELECT s.PartidoID, s.EquipoID, s.JugadorID, s.Anotador, s.Minuto, s.Tipo);
    SET @c = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Gol ON;
    INSERT INTO liga.Gol (GolID, PartidoID, EquipoID, JugadorID, Anotador, Minuto, Tipo)
    SELECT s.GolID, s.PartidoID, s.EquipoID, s.JugadorID, s.Anotador, s.Minuto, s.Tipo
    FROM #Gol AS s WHERE NOT EXISTS (SELECT 1 FROM liga.Gol AS t WHERE t.GolID = s.GolID);
    SET @n = @@ROWCOUNT;
    SET IDENTITY_INSERT liga.Gol OFF;
    INSERT @Cambios VALUES (8, N'liga.Gol', @n, @c);

    -- 4. Comprobación: cada tabla tiene exactamente las filas de su CSV.
    DECLARE @Distintas INT =
          (SELECT COUNT(*) FROM (SELECT * FROM #Temporada EXCEPT SELECT TemporadaID, Nombre FROM liga.Temporada) AS x)
        + (SELECT COUNT(*) FROM (SELECT * FROM #Equipo    EXCEPT SELECT EquipoID, Nombre, NombreCorto, Ciudad FROM liga.Equipo) AS x)
        + (SELECT COUNT(*) FROM (SELECT * FROM #Estadio   EXCEPT SELECT EstadioID, Nombre, Capacidad, EquipoID FROM liga.Estadio) AS x)
        + (SELECT COUNT(*) FROM (SELECT * FROM #Arbitro   EXCEPT SELECT ArbitroID, Nombre FROM liga.Arbitro) AS x)
        + (SELECT COUNT(*) FROM (SELECT * FROM #Jornada   EXCEPT SELECT JornadaID, TemporadaID, Numero FROM liga.Jornada) AS x)
        + (SELECT COUNT(*) FROM (SELECT * FROM #Partido   EXCEPT SELECT PartidoID, JornadaID, EquipoLocalID, EquipoVisitanteID, EstadioID,
                                                                    ArbitroPrincipalID, FechaHora, GolesLocal, GolesVisitante, Estado FROM liga.Partido) AS x)
        + (SELECT COUNT(*) FROM (SELECT * FROM #Jugador   EXCEPT SELECT JugadorID, EquipoID, Nombre, Posicion, MinutosJugados, Goles,
                                                                    Asistencias, UltimaJornada FROM liga.Jugador) AS x)
        + (SELECT COUNT(*) FROM (SELECT * FROM #Gol       EXCEPT SELECT GolID, PartidoID, EquipoID, JugadorID, Anotador, Minuto, Tipo FROM liga.Gol) AS x);
    IF @Distintas > 0
        THROW 50602, N'Tras actualizar, la base de datos no coincide con los CSV. Se deshace todo.', 1;

IF $(Simular) = 1
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'=== SIMULACIÓN: esto es lo que cambiaría. No se ha guardado nada. ===';
END
ELSE
BEGIN
    COMMIT TRANSACTION;
    PRINT N'=== Actualización aplicada ===';
END;

SELECT Tabla, Nuevas, Cambiadas FROM @Cambios ORDER BY Orden;
SELECT CASE WHEN SUM(Nuevas + Cambiadas) = 0 THEN N'Los datos ya estaban al día.'
            ELSE CONCAT(SUM(Nuevas), N' filas nuevas y ', SUM(Cambiadas), N' cambiadas.') END AS Resumen
FROM @Cambios;
GO

DROP TABLE IF EXISTS staging.temporadas, staging.equipos, staging.estadios, staging.arbitros,
                     staging.jornadas, staging.partidos, staging.jugadores, staging.goles;
GO
