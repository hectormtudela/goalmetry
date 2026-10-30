/* =============================================================================
   vector_search.sql
   Goalmetry (DP-800, Práctica 09) - Bloque F
   Búsqueda inteligente sobre ia.Documento (139 textos con embedding):
     1. Índice Full-Text en español (LCID 3082) con una lista de palabras vacías propia.
     2. ia.usp_BuscarDocumentos @Consulta, @Modo, @Top, @Tipo, @Candidatos:
          'vectorial' : similitud semántica, VECTOR_DISTANCE('cosine') exacta.
          'texto'     : palabras (con sus variantes: singular/plural, conjugaciones)
                        con FREETEXTTABLE sobre el índice Full-Text.
          'hibrida'   : fusión de las dos listas con Reciprocal Rank Fusion (RRF).
     3. Comparación de las tres búsquedas con las mismas preguntas.
   Por qué el coseno: mide el ángulo entre vectores y no depende de su longitud. En el
   Bloque E se midió que bge-m3 devuelve vectores de norma 1; entonces coseno, producto
   escalar y distancia euclídea dan el MISMO ORDEN (aquí se comprueba).
   Por qué búsqueda exacta y no índice vectorial (DiskANN): con 139 documentos recorrer
   todos es inmediato y da el resultado exacto; un índice aproximado solo compensa con
   cientos de miles de vectores.
   Ejecución:  sqlcmd -S localhost -E -C -b -i ai\vector_search.sql
   Requiere: Bloque E ejecutado (modelo bge_m3_ollama y embeddings) y Caddy en marcha.
   Idempotente.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

/* ---------- 1. Full-Text en español ---------- */
IF EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID(N'ia.Documento'))
    DROP FULLTEXT INDEX ON ia.Documento;
IF EXISTS (SELECT 1 FROM sys.fulltext_stoplists WHERE name = N'sl_liga_es')
    DROP FULLTEXT STOPLIST sl_liga_es;
IF EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = N'ft_liga')
    DROP FULLTEXT CATALOG ft_liga;
GO

CREATE FULLTEXT CATALOG ft_liga WITH ACCENT_SENSITIVITY = OFF;   -- "Mbappé" = "Mbappe"
GO

-- Se parte de la lista del sistema (que ya incluye el español) y se le añade una palabra:
-- "LaLiga" aparece en los resúmenes de jornada y no distingue unos textos de otros.
CREATE FULLTEXT STOPLIST sl_liga_es FROM SYSTEM STOPLIST;
ALTER FULLTEXT STOPLIST sl_liga_es ADD N'LaLiga' LANGUAGE 3082;
GO

CREATE FULLTEXT INDEX ON ia.Documento (Titulo LANGUAGE 3082, Texto LANGUAGE 3082)
    KEY INDEX PK_Documento ON ft_liga
    WITH CHANGE_TRACKING AUTO, STOPLIST = sl_liga_es;
GO

-- La población del índice es asíncrona: se espera a que termine (máx. 60 s).
DECLARE @intentos INT = 0;
WHILE FULLTEXTCATALOGPROPERTY(N'ft_liga', 'PopulateStatus') <> 0 AND @intentos < 60
BEGIN
    WAITFOR DELAY '00:00:01';
    SET @intentos += 1;
END;

PRINT N'--- Índice Full-Text ---';
SELECT CAST(FULLTEXTCATALOGPROPERTY(N'ft_liga', 'ItemCount') AS INT)           AS DocumentosIndexados,
       CAST(FULLTEXTCATALOGPROPERTY(N'ft_liga', 'PopulateStatus') AS INT)      AS EstadoPoblacion,   -- 0 = inactivo (terminado)
       (SELECT COUNT(*) FROM sys.fulltext_index_fragments) AS Fragmentos,
       (SELECT CAST(language_id AS INT) FROM sys.fulltext_index_columns fic
         WHERE fic.object_id = OBJECT_ID(N'ia.Documento') AND fic.column_id = COLUMNPROPERTY(OBJECT_ID(N'ia.Documento'), 'Texto', 'ColumnId')) AS IdiomaTexto;
GO

/* ---------- 2. ia.usp_BuscarDocumentos ---------- */
CREATE OR ALTER PROCEDURE ia.usp_BuscarDocumentos
    @Consulta   NVARCHAR(500),
    @Modo       VARCHAR(10) = 'hibrida',   -- 'vectorial' | 'texto' | 'hibrida'
    @Top        INT         = 5,           -- resultados que se devuelven
    @Tipo       VARCHAR(20) = NULL,        -- opcional: limita a un tipo de documento
    @Candidatos INT         = 20           -- tamaño de cada lista antes de fusionar (RRF)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Consulta IS NULL OR LEN(LTRIM(RTRIM(@Consulta))) = 0
        THROW 50201, N'La consulta no puede estar vacía.', 1;
    IF @Modo NOT IN ('vectorial', 'texto', 'hibrida')
        THROW 50202, N'El modo debe ser vectorial, texto o hibrida.', 1;
    IF @Top NOT BETWEEN 1 AND 50 OR @Candidatos NOT BETWEEN 1 AND 100
        THROW 50203, N'@Top debe estar entre 1 y 50, y @Candidatos entre 1 y 100.', 1;

    DECLARE @k INT = 60;                   -- constante habitual de RRF
    DECLARE @vector VECTOR(1024) = NULL;

    IF @Modo IN ('vectorial', 'hibrida')
        SET @vector = AI_GENERATE_EMBEDDINGS(@Consulta USE MODEL bge_m3_ollama);

    -- Lista vectorial: los @Candidatos documentos más cercanos (coseno exacto).
    CREATE TABLE #Vec (DocumentoID INT PRIMARY KEY, Rango INT NOT NULL, Distancia FLOAT NOT NULL);
    -- Lista de texto: los @Candidatos mejores según el índice Full-Text.
    CREATE TABLE #Txt (DocumentoID INT PRIMARY KEY, Rango INT NOT NULL, Rank INT NOT NULL);

    IF @vector IS NOT NULL
        INSERT INTO #Vec (DocumentoID, Rango, Distancia)
        SELECT TOP (@Candidatos) d.DocumentoID,
               ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', d.Embedding, @vector)),
               VECTOR_DISTANCE('cosine', d.Embedding, @vector)
        FROM ia.Documento AS d
        WHERE d.Embedding IS NOT NULL AND (@Tipo IS NULL OR d.Tipo = @Tipo)
        ORDER BY VECTOR_DISTANCE('cosine', d.Embedding, @vector);

    IF @Modo IN ('texto', 'hibrida')
        INSERT INTO #Txt (DocumentoID, Rango, Rank)
        SELECT TOP (@Candidatos) ft.[KEY],
               ROW_NUMBER() OVER (ORDER BY ft.[RANK] DESC, ft.[KEY]),
               ft.[RANK]
        FROM FREETEXTTABLE(ia.Documento, (Titulo, Texto), @Consulta, LANGUAGE 3082) AS ft
        JOIN ia.Documento AS d ON d.DocumentoID = ft.[KEY]
        WHERE @Tipo IS NULL OR d.Tipo = @Tipo
        ORDER BY ft.[RANK] DESC, ft.[KEY];

    SELECT TOP (@Top)
           d.DocumentoID,
           d.Tipo,
           d.Titulo,
           CAST(CASE @Modo
                    WHEN 'vectorial' THEN 1 - v.Distancia                       -- similitud coseno
                    WHEN 'texto'     THEN t.Rank / 1000.0                       -- RANK de Full-Text (0-1000)
                    ELSE 1.0 / (@k + COALESCE(v.Rango, 1000000))
                       + 1.0 / (@k + COALESCE(t.Rango, 1000000))                -- RRF
                END AS DECIMAL(9,6)) AS Puntuacion,
           v.Rango AS RangoVectorial,
           t.Rango AS RangoTexto
    FROM ia.Documento AS d
    LEFT JOIN #Vec AS v ON v.DocumentoID = d.DocumentoID
    LEFT JOIN #Txt AS t ON t.DocumentoID = d.DocumentoID
    WHERE (@Modo = 'vectorial' AND v.DocumentoID IS NOT NULL)
       OR (@Modo = 'texto'     AND t.DocumentoID IS NOT NULL)
       OR (@Modo = 'hibrida'   AND (v.DocumentoID IS NOT NULL OR t.DocumentoID IS NOT NULL))
    ORDER BY Puntuacion DESC, d.DocumentoID;
END;
GO

/* ---------- 3. Las tres métricas dan el mismo orden (vectores de norma 1) ---------- */
PRINT N'--- Coseno, producto escalar y euclídea ordenan igual (top 5 de una consulta) ---';
DECLARE @q VECTOR(1024) = AI_GENERATE_EMBEDDINGS(N'¿Quién es el máximo goleador de la liga?' USE MODEL bge_m3_ollama);
WITH M AS (
    SELECT DocumentoID,
           ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine',    Embedding, @q))       AS RangoCoseno,
           ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('dot',       Embedding, @q))       AS RangoEscalar,
           ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('euclidean', Embedding, @q))       AS RangoEuclidea
    FROM ia.Documento)
SELECT COUNT(*) AS Documentos,
       SUM(CASE WHEN RangoCoseno = RangoEscalar AND RangoCoseno = RangoEuclidea THEN 1 ELSE 0 END) AS ConMismoRango
FROM M;
GO

/* ---------- 4. Comparación de las tres búsquedas ---------- */
PRINT N'--- Mejor resultado (y top 3) de cada modo para preguntas distintas ---';
DECLARE @preguntas TABLE (N INT IDENTITY, Consulta NVARCHAR(200), Que NVARCHAR(100));
INSERT INTO @preguntas (Consulta, Que) VALUES
 (N'¿Cuántos puntos se llevan los que ganan un partido?', N'Pregunta con otras palabras'),
 (N'reglas de la posición adelantada',                      N'Sinónimo de "fuera de juego"'),
 (N'Gil Manzano',                                           N'Nombre propio (árbitro)'),
 (N'¿Cómo quedó el Valencia contra el Celta?',              N'Partido concreto'),
 (N'¿Quién marca más goles en el Barcelona?',               N'Pregunta sobre un equipo'),
 (N'jugadores expulsados por doble amonestación',           N'Concepto del reglamento');

DECLARE @res TABLE (N INT, Modo VARCHAR(10), Pos INT, DocumentoID INT, Titulo NVARCHAR(150));
DECLARE @n INT = 1, @c NVARCHAR(200), @modo VARCHAR(10);
WHILE @n <= (SELECT COUNT(*) FROM @preguntas)
BEGIN
    SELECT @c = Consulta FROM @preguntas WHERE N = @n;
    DECLARE @m INT = 1;
    WHILE @m <= 3
    BEGIN
        SET @modo = CHOOSE(@m, 'vectorial', 'texto', 'hibrida');
        CREATE TABLE #t (DocumentoID INT, Tipo VARCHAR(20), Titulo NVARCHAR(150), Puntuacion DECIMAL(9,6), RV INT, RT INT);
        INSERT INTO #t EXEC ia.usp_BuscarDocumentos @Consulta = @c, @Modo = @modo, @Top = 3;
        INSERT INTO @res SELECT @n, @modo, ROW_NUMBER() OVER (ORDER BY Puntuacion DESC, DocumentoID), DocumentoID, Titulo FROM #t;
        DROP TABLE #t;
        SET @m += 1;
    END;
    SET @n += 1;
END;

SELECT p.N, CAST(p.Consulta AS NVARCHAR(55)) AS Consulta, r.Modo,
       CAST(STRING_AGG(CONCAT(r.Pos, N'.', r.Titulo), N' | ') WITHIN GROUP (ORDER BY r.Pos) AS NVARCHAR(180)) AS Top3
FROM @preguntas AS p
JOIN @res AS r ON r.N = p.N
GROUP BY p.N, p.Consulta, r.Modo
ORDER BY p.N, CHOOSE(CASE r.Modo WHEN 'vectorial' THEN 1 WHEN 'texto' THEN 2 ELSE 3 END, 1, 2, 3);
GO

/* ---------- 5. Precisión objetiva: aciertos en el top 5 frente a lo que dicen las tablas ----------
   Dos preguntas cuya respuesta correcta se calcula con T-SQL (no a ojo), buscando solo crónicas. */
PRINT N'--- Aciertos en el top 5 (solo crónicas de partido) ---';
DECLARE @casos TABLE (Caso INT, Consulta NVARCHAR(100), PartidoID INT);
INSERT INTO @casos
SELECT 1, N'Gil Manzano', p.PartidoID
FROM liga.Partido AS p JOIN liga.Arbitro AS a ON a.ArbitroID = p.ArbitroPrincipalID
WHERE a.Nombre LIKE N'%Gil Manzano%' AND p.Estado = 'Finalizado'
UNION ALL
SELECT 2, N'Rayo Vallecano de Madrid', p.PartidoID
FROM liga.Partido AS p JOIN liga.Equipo AS e ON e.Nombre = N'Rayo Vallecano de Madrid'
WHERE p.Estado = 'Finalizado' AND e.EquipoID IN (p.EquipoLocalID, p.EquipoVisitanteID);

DECLARE @acierto TABLE (Caso INT, Modo VARCHAR(10), Aciertos INT);
DECLARE @i INT = 1, @cons NVARCHAR(100), @md VARCHAR(10), @j INT;
WHILE @i <= 2
BEGIN
    SELECT TOP 1 @cons = Consulta FROM @casos WHERE Caso = @i;
    SET @j = 1;
    WHILE @j <= 3
    BEGIN
        SET @md = CHOOSE(@j, 'vectorial', 'texto', 'hibrida');
        CREATE TABLE #t (DocumentoID INT, Tipo VARCHAR(20), Titulo NVARCHAR(150), Puntuacion DECIMAL(9,6), RV INT, RT INT);
        INSERT INTO #t EXEC ia.usp_BuscarDocumentos @Consulta = @cons, @Modo = @md, @Top = 5, @Tipo = 'cronica_partido';
        INSERT INTO @acierto
        SELECT @i, @md, COUNT(*)
        FROM #t AS t
        JOIN ia.Documento AS d ON d.DocumentoID = t.DocumentoID
        WHERE d.PartidoID IN (SELECT PartidoID FROM @casos WHERE Caso = @i);
        DROP TABLE #t;
        SET @j += 1;
    END;
    SET @i += 1;
END;

SELECT c.Consulta, c.Correctas AS PartidosReales, a.Modo, a.Aciertos AS AciertosEnTop5
FROM (SELECT Caso, MAX(Consulta) AS Consulta, COUNT(*) AS Correctas FROM @casos GROUP BY Caso) AS c
JOIN @acierto AS a ON a.Caso = c.Caso
ORDER BY c.Caso, CHOOSE(CASE a.Modo WHEN 'vectorial' THEN 1 WHEN 'texto' THEN 2 ELSE 3 END, 1, 2, 3);
GO

/* ---------- 6. Validación de parámetros ---------- */
PRINT N'--- Errores controlados del procedimiento ---';
DECLARE @pruebas TABLE (Caso NVARCHAR(40), Esperado INT, Obtenido INT);
BEGIN TRY EXEC ia.usp_BuscarDocumentos @Consulta = N'   '; INSERT @pruebas VALUES (N'Consulta vacía', 50201, 0); END TRY
BEGIN CATCH INSERT @pruebas VALUES (N'Consulta vacía', 50201, ERROR_NUMBER()); END CATCH;
BEGIN TRY EXEC ia.usp_BuscarDocumentos @Consulta = N'fuera de juego', @Modo = 'otro'; INSERT @pruebas VALUES (N'Modo inválido', 50202, 0); END TRY
BEGIN CATCH INSERT @pruebas VALUES (N'Modo inválido', 50202, ERROR_NUMBER()); END CATCH;
BEGIN TRY EXEC ia.usp_BuscarDocumentos @Consulta = N'fuera de juego', @Top = 0; INSERT @pruebas VALUES (N'@Top fuera de rango', 50203, 0); END TRY
BEGIN CATCH INSERT @pruebas VALUES (N'@Top fuera de rango', 50203, ERROR_NUMBER()); END CATCH;
SELECT Caso, Esperado, Obtenido, CASE WHEN Esperado = Obtenido THEN N'Correcto' ELSE N'FALLO' END AS Resultado FROM @pruebas;
IF EXISTS (SELECT 1 FROM @pruebas WHERE Esperado <> Obtenido) THROW 50204, N'Falla la validación de parámetros.', 1;
GO
