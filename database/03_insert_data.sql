/* =============================================================================
   03_insert_data.sql
   Proyecto LigaDB (DP-800, Práctica 09) - Bloque A
   1) Carga los CSV verificados de data/ (temporada 2026-27, J1-J10):
      CSV -> staging (todo texto) -> tablas finales con IDENTITY_INSERT y CONVERT.
   2) Genera los únicos datos sintéticos del proyecto, de forma reproducible:
      ventas.Abonado (2.000) y ventas.Entrada (~200.000).

   Ejecución (la ruta de data/ se pasa como variable, sin rutas fijas):
     sqlcmd -S localhost -E -C -b -v DataPath="C:\...\goalmetry\data" -i database\03_insert_data.sql
   Idempotente: vacía las tablas antes de cargar y deja staging vacío al terminar.
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;
USE LigaDB;
GO

/* ===================== 0. Vaciar tablas (hijas antes que padres) ===================== */
-- Si ya se ejecutó 06_security.sql, seguridad.UsuarioEquipo apunta a liga.Equipo: se guarda en
-- una tabla temporal (dura toda la sesión de sqlcmd) y se restaura al final. Los EquipoID vienen
-- fijados por los CSV, así que siguen siendo válidos tras la recarga.
DROP TABLE IF EXISTS #UsuarioEquipo;
CREATE TABLE #UsuarioEquipo (NombreUsuario SYSNAME COLLATE DATABASE_DEFAULT, EquipoID INT);

-- Una transacción: si algo falla, no queda la BD a medio vaciar (con XACT_ABORT ON se deshace todo).
BEGIN TRANSACTION;
IF OBJECT_ID(N'seguridad.UsuarioEquipo') IS NOT NULL
BEGIN
    INSERT INTO #UsuarioEquipo (NombreUsuario, EquipoID)
    SELECT NombreUsuario, EquipoID FROM seguridad.UsuarioEquipo;
    DELETE FROM seguridad.UsuarioEquipo;
END;
DELETE FROM ia.Documento;
-- TRUNCATE (no DELETE + DBCC CHECKIDENT RESEED 0): RESEED 0 en una tabla que nunca tuvo filas
-- hace que el primer EntradaID sea 0, y en una que ya tuvo filas, 1. TRUNCATE siempre deja la
-- identidad en su semilla (1), así una BD recién creada y una recarga generan los mismos IDs.
-- Se puede porque ninguna FK apunta a ventas.Entrada.
TRUNCATE TABLE ventas.Entrada;
DELETE FROM ventas.Abonado;
DELETE FROM liga.PartidoAuditoria;
DELETE FROM liga.Gol;
DELETE FROM liga.Jugador;
DELETE FROM liga.Partido;
DELETE FROM liga.Jornada;
DELETE FROM liga.Arbitro;
DELETE FROM liga.Estadio;
DELETE FROM liga.Equipo;
DELETE FROM liga.Temporada;
COMMIT TRANSACTION;
GO

/* ===================== 1. Tablas de staging (columnas = cabecera del CSV, todo texto) ===================== */
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
GO

/* ===================== 2. BULK INSERT de los CSV ===================== */
-- UTF-8 (CODEPAGE 65001), cabecera en la fila 1, fin de línea LF (garantizado por .gitattributes).
BULK INSERT staging.temporadas FROM '$(DataPath)\temporadas.csv' WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.equipos    FROM '$(DataPath)\equipos.csv'    WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.estadios   FROM '$(DataPath)\estadios.csv'   WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.arbitros   FROM '$(DataPath)\arbitros.csv'   WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.jornadas   FROM '$(DataPath)\jornadas.csv'   WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.partidos   FROM '$(DataPath)\partidos.csv'   WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.jugadores  FROM '$(DataPath)\jugadores.csv'  WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT staging.goles      FROM '$(DataPath)\goles.csv'      WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a', TABLOCK);

-- Protección por si un CSV llega con CRLF: el CR quedaría pegado a la última columna.
UPDATE staging.temporadas SET nombre         = REPLACE(nombre,         NCHAR(13), N'');
UPDATE staging.equipos    SET ciudad         = REPLACE(ciudad,         NCHAR(13), N'');
UPDATE staging.estadios   SET equipo_id      = REPLACE(equipo_id,      NCHAR(13), N'');
UPDATE staging.arbitros   SET nombre         = REPLACE(nombre,         NCHAR(13), N'');
UPDATE staging.jornadas   SET numero         = REPLACE(numero,         NCHAR(13), N'');
UPDATE staging.partidos   SET estado         = REPLACE(estado,         NCHAR(13), N'');
UPDATE staging.jugadores  SET ultima_jornada = REPLACE(ultima_jornada, NCHAR(13), N'');
UPDATE staging.goles      SET tipo           = REPLACE(tipo,           NCHAR(13), N'');
GO

/* ===================== 3. Staging -> tablas finales ===================== */
-- CONVERT (no TRY_CONVERT): si un valor no encaja, la carga falla y no se pierde el dato en silencio.
-- NULLIF(x, N''): un campo vacío del CSV es NULL. Todo en una transacción: o se carga todo o nada.
BEGIN TRANSACTION;

SET IDENTITY_INSERT liga.Temporada ON;
INSERT INTO liga.Temporada (TemporadaID, Nombre)
SELECT CONVERT(SMALLINT, temporada_id), nombre
FROM staging.temporadas;
SET IDENTITY_INSERT liga.Temporada OFF;

SET IDENTITY_INSERT liga.Equipo ON;
INSERT INTO liga.Equipo (EquipoID, Nombre, NombreCorto, Ciudad)
SELECT CONVERT(INT, equipo_id), nombre, nombre_corto, ciudad
FROM staging.equipos;
SET IDENTITY_INSERT liga.Equipo OFF;

SET IDENTITY_INSERT liga.Estadio ON;
INSERT INTO liga.Estadio (EstadioID, Nombre, Capacidad, EquipoID)
SELECT CONVERT(INT, estadio_id), nombre, CONVERT(INT, capacidad), CONVERT(INT, equipo_id)
FROM staging.estadios;
SET IDENTITY_INSERT liga.Estadio OFF;

SET IDENTITY_INSERT liga.Arbitro ON;
INSERT INTO liga.Arbitro (ArbitroID, Nombre)
SELECT CONVERT(INT, arbitro_id), nombre
FROM staging.arbitros;
SET IDENTITY_INSERT liga.Arbitro OFF;

SET IDENTITY_INSERT liga.Jornada ON;
INSERT INTO liga.Jornada (JornadaID, TemporadaID, Numero)
SELECT CONVERT(INT, jornada_id), CONVERT(SMALLINT, temporada_id), CONVERT(TINYINT, numero)
FROM staging.jornadas;
SET IDENTITY_INSERT liga.Jornada OFF;

SET IDENTITY_INSERT liga.Partido ON;
INSERT INTO liga.Partido (PartidoID, JornadaID, EquipoLocalID, EquipoVisitanteID, EstadioID,
                          ArbitroPrincipalID, FechaHora, GolesLocal, GolesVisitante, Estado)
SELECT CONVERT(INT, partido_id),
       CONVERT(INT, jornada_id),
       CONVERT(INT, equipo_local_id),
       CONVERT(INT, equipo_visitante_id),
       CONVERT(INT, estadio_id),
       CONVERT(INT, NULLIF(arbitro_principal_id, N'')),
       CONVERT(DATETIME2(0), NULLIF(fecha_hora, N''), 120),     -- formato 'aaaa-mm-dd hh:mi:ss'
       CONVERT(TINYINT, NULLIF(goles_local, N'')),
       CONVERT(TINYINT, NULLIF(goles_visitante, N'')),
       estado
FROM staging.partidos;
SET IDENTITY_INSERT liga.Partido OFF;

SET IDENTITY_INSERT liga.Jugador ON;
INSERT INTO liga.Jugador (JugadorID, EquipoID, Nombre, Posicion, MinutosJugados, Goles, Asistencias, UltimaJornada)
SELECT CONVERT(INT, jugador_id),
       CONVERT(INT, equipo_id),
       nombre,
       NULLIF(posicion, N''),
       CONVERT(INT, minutos_jugados),
       CONVERT(SMALLINT, goles),
       CONVERT(SMALLINT, asistencias),
       CONVERT(TINYINT, NULLIF(ultima_jornada, N''))
FROM staging.jugadores;
SET IDENTITY_INSERT liga.Jugador OFF;

SET IDENTITY_INSERT liga.Gol ON;
INSERT INTO liga.Gol (GolID, PartidoID, EquipoID, JugadorID, Anotador, Minuto, Tipo)
SELECT CONVERT(INT, gol_id),
       CONVERT(INT, partido_id),
       CONVERT(INT, equipo_id),
       CONVERT(INT, NULLIF(jugador_id, N'')),
       anotador,
       CONVERT(TINYINT, minuto),
       tipo
FROM staging.goles;
SET IDENTITY_INSERT liga.Gol OFF;

-- Recuentos esperados (docs/verificacion.md). Si alguno no cuadra, se deshace la carga.
DECLARE @Errores NVARCHAR(MAX) =
(
    SELECT STRING_AGG(CONCAT(Tabla, N': ', Real, N' (esperado ', Esperado, N')'), N'; ')
    FROM (VALUES (N'Temporada', (SELECT COUNT(*) FROM liga.Temporada),   1),
                 (N'Equipo',    (SELECT COUNT(*) FROM liga.Equipo),     20),
                 (N'Estadio',   (SELECT COUNT(*) FROM liga.Estadio),    20),
                 (N'Arbitro',   (SELECT COUNT(*) FROM liga.Arbitro),    21),
                 (N'Jornada',   (SELECT COUNT(*) FROM liga.Jornada),    10),
                 (N'Partido',   (SELECT COUNT(*) FROM liga.Partido),   100),
                 (N'Jugador',   (SELECT COUNT(*) FROM liga.Jugador),   452),
                 (N'Gol',       (SELECT COUNT(*) FROM liga.Gol),       279)) AS v (Tabla, Real, Esperado)
    WHERE Real <> Esperado
);
IF @Errores IS NOT NULL
BEGIN
    ROLLBACK TRANSACTION;
    THROW 50001, @Errores, 1;
END;

COMMIT TRANSACTION;
PRINT N'Carga de los CSV correcta: recuentos 1/20/20/21/10/100/452/279.';
GO

/* ===================== 4. Datos sintéticos de ventas (reproducibles) ===================== */
-- No se usa RAND(): el "azar" sale de un hash SHA-256 de una semilla fija + el número de fila,
-- así que cada ejecución genera exactamente los mismos datos (mismo checksum al final).
-- Nombres, emails, teléfonos y DNI son FICTICIOS (dominio reservado .example).

-- 4.1 Abonados: 2.000, 100 por equipo.
DECLARE @Semilla NVARCHAR(20) = N'LigaDB-2026';

DECLARE @Nombres TABLE (i INT PRIMARY KEY, Nombre NVARCHAR(30));
INSERT INTO @Nombres VALUES
 (0,N'Lucía'),(1,N'Hugo'),(2,N'Martina'),(3,N'Martín'),(4,N'Sofía'),(5,N'Mateo'),(6,N'Julia'),(7,N'Leo'),
 (8,N'Paula'),(9,N'Daniel'),(10,N'Valeria'),(11,N'Pablo'),(12,N'Emma'),(13,N'Álvaro'),(14,N'Daniela'),
 (15,N'Manuel'),(16,N'Carla'),(17,N'Adrián'),(18,N'Alba'),(19,N'David'),(20,N'Noa'),(21,N'Javier'),
 (22,N'Carmen'),(23,N'Diego'),(24,N'Sara'),(25,N'Marcos'),(26,N'Lara'),(27,N'Sergio'),(28,N'Elena'),(29,N'Iker');

DECLARE @Apellidos TABLE (i INT PRIMARY KEY, Apellido NVARCHAR(30));
INSERT INTO @Apellidos VALUES
 (0,N'García'),(1,N'Rodríguez'),(2,N'González'),(3,N'Fernández'),(4,N'López'),(5,N'Martínez'),(6,N'Sánchez'),
 (7,N'Pérez'),(8,N'Gómez'),(9,N'Martín'),(10,N'Jiménez'),(11,N'Ruiz'),(12,N'Hernández'),(13,N'Díaz'),
 (14,N'Moreno'),(15,N'Muñoz'),(16,N'Álvarez'),(17,N'Romero'),(18,N'Alonso'),(19,N'Gutiérrez'),(20,N'Navarro'),
 (21,N'Torres'),(22,N'Domínguez'),(23,N'Vázquez'),(24,N'Ramos'),(25,N'Gil'),(26,N'Ramírez'),(27,N'Serrano'),
 (28,N'Blanco'),(29,N'Molina');

SET IDENTITY_INSERT ventas.Abonado ON;   -- AbonadoID = n, siempre el mismo

WITH Base AS
(
    SELECT s.value AS n,
           -- 6 bytes del hash -> entero no negativo de 48 bits, distinto para cada n
           CONVERT(BIGINT, SUBSTRING(HASHBYTES('SHA2_256', CONCAT(@Semilla, N'|abonado|', s.value)), 1, 6)) AS h
    FROM GENERATE_SERIES(1, 2000) AS s
),
Calc AS
(
    SELECT n, h,
           ((n - 1) % 20) + 1                                  AS EquipoID,
           10000000 + (CONVERT(BIGINT, n) * 48271) % 90000000  AS NumDNI,   -- 8 cifras, único para n <= 2000
           h % 100                                             AS PctTelefono
    FROM Base
)
INSERT INTO ventas.Abonado (AbonadoID, EquipoID, Nombre, Email, Telefono, Documento)
SELECT c.n,
       c.EquipoID,
       CONCAT(nb.Nombre, N' ', a1.Apellido, N' ', a2.Apellido),
       CONCAT(N'abonado', FORMAT(c.n, '0000'), N'@correo.example'),
       CASE WHEN c.PctTelefono < 10 THEN NULL                                         -- 10 %: sin teléfono
            WHEN c.PctTelefono < 30 THEN CONCAT('+34 6', FORMAT((c.h / 100) % 100, '00'), ' ',
                                                FORMAT((c.h / 10000) % 1000, '000'), ' ',
                                                FORMAT((c.h / 10000000) % 1000, '000'))  -- 20 %: '+34 6XX XXX XXX'
            ELSE CONCAT('6', FORMAT((c.h / 100) % 100000000, '00000000'))              -- 70 %: '6XXXXXXXX'
       END,
       -- DNI: 8 cifras + letra de control oficial (resto módulo 23)
       CONCAT(c.NumDNI, SUBSTRING('TRWAGMYFPDXBNJZSQVHLCKE', CONVERT(INT, c.NumDNI % 23) + 1, 1))
FROM Calc AS c
JOIN @Nombres   AS nb ON nb.i = c.h % 30
JOIN @Apellidos AS a1 ON a1.i = (c.h / 30) % 30
JOIN @Apellidos AS a2 ON a2.i = (c.h / 900) % 30
ORDER BY c.n
OPTION (MAXDOP 1);

SET IDENTITY_INSERT ventas.Abonado OFF;
GO

-- 4.2 Entradas: cada abonado compra para los partidos de su equipo (local y visitante)
--     de 1 a 19 entradas por partido (él y acompañantes). Resultado: ~200.000 filas.
--     FechaCompra: entre 1 hora y 30 días antes del partido, nunca después de la fecha de corte.
--     Precio: base según el aforo del estadio del partido + variación de 0 a 40 euros.
DECLARE @Semilla   NVARCHAR(20) = N'LigaDB-2026';
DECLARE @FechaCorte DATETIME2(0) = '2026-10-24T12:00:00';   -- "hoy" en la temporada simulada (fijo)

WITH Pares AS
(
    SELECT a.AbonadoID, p.PartidoID, p.FechaHora, e.Capacidad,
           1 + CONVERT(BIGINT, SUBSTRING(HASHBYTES('SHA2_256',
                 CONCAT(@Semilla, N'|cantidad|', a.AbonadoID, N'|', p.PartidoID)), 1, 6)) % 19 AS Cantidad
    FROM ventas.Abonado AS a
    JOIN liga.Partido   AS p ON a.EquipoID IN (p.EquipoLocalID, p.EquipoVisitanteID)
    JOIN liga.Estadio   AS e ON e.EstadioID = p.EstadioID
),
Filas AS
(
    SELECT pr.AbonadoID, pr.PartidoID, pr.FechaHora, pr.Capacidad, k.value AS k,
           CONVERT(BIGINT, SUBSTRING(HASHBYTES('SHA2_256',
               CONCAT(@Semilla, N'|entrada|', pr.AbonadoID, N'|', pr.PartidoID, N'|', k.value)), 1, 6)) AS h
    FROM Pares AS pr
    CROSS APPLY GENERATE_SERIES(CONVERT(BIGINT, 1), pr.Cantidad) AS k
)
INSERT INTO ventas.Entrada (AbonadoID, PartidoID, Precio, FechaCompra)
SELECT f.AbonadoID,
       f.PartidoID,
       CONVERT(DECIMAL(8,2), 30 + f.Capacidad / 2000.0 + (f.h % 4001) / 100.0),
       DATEADD(MINUTE, -CONVERT(INT, 60 + (f.h / 4001) % (30 * 24 * 60)),
               LEAST(f.FechaHora, @FechaCorte))
FROM Filas AS f
ORDER BY f.AbonadoID, f.PartidoID, f.k          -- EntradaID siempre en el mismo orden
OPTION (MAXDOP 1);
GO

/* ===================== 5. Restaurar asignaciones de seguridad y limpiar staging ===================== */
IF OBJECT_ID(N'seguridad.UsuarioEquipo') IS NOT NULL
    INSERT INTO seguridad.UsuarioEquipo (NombreUsuario, EquipoID)
    SELECT NombreUsuario, EquipoID FROM #UsuarioEquipo;
DROP TABLE IF EXISTS #UsuarioEquipo;

DROP TABLE IF EXISTS staging.temporadas, staging.equipos, staging.estadios, staging.arbitros,
                     staging.jornadas, staging.partidos, staging.jugadores, staging.goles;
GO

/* ===================== 6. Comprobación ===================== */
PRINT N'--- Recuentos por tabla ---';
SELECT Tabla, Filas
FROM (VALUES (1,  N'liga.Temporada',      (SELECT COUNT_BIG(*) FROM liga.Temporada)),
             (2,  N'liga.Equipo',         (SELECT COUNT_BIG(*) FROM liga.Equipo)),
             (3,  N'liga.Estadio',        (SELECT COUNT_BIG(*) FROM liga.Estadio)),
             (4,  N'liga.Arbitro',        (SELECT COUNT_BIG(*) FROM liga.Arbitro)),
             (5,  N'liga.Jornada',        (SELECT COUNT_BIG(*) FROM liga.Jornada)),
             (6,  N'liga.Partido',        (SELECT COUNT_BIG(*) FROM liga.Partido)),
             (7,  N'liga.Jugador',        (SELECT COUNT_BIG(*) FROM liga.Jugador)),
             (8,  N'liga.Gol',            (SELECT COUNT_BIG(*) FROM liga.Gol)),
             (9,  N'ventas.Abonado',      (SELECT COUNT_BIG(*) FROM ventas.Abonado)),
             (10, N'ventas.Entrada',      (SELECT COUNT_BIG(*) FROM ventas.Entrada))) AS v (Orden, Tabla, Filas)
ORDER BY Orden;

PRINT N'--- Partidos por estado (J10 incompleta) y marcadores NULL ---';
SELECT j.Numero AS Jornada, p.Estado, COUNT(*) AS Partidos,
       SUM(CASE WHEN p.GolesLocal IS NULL THEN 1 ELSE 0 END) AS SinMarcador,
       SUM(CASE WHEN p.ArbitroPrincipalID IS NULL THEN 1 ELSE 0 END) AS SinArbitro
FROM liga.Partido AS p
JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
WHERE j.Numero >= 9
GROUP BY j.Numero, p.Estado
ORDER BY j.Numero, p.Estado;

PRINT N'--- Comprobaciones de valores especiales de los CSV ---';
SELECT (SELECT COUNT(*) FROM liga.Jugador WHERE Posicion IS NULL)    AS JugadoresSinPosicion,   -- esperado 1
       (SELECT COUNT(*) FROM liga.Gol WHERE JugadorID IS NULL)       AS GolesSinJugador,        -- esperado 5
       (SELECT COUNT(*) FROM liga.Gol WHERE Tipo = 'PropiaPuerta')   AS GolesPropiaPuerta,
       (SELECT COUNT(*) FROM liga.Gol WHERE Tipo = 'Penalti')        AS GolesPenalti,
       -- UTF-8 bien leído. COLLATE sensible a tildes: con la collation CI_AI de la BD, 'á' = 'a'.
       (SELECT COUNT(*) FROM liga.Equipo
        WHERE Nombre COLLATE Modern_Spanish_100_CS_AS LIKE N'%[áéíóúñ]%') AS EquiposConTilde;

PRINT N'--- Ventas generadas ---';
SELECT COUNT(*) AS Entradas, MIN(Precio) AS PrecioMin, MAX(Precio) AS PrecioMax, AVG(Precio) AS PrecioMedio,
       MIN(FechaCompra) AS PrimeraCompra, MAX(FechaCompra) AS UltimaCompra
FROM ventas.Entrada;

SELECT SUM(CASE WHEN Telefono IS NULL THEN 1 ELSE 0 END)        AS SinTelefono,
       SUM(CASE WHEN Telefono LIKE '+34 %' THEN 1 ELSE 0 END)   AS TelefonoConPrefijo,
       SUM(CASE WHEN Telefono LIKE '6%' THEN 1 ELSE 0 END)      AS TelefonoSinPrefijo
FROM ventas.Abonado;

SELECT TOP (3) AbonadoID, EquipoID, Nombre, Email, Telefono, Documento
FROM ventas.Abonado
ORDER BY AbonadoID;

-- Huella de los datos generados: tiene que salir igual en cada ejecución (reproducibilidad).
SELECT (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM ventas.Abonado) AS ChecksumAbonado,
       (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM ventas.Entrada) AS ChecksumEntrada;

-- Ninguna compra posterior al partido ni a la fecha de corte.
SELECT COUNT(*) AS ComprasIncoherentes
FROM ventas.Entrada AS en
JOIN liga.Partido   AS p ON p.PartidoID = en.PartidoID
WHERE en.FechaCompra >= p.FechaHora OR en.FechaCompra > '2026-10-24T12:00:00';
GO
