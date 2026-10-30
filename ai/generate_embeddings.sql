/* =============================================================================
   generate_embeddings.sql
   Goalmetry - Bloque E (2/2): documentos de ia.Documento y sus embeddings
   Deja ia.Documento al día con los datos de la liga y calcula el embedding de los
   textos nuevos o modificados con el modelo externo bge_m3_ollama
   (ver create_external_model.sql).
   Origen de cada tipo de documento:
     - reglamento y faq: textos redactados, en data\documentos.csv.
     - cronica_partido:  data\cronicas.csv (una por partido finalizado). Si a algún
                         partido finalizado le falta su crónica, se usa la generada por
                         ia.vw_CronicaGenerada y se avisa.
     - ficha_equipo y resumen_jornada: se GENERAN con los datos de liga.* (vistas
                         ia.vw_FichaEquipo e ia.vw_ResumenJornada), así siempre cuadran
                         con la clasificación. No se inventa nada.
   ia.usp_SincronizarDocumentos compara lo que debería haber con lo que hay:
   inserta lo nuevo, cambia lo modificado (y borra su embedding para recalcularlo) y
   quita lo que ya no corresponde. Solo se calculan los embeddings que faltan.
   Lo usan instalar.ps1 (con -IA) y actualizar.ps1.
   Ejecución:  sqlcmd -S localhost -E -C -b -v DataPath="C:\ruta\data" -i ai\generate_embeddings.sql
   Idempotente: si nada ha cambiado, no modifica nada ni recalcula ningún embedding.
   Requiere: 01-05 ejecutados y bge_m3_ollama creado (create_external_model.sql).
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

/* ---------- 1. Textos generados a partir de los datos ---------- */
CREATE OR ALTER VIEW ia.vw_FichaEquipo
AS
SELECT e.EquipoID,
       CONCAT(N'Ficha de ', e.Nombre) AS Titulo,
       CONCAT(e.Nombre, N' (', e.Ciudad, N'). Juega como local en ', es.Nombre,
              N', con capacidad para ', es.Capacidad, N' espectadores. ',
              N'Clasificación: puesto ', c.Posicion, N' con ', c.Pts, N' puntos tras ', c.PJ,
              N' partidos (', c.G, N' ganados, ', c.E, N' empatados y ', c.P, N' perdidos), ',
              c.GF, N' goles a favor y ', c.GC, N' en contra (diferencia de goles ', c.DG, N'). ',
              N'Plantilla con ', pl.Jugadores, N' jugadores registrados.',
              CASE WHEN g.Goleadores IS NOT NULL
                   THEN CONCAT(N' Máximos goleadores del equipo: ', g.Goleadores, N'.') ELSE N'' END) AS Texto,
       N'Goalmetry (generado desde liga.vw_Clasificacion, liga.Jugador y liga.Gol)' AS Fuente
FROM liga.Equipo AS e
JOIN liga.Estadio AS es ON es.EquipoID = e.EquipoID
JOIN liga.vw_Clasificacion AS c ON c.EquipoID = e.EquipoID
CROSS APPLY (SELECT COUNT(*) AS Jugadores FROM liga.Jugador AS j WHERE j.EquipoID = e.EquipoID) AS pl
OUTER APPLY (SELECT STRING_AGG(CONCAT(t.Anotador, N' (', t.Goles, N')'), N', ')
                    WITHIN GROUP (ORDER BY t.Goles DESC, t.Anotador) AS Goleadores
             FROM (SELECT TOP (3) m.Anotador, m.Goles
                   FROM liga.vw_MaximosGoleadores AS m
                   WHERE m.Equipo = e.Nombre
                   ORDER BY m.Goles DESC, m.Anotador) AS t) AS g;
GO

CREATE OR ALTER VIEW ia.vw_ResumenJornada
AS
SELECT j.Numero,
       CONCAT(N'Resumen de la jornada ', j.Numero) AS Titulo,
       CONCAT(N'Jornada ', j.Numero, N' de LaLiga ', t.Nombre, N'. ',
              N'Partidos finalizados: ', r.Finalizados, N' de ', r.Total, N', con ', r.Goles, N' goles. ',
              CASE WHEN r.Resultados IS NOT NULL THEN CONCAT(N'Resultados: ', r.Resultados, N'. ') ELSE N'' END,
              CASE WHEN r.Pendientes IS NOT NULL THEN CONCAT(N'Pendientes de jugar: ', r.Pendientes, N'.') ELSE N'' END) AS Texto,
       N'Goalmetry (generado desde liga.Partido)' AS Fuente
FROM liga.Jornada AS j
JOIN liga.Temporada AS t ON t.TemporadaID = j.TemporadaID
CROSS APPLY (
    SELECT COUNT(*)                                                        AS Total,
           SUM(CASE WHEN p.Estado = 'Finalizado' THEN 1 ELSE 0 END)        AS Finalizados,
           SUM(CASE WHEN p.Estado = 'Finalizado' THEN p.GolesLocal + p.GolesVisitante ELSE 0 END) AS Goles,
           STRING_AGG(CASE WHEN p.Estado = 'Finalizado'
                           THEN CONCAT(l.Nombre, N' ', p.GolesLocal, N'-', p.GolesVisitante, N' ', v.Nombre) END, N'; ')
                      WITHIN GROUP (ORDER BY p.PartidoID)                  AS Resultados,
           STRING_AGG(CASE WHEN p.Estado <> 'Finalizado'
                           THEN CONCAT(l.Nombre, N'-', v.Nombre) END, N'; ')
                      WITHIN GROUP (ORDER BY p.PartidoID)                  AS Pendientes
    FROM liga.Partido AS p
    JOIN liga.Equipo AS l ON l.EquipoID = p.EquipoLocalID
    JOIN liga.Equipo AS v ON v.EquipoID = p.EquipoVisitanteID
    WHERE p.JornadaID = j.JornadaID
) AS r
WHERE r.Total > 0;
GO

-- Crónica básica de un partido finalizado, solo con los datos de liga.Partido y liga.Gol.
-- Es la plantilla con la que se escriben las crónicas de data\cronicas.csv y el respaldo
-- si a un partido finalizado le falta la suya.
CREATE OR ALTER VIEW ia.vw_CronicaGenerada
AS
SELECT p.PartidoID,
       CONCAT(l.Nombre, N' ', p.GolesLocal, N'-', p.GolesVisitante, N' ', v.Nombre, N' (jornada ', j.Numero, N')') AS Titulo,
       CONCAT(N'Jornada ', j.Numero, N': ', l.Nombre, N' ', p.GolesLocal, N'-', p.GolesVisitante, N' ', v.Nombre,
              N', en ', es.Nombre,
              CASE WHEN p.FechaHora IS NOT NULL THEN CONCAT(N', el ', CONVERT(CHAR(16), p.FechaHora, 120)) ELSE N'' END, N'. ',
              CASE WHEN p.GolesLocal > p.GolesVisitante THEN CONCAT(N'Ganó ', l.Nombre, N'. ')
                   WHEN p.GolesLocal < p.GolesVisitante THEN CONCAT(N'Ganó ', v.Nombre, N'. ')
                   ELSE N'Empate. ' END,
              CASE WHEN a.Nombre IS NOT NULL THEN CONCAT(N'Árbitro: ', a.Nombre, N'. ') ELSE N'' END,
              CASE WHEN g.Detalle IS NULL
                   THEN CASE WHEN p.GolesLocal + p.GolesVisitante = 0 THEN N'Sin goles.'
                             ELSE N'La fuente no detalla los goles de este partido.' END
                   ELSE CONCAT(N'Goles: ', g.Detalle, N'.') END,
              CASE WHEN g.Detalle IS NOT NULL AND g.NumGoles <> p.GolesLocal + p.GolesVisitante
                   THEN CONCAT(N' Nota: la fuente detalla ', g.NumGoles, N' de los ', p.GolesLocal + p.GolesVisitante, N' goles del partido.')
                   ELSE N'' END) AS Texto,
       N'Goalmetry (generado desde liga.Partido y liga.Gol)' AS Fuente
FROM liga.Partido AS p
JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
JOIN liga.Equipo  AS l ON l.EquipoID = p.EquipoLocalID
JOIN liga.Equipo  AS v ON v.EquipoID = p.EquipoVisitanteID
JOIN liga.Estadio AS es ON es.EstadioID = p.EstadioID
LEFT JOIN liga.Arbitro AS a ON a.ArbitroID = p.ArbitroPrincipalID
OUTER APPLY (
    SELECT COUNT(*) AS NumGoles,
           STRING_AGG(CONCAT(N'minuto ', x.Minuto, N': ', x.Anotador,
                             CASE x.Tipo
                                  WHEN 'Penalti'      THEN CONCAT(N' (penalti, ', x.Equipo, N')')
                                  WHEN 'PropiaPuerta' THEN CONCAT(N' (en propia puerta, gol para ', x.Equipo, N')')
                                  ELSE CONCAT(N' (', x.Equipo, N')') END), N'; ')
                      WITHIN GROUP (ORDER BY x.Minuto, x.GolID) AS Detalle
    FROM (SELECT gl.GolID, gl.Minuto, gl.Anotador, gl.Tipo, eq.Nombre AS Equipo
          FROM liga.Gol AS gl
          JOIN liga.Equipo AS eq ON eq.EquipoID = gl.EquipoID
          WHERE gl.PartidoID = p.PartidoID) AS x
) AS g
WHERE p.Estado = 'Finalizado';
GO

/* ---------- 2. Sincronización de ia.Documento ----------
   Lee staging.documentos y staging.cronicas (los carga el script que lo llama desde los CSV).
   @GenerarEmbeddings = 0: solo deja los textos al día (los embeddings quedan pendientes). */
CREATE OR ALTER PROCEDURE ia.usp_SincronizarDocumentos
    @GenerarEmbeddings BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(N'staging.documentos') IS NULL OR OBJECT_ID(N'staging.cronicas') IS NULL
        THROW 50102, N'Faltan staging.documentos o staging.cronicas: hay que cargar antes data\documentos.csv y data\cronicas.csv.', 1;

    DECLARE @Resumen TABLE (Accion NVARCHAR(40), Documentos INT);
    CREATE TABLE #D (Orden INT IDENTITY PRIMARY KEY, Clave NVARCHAR(200) COLLATE DATABASE_DEFAULT,
                     Tipo VARCHAR(20) COLLATE DATABASE_DEFAULT, Titulo NVARCHAR(150) COLLATE DATABASE_DEFAULT,
                     Texto NVARCHAR(MAX) COLLATE DATABASE_DEFAULT, EquipoID INT, PartidoID INT,
                     Fuente NVARCHAR(200) COLLATE DATABASE_DEFAULT);

    -- 2.1 Avisos sobre las crónicas del CSV (no paran la carga).
    DECLARE @Avisos TABLE (Aviso NVARCHAR(600));
    INSERT @Avisos
    SELECT CONCAT(N'AVISO: la crónica del partido ', c.partido_id,
                  CASE WHEN p.PartidoID IS NULL THEN N' no corresponde a ningún partido: se ignora.'
                       WHEN p.Estado <> 'Finalizado' THEN N' es de un partido que no está finalizado: se ignora.'
                       ELSE CONCAT(N' tiene un título que no coincide con el marcador («', c.titulo, N'» frente a «', g.Titulo, N'»).') END) AS Aviso
    FROM staging.cronicas AS c
    LEFT JOIN liga.Partido AS p ON p.PartidoID = TRY_CONVERT(INT, c.partido_id)
    LEFT JOIN ia.vw_CronicaGenerada AS g ON g.PartidoID = p.PartidoID
    WHERE p.PartidoID IS NULL OR p.Estado <> 'Finalizado' OR c.titulo <> g.Titulo
    UNION ALL
    SELECT CONCAT(N'AVISO: el partido ', g.PartidoID, N' («', g.Titulo, N'») no tiene crónica en data\cronicas.csv: se usa la generada.')
    FROM ia.vw_CronicaGenerada AS g
    WHERE NOT EXISTS (SELECT 1 FROM staging.cronicas AS c WHERE TRY_CONVERT(INT, c.partido_id) = g.PartidoID);
    IF EXISTS (SELECT 1 FROM @Avisos) SELECT Aviso FROM @Avisos;

    -- 2.2 Lo que debería haber, en el orden de inserción de siempre (así los DocumentoID se repiten).
    INSERT INTO #D (Clave, Tipo, Titulo, Texto, EquipoID, PartidoID, Fuente)
    SELECT CONCAT(d.tipo, N'|', d.titulo), d.tipo, d.titulo, d.texto, NULL, NULL, NULLIF(d.fuente, N'')
    FROM staging.documentos AS d
    ORDER BY CASE d.tipo WHEN 'reglamento' THEN 1 ELSE 2 END, d.fila;

    INSERT INTO #D (Clave, Tipo, Titulo, Texto, EquipoID, PartidoID, Fuente)
    SELECT CONCAT(N'ficha_equipo|', f.EquipoID), 'ficha_equipo', f.Titulo, f.Texto, f.EquipoID, NULL, f.Fuente
    FROM ia.vw_FichaEquipo AS f ORDER BY f.EquipoID;

    INSERT INTO #D (Clave, Tipo, Titulo, Texto, EquipoID, PartidoID, Fuente)
    SELECT CONCAT(N'resumen_jornada|', r.Titulo), 'resumen_jornada', r.Titulo, r.Texto, NULL, NULL, r.Fuente
    FROM ia.vw_ResumenJornada AS r ORDER BY r.Numero;

    INSERT INTO #D (Clave, Tipo, Titulo, Texto, EquipoID, PartidoID, Fuente)
    SELECT CONCAT(N'cronica_partido|', g.PartidoID), 'cronica_partido',
           COALESCE(c.titulo, g.Titulo), COALESCE(c.texto, g.Texto), NULL, g.PartidoID,
           CASE WHEN c.partido_id IS NULL THEN g.Fuente ELSE NULLIF(c.fuente, N'') END
    FROM ia.vw_CronicaGenerada AS g
    LEFT JOIN staging.cronicas AS c ON TRY_CONVERT(INT, c.partido_id) = g.PartidoID
    ORDER BY g.PartidoID;

    -- 2.3 Comparar con lo que hay (clave lógica: tipo + equipo/partido/título).
    SELECT d.DocumentoID, k.Clave
    INTO #Actual
    FROM ia.Documento AS d
    CROSS APPLY (SELECT CASE d.Tipo WHEN 'ficha_equipo'    THEN CONCAT(N'ficha_equipo|', d.EquipoID)
                                    WHEN 'cronica_partido' THEN CONCAT(N'cronica_partido|', d.PartidoID)
                                    ELSE CONCAT(d.Tipo, N'|', d.Titulo) END COLLATE DATABASE_DEFAULT AS Clave) AS k;

    BEGIN TRANSACTION;
        -- Cambiados: se actualiza el texto y, si cambia lo que se "lee", se borra el embedding.
        UPDATE d
        SET Titulo = n.Titulo, Texto = n.Texto, Fuente = n.Fuente, EquipoID = n.EquipoID, PartidoID = n.PartidoID,
            Embedding       = CASE WHEN d.Titulo = n.Titulo AND d.Texto = n.Texto THEN d.Embedding END,
            EmbeddingModelo = CASE WHEN d.Titulo = n.Titulo AND d.Texto = n.Texto THEN d.EmbeddingModelo END,
            EmbeddingFecha  = CASE WHEN d.Titulo = n.Titulo AND d.Texto = n.Texto THEN d.EmbeddingFecha END
        FROM ia.Documento AS d
        JOIN #Actual AS a ON a.DocumentoID = d.DocumentoID
        JOIN #D AS n ON n.Clave = a.Clave
        WHERE EXISTS (SELECT d.Titulo, d.Texto, d.Fuente, d.EquipoID, d.PartidoID
                      EXCEPT
                      SELECT n.Titulo, n.Texto, n.Fuente, n.EquipoID, n.PartidoID);
        INSERT @Resumen VALUES (N'Modificados', @@ROWCOUNT);

        -- Sobrantes: por ejemplo, la crónica de un partido que ya no está finalizado.
        DELETE d
        FROM ia.Documento AS d
        JOIN #Actual AS a ON a.DocumentoID = d.DocumentoID
        WHERE NOT EXISTS (SELECT 1 FROM #D AS n WHERE n.Clave = a.Clave);
        INSERT @Resumen VALUES (N'Borrados', @@ROWCOUNT);

        -- Nuevos.
        INSERT INTO ia.Documento (Tipo, Titulo, Texto, EquipoID, PartidoID, Fuente)
        SELECT n.Tipo, n.Titulo, n.Texto, n.EquipoID, n.PartidoID, n.Fuente
        FROM #D AS n
        WHERE NOT EXISTS (SELECT 1 FROM #Actual AS a WHERE a.Clave = n.Clave)
        ORDER BY n.Orden;
        INSERT @Resumen VALUES (N'Nuevos', @@ROWCOUNT);
    COMMIT TRANSACTION;

    -- 2.4 Embeddings: solo los que faltan. Si el modelo no responde, los textos quedan
    --     al día y los embeddings pendientes para la próxima ejecución.
    DECLARE @Pendientes INT = (SELECT COUNT(*) FROM ia.Documento WHERE Embedding IS NULL);
    IF @GenerarEmbeddings = 1 AND @Pendientes > 0
    BEGIN TRY
        UPDATE ia.Documento
        SET Embedding       = AI_GENERATE_EMBEDDINGS(CONCAT(Titulo, N'. ', Texto) USE MODEL bge_m3_ollama),
            EmbeddingModelo = N'bge-m3',
            EmbeddingFecha  = SYSDATETIME()
        WHERE Embedding IS NULL;
        INSERT @Resumen VALUES (N'Embeddings calculados', @@ROWCOUNT);
    END TRY
    BEGIN CATCH
        PRINT CONCAT(N'AVISO: no se han podido calcular los embeddings (', ERROR_MESSAGE(),
                     N'). ¿Están encendidos Ollama y Caddy? Se calcularán en la próxima ejecución.');
    END CATCH;

    INSERT @Resumen SELECT N'Pendientes de embedding', COUNT(*) FROM ia.Documento WHERE Embedding IS NULL;
    SELECT Accion, Documentos FROM @Resumen;
END;
GO

/* ---------- 3. Cargar los textos de data\ ---------- */
DROP VIEW  IF EXISTS staging.v_documentos;
DROP TABLE IF EXISTS staging.documentos, staging.cronicas;
GO
-- fila (IDENTITY) guarda el orden del fichero; se carga a través de una vista sin esa columna.
CREATE TABLE staging.documentos (fila INT IDENTITY, tipo NVARCHAR(20), titulo NVARCHAR(150), texto NVARCHAR(MAX), fuente NVARCHAR(200));
CREATE TABLE staging.cronicas   (partido_id NVARCHAR(20), titulo NVARCHAR(150), texto NVARCHAR(MAX), fuente NVARCHAR(200));
GO
CREATE VIEW staging.v_documentos AS SELECT tipo, titulo, texto, fuente FROM staging.documentos;
GO
BULK INSERT staging.v_documentos FROM '$(DataPath)\documentos.csv' WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a');
BULK INSERT staging.cronicas     FROM '$(DataPath)\cronicas.csv'   WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"', ROWTERMINATOR = '0x0a');
UPDATE staging.documentos SET fuente = REPLACE(fuente, NCHAR(13), N'');   -- por si llegan con CRLF
UPDATE staging.cronicas   SET fuente = REPLACE(fuente, NCHAR(13), N'');
IF EXISTS (SELECT 1 FROM staging.documentos WHERE tipo NOT IN (N'reglamento', N'faq'))
    THROW 50103, N'data\documentos.csv solo admite los tipos reglamento y faq.', 1;
GO

/* ---------- 4. Sincronizar y calcular los embeddings ---------- */
PRINT N'--- Sincronización de ia.Documento con los datos ---';
DECLARE @inicio DATETIME2 = SYSDATETIME();
EXEC ia.usp_SincronizarDocumentos;
PRINT CONCAT(N'Duración: ', DATEDIFF(MILLISECOND, @inicio, SYSDATETIME()), N' ms');
GO

DROP VIEW  IF EXISTS staging.v_documentos;
DROP TABLE IF EXISTS staging.documentos, staging.cronicas;
GO

PRINT N'--- Documentos por tipo ---';
SELECT Tipo, COUNT(*) AS Documentos, MIN(LEN(Texto)) AS LongMin, MAX(LEN(Texto)) AS LongMax,
       SUM(CASE WHEN Embedding IS NULL THEN 1 ELSE 0 END) AS SinEmbedding
FROM ia.Documento GROUP BY Tipo ORDER BY Tipo;

PRINT N'--- Ejemplos de texto (primeros 330 caracteres) ---';
SELECT Tipo, CAST(Titulo AS NVARCHAR(45)) AS Titulo, CAST(LEFT(Texto, 330) AS NVARCHAR(330)) AS Texto
FROM ia.Documento
WHERE DocumentoID IN (
    (SELECT MIN(DocumentoID) FROM ia.Documento WHERE Tipo = 'ficha_equipo'),
    (SELECT MIN(DocumentoID) FROM ia.Documento WHERE Tipo = 'resumen_jornada'),
    (SELECT MAX(DocumentoID) FROM ia.Documento WHERE Tipo = 'resumen_jornada'),
    (SELECT MIN(DocumentoID) FROM ia.Documento WHERE Tipo = 'cronica_partido'))
ORDER BY DocumentoID;

/* ---------- 5. Comprobación de la norma L2 ---------- */
PRINT N'--- Norma L2 de los vectores (VECTOR_NORM, norm2) ---';
SELECT COUNT(*)                                                  AS Vectores,
       CAST(MIN(VECTOR_NORM(Embedding, 'norm2')) AS DECIMAL(9,6)) AS NormaMin,
       CAST(AVG(VECTOR_NORM(Embedding, 'norm2')) AS DECIMAL(9,6)) AS NormaMedia,
       CAST(MAX(VECTOR_NORM(Embedding, 'norm2')) AS DECIMAL(9,6)) AS NormaMax,
       CAST(MIN(VECTORPROPERTY(Embedding, 'Dimensions')) AS INT)  AS Dimensiones
FROM ia.Documento WHERE Embedding IS NOT NULL;
GO

/* ---------- 6. Si ya existe el índice Full-Text (Bloque F), esperar a que esté al día ----------
   Se actualiza en segundo plano; sin esta espera, una búsqueda justo después vería datos a medias. */
IF EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID(N'ia.Documento'))
BEGIN
    DECLARE @espera INT = 0;
    WHILE (OBJECTPROPERTYEX(OBJECT_ID(N'ia.Documento'), 'TableFulltextPendingChanges') > 0
           OR FULLTEXTCATALOGPROPERTY(N'ft_liga', 'PopulateStatus') <> 0)
          AND @espera < 60
    BEGIN
        WAITFOR DELAY '00:00:01';
        SET @espera += 1;
    END;
    PRINT CONCAT(N'Índice Full-Text al día (', @espera, N' s de espera).');
END;
GO

-- Al final, para que instalar.ps1 se pare si el modelo no ha respondido
-- (actualizar.ps1 lo trata como un aviso: los datos ya están actualizados).
IF EXISTS (SELECT 1 FROM ia.Documento WHERE Embedding IS NULL)
    THROW 50101, N'Quedan documentos sin embedding. Enciende Ollama y Caddy y vuelve a ejecutar el script.', 1;
GO
