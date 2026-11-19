/* =============================================================================
   ai/intenciones.sql
   Goalmetry - Idea 8: preguntas que se responden con una tarjeta de datos, sin LLM.
     1. ia.usp_ReconocerEntidades (ai/rag.sql) busca equipos, jugadores y árbitros en la pregunta.
     2. Lo que se ha nombrado decide qué intenciones son posibles (comparar exige dos equipos...).
     3. Entre esas, gana la frase de ejemplo más cercana por VECTOR_DISTANCE con embeddings bge-m3.
     4. Solo si está cerca (umbral calibrado en tests/intenciones_evaluacion.sql) se ejecuta la
        consulta paramétrica de esa intención. Si no, la pregunta sigue al RAG de siempre.
   El modelo de lenguaje no elige nada ni escribe nada: textos y filas salen de SQL.
   Ejecución:  sqlcmd -S localhost -E -C -b -i ai\intenciones.sql   (necesita Ollama y Caddy)
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

IF OBJECT_ID(N'ia.IntencionFrase', N'U') IS NULL
CREATE TABLE ia.IntencionFrase
(
    FraseID   INT IDENTITY(1,1) NOT NULL,
    Intencion VARCHAR(20)       NOT NULL,
    Frase     NVARCHAR(150)     NOT NULL,
    Embedding VECTOR(1024)      NULL,
    CONSTRAINT PK_IntencionFrase PRIMARY KEY (FraseID),
    CONSTRAINT UQ_IntencionFrase UNIQUE (Intencion, Frase)
);
IF OBJECT_ID(N'ia.Intencion', N'U') IS NULL
CREATE TABLE ia.Intencion
(
    Intencion VARCHAR(20)   NOT NULL,
    Titulo    NVARCHAR(60)  NOT NULL,
    Requiere  VARCHAR(2)    NOT NULL,   -- '' nada · E un equipo · EE dos · J un jugador · R un árbitro · N una jornada
    Umbral    FLOAT         NOT NULL,   -- distancia coseno máxima para responder con tarjeta
    CONSTRAINT PK_Intencion PRIMARY KEY (Intencion)
);
GO

MERGE ia.Intencion AS d
-- Umbrales calibrados con tests/intenciones_evaluacion.sql. Son estrictos con una sola entidad: con el nombre
-- quitado, «¿cuántos años tiene X?» queda muy cerca de «¿cuántos goles lleva X?» y la ficha no lo contesta.
USING (VALUES ('clasificacion', N'Clasificación', '', 0.20), ('goleadores', N'Máximos goleadores', '', 0.20), ('equipo', N'Equipo', 'E', 0.12),
              ('comparar', N'Comparación de equipos', 'EE', 0.25), ('enfrentamiento', N'Partidos entre dos equipos', 'EE', 0.25),
              ('jugador', N'Jugador', 'J', 0.12), ('arbitro', N'Árbitro', 'R', 0.12), ('jornada', N'Jornada', 'N', 0.25)) AS o (Intencion, Titulo, Requiere, Umbral)
   ON d.Intencion = o.Intencion
WHEN MATCHED THEN UPDATE SET Titulo = o.Titulo, Requiere = o.Requiere, Umbral = o.Umbral
WHEN NOT MATCHED THEN INSERT (Intencion, Titulo, Requiere, Umbral) VALUES (o.Intencion, o.Titulo, o.Requiere, o.Umbral);
GO

-- X es lo que se ha reconocido en la pregunta: así la frase compara la intención y no el nombre.
MERGE ia.IntencionFrase AS d
USING (VALUES
 ('clasificacion', N'clasificación de la liga'), ('clasificacion', N'cómo va la clasificación'), ('clasificacion', N'enséñame la tabla de la liga'), ('clasificacion', N'cómo va la tabla'), ('clasificacion', N'quién va primero en la liga'),
 ('clasificacion', N'quién lidera la clasificación y con cuántos puntos'), ('clasificacion', N'qué equipo es el último de la clasificación'),
 ('clasificacion', N'qué equipo va segundo'), ('clasificacion', N'qué equipos están en descenso ahora mismo'),
 ('clasificacion', N'qué equipo ha encajado menos goles'), ('clasificacion', N'qué equipo ha marcado más goles'),
 ('goleadores', N'máximo goleador de la liga'), ('goleadores', N'quién es el pichichi'), ('goleadores', N'qué jugador ha marcado más goles'),
 ('goleadores', N'tabla de goleadores'), ('goleadores', N'quién marca más goles esta temporada'),
 ('equipo', N'cómo va X'), ('equipo', N'datos de X'), ('equipo', N'cuántos puntos tiene X'), ('equipo', N'en qué puesto de la clasificación va X'),
 ('equipo', N'cuántos goles ha marcado X esta temporada'), ('equipo', N'cuántos goles ha encajado X'), ('equipo', N'cuántos partidos ha ganado X'),
 ('equipo', N'cuántos partidos ha perdido X'), ('equipo', N'cuántos partidos ha empatado X'), ('equipo', N'cuántas victorias lleva X'),
 ('equipo', N'máximo goleador de X'), ('equipo', N'qué jugador de X ha marcado más goles'), ('equipo', N'contra qué equipo ha perdido X'),
 ('comparar', N'compara X y X'), ('comparar', N'quién va mejor X o X'), ('comparar', N'diferencia de puntos entre X y X'),
 ('comparar', N'cuántos puntos separan a X de X'), ('comparar', N'comparación de X con X'),
 ('enfrentamiento', N'cómo quedó el partido entre X y X'), ('enfrentamiento', N'qué resultado hubo en el X X'), ('enfrentamiento', N'cuál fue el marcador del X contra X'),
 ('enfrentamiento', N'qué equipo ganó el partido entre X y X'), ('enfrentamiento', N'qué día se jugó el X X'), ('enfrentamiento', N'en qué jornada se enfrentaron X y X'),
 ('enfrentamiento', N'quién marcó los goles del X X'), ('enfrentamiento', N'quién arbitró el X contra X'),
 ('jugador', N'cuántos goles ha marcado X'), ('jugador', N'cuántos goles lleva X esta temporada'), ('jugador', N'estadísticas de X'),
 ('jugador', N'cuántas asistencias ha dado X'), ('jugador', N'cuántos minutos ha jugado X'), ('jugador', N'cuántos penaltis ha marcado X'),
 ('jugador', N'cuántos partidos ha jugado X'), ('jugador', N'cómo va X esta temporada'), ('jugador', N'en qué equipo juega X'),
 ('arbitro', N'cuántos partidos ha arbitrado X'), ('arbitro', N'datos del árbitro X'), ('arbitro', N'cuántos goles hubo en los partidos que dirigió X'),
 ('arbitro', N'perfil del árbitro X'), ('arbitro', N'cuántos partidos ha dirigido X'),
 ('jornada', N'resultados de la jornada'), ('jornada', N'cómo quedaron los partidos de la jornada'), ('jornada', N'cuántos goles se marcaron en total en la jornada'),
 ('jornada', N'partidos de la jornada'), ('jornada', N'qué pasó en la jornada')
) AS o (Intencion, Frase)
   ON d.Intencion = o.Intencion AND d.Frase = o.Frase
WHEN NOT MATCHED THEN INSERT (Intencion, Frase) VALUES (o.Intencion, o.Frase)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
GO

-- Embeddings de las frases que aún no lo tienen. Sin Ollama no se rompe nada: no habrá tarjetas y todo va al RAG.
DECLARE @id INT, @frase NVARCHAR(150), @v VECTOR(1024);
BEGIN TRY
    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @id = FraseID, @frase = Frase FROM ia.IntencionFrase WHERE Embedding IS NULL ORDER BY FraseID;
        IF @@ROWCOUNT = 0 BREAK;
        SET @v = AI_GENERATE_EMBEDDINGS(@frase USE MODEL bge_m3_ollama);
        UPDATE ia.IntencionFrase SET Embedding = @v WHERE FraseID = @id;
    END;
END TRY
BEGIN CATCH
    PRINT CONCAT(N'AVISO: quedan frases sin embedding (¿Ollama y Caddy en marcha?): ', ERROR_MESSAGE());
END CATCH;
GO

/* Decide la intención. Devuelve @Intencion NULL si no hay confianza, y la pregunta sigue al RAG. */
CREATE OR ALTER PROCEDURE ia.usp_ClasificarPregunta
    @Pregunta  NVARCHAR(500),
    @Intencion VARCHAR(20) = NULL OUTPUT,
    @Distancia FLOAT       = NULL OUTPUT,
    @Candidata VARCHAR(20) = NULL OUTPUT,
    @A         INT         = NULL OUTPUT,
    @B         INT         = NULL OUTPUT,
    @Jornada   INT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Intencion = NULL, @Distancia = NULL, @Candidata = NULL, @A = NULL, @B = NULL, @Jornada = NULL;

    -- Lo que la base de datos no tiene y lo que pide una estimación van siempre por el camino de siempre.
    DECLARE @tema VARCHAR(24);
    EXEC ia.usp_TemaNoSoportado @Pregunta = @Pregunta, @Tema = @tema OUTPUT;
    IF @tema IS NOT NULL RETURN;
    IF REGEXP_LIKE(@Pregunta, N'opciones|probabilidad|va a |descender|predic|pr[oó]xim|por qu[eé]|reglamento|norma|(ar|er|ir)[áÁ]n?([^\p{L}]|$)', 'i') RETURN;

    CREATE TABLE #Hallado (Orden INT IDENTITY, Tipo CHAR(1), ID INT, Nombre NVARCHAR(150) COLLATE DATABASE_DEFAULT);
    DECLARE @Texto NVARCHAR(700);
    EXEC ia.usp_ReconocerEntidades @Pregunta = @Pregunta, @Texto = @Texto OUTPUT;

    DECLARE @nE INT = (SELECT COUNT(*) FROM #Hallado WHERE Tipo = 'E'), @nJ INT = (SELECT COUNT(*) FROM #Hallado WHERE Tipo = 'J'),
            @nR INT = (SELECT COUNT(*) FROM #Hallado WHERE Tipo = 'R'), @nA INT = (SELECT COUNT(*) FROM #Hallado WHERE Tipo = 'A');
    SET @Jornada = TRY_CONVERT(INT, REGEXP_SUBSTR(@Pregunta, N'jornada\s*(\d{1,2})', 1, 1, 'i', 1));
    IF @Jornada IS NULL SET @Jornada = TRY_CONVERT(INT, REGEXP_SUBSTR(@Pregunta, N'\bJ(\d{1,2})\b', 1, 1, 'i', 1));

    -- Combinaciones sin tarjeta clara: anotador sin ficha, varios jugadores, personas y equipos mezclados...
    DECLARE @Requiere VARCHAR(2) =
        CASE WHEN @nA > 0 OR @nJ > 1 OR @nR > 1 OR @nE > 2 OR (@nJ > 0 AND (@nE > 0 OR @nR > 0)) OR (@nR > 0 AND @nE > 0) THEN NULL
             WHEN @nE = 2 THEN 'EE'
             WHEN @nE = 1 AND @Jornada IS NULL THEN 'E'
             WHEN @nE = 1 THEN NULL
             WHEN @nJ = 1 AND @Jornada IS NULL THEN 'J'
             WHEN @nJ = 1 THEN NULL
             WHEN @nR = 1 THEN 'R'
             WHEN @Jornada IS NOT NULL THEN 'N'
             ELSE '' END;
    IF @Requiere IS NULL RETURN;

    IF @Jornada IS NOT NULL AND @Requiere = 'EE' AND NOT EXISTS (SELECT 1 FROM liga.Jornada WHERE Numero = @Jornada) RETURN;

    DECLARE @v VECTOR(1024);
    DECLARE @paraEmbeber NVARCHAR(700) = TRIM(REPLACE(@Texto, N'|', N'X'));
    SET @paraEmbeber = REGEXP_REPLACE(@paraEmbeber, N'\bJ(\d{1,2})\b', N'jornada \1');
    BEGIN TRY
        SET @v = AI_GENERATE_EMBEDDINGS(@paraEmbeber USE MODEL bge_m3_ollama);
    END TRY
    BEGIN CATCH
        RETURN;   -- sin embeddings no hay tarjeta; el RAG dirá lo que corresponda
    END CATCH;

    SELECT TOP (1) @Candidata = f.Intencion, @Distancia = VECTOR_DISTANCE('cosine', f.Embedding, @v)
    FROM ia.IntencionFrase AS f JOIN ia.Intencion AS i ON i.Intencion = f.Intencion
    WHERE f.Embedding IS NOT NULL AND i.Requiere = @Requiere
    ORDER BY VECTOR_DISTANCE('cosine', f.Embedding, @v);

    IF @Distancia IS NOT NULL AND @Distancia <= (SELECT Umbral FROM ia.Intencion WHERE Intencion = @Candidata)
    BEGIN
        SET @Intencion = @Candidata;
        SELECT @A = CASE WHEN Tipo IN ('E', 'J', 'R') THEN ID END FROM #Hallado WHERE Orden = (SELECT MIN(Orden) FROM #Hallado);
        SELECT @B = ID FROM #Hallado WHERE Orden = (SELECT MAX(Orden) FROM #Hallado) AND Orden > (SELECT MIN(Orden) FROM #Hallado);
    END;
END;
GO

/* Texto de la tarjeta, sin las filas. Lo usan ia.usp_TarjetaPregunta (pantalla de preguntas) e ia.usp_PreguntarLiga
   (el RAG responde con él, sin llamar al modelo, cuando la base de datos reconoce la pregunta).
   Cada texto tiene que contestar la pregunta por sí solo. Devuelve @Intencion NULL si no hay tarjeta. */
CREATE OR ALTER PROCEDURE ia.usp_TextoTarjeta
    @Pregunta  NVARCHAR(500),
    @Intencion VARCHAR(20)    = NULL OUTPUT,
    @Distancia FLOAT          = NULL OUTPUT,
    @Candidata VARCHAR(20)    = NULL OUTPUT,
    @A         INT            = NULL OUTPUT,
    @B         INT            = NULL OUTPUT,
    @N         INT            = NULL OUTPUT,
    @Titulo    NVARCHAR(150)  = NULL OUTPUT,
    @Texto     NVARCHAR(2000) = NULL OUTPUT,
    @Enlace    NVARCHAR(100)  = NULL OUTPUT,
    @Grafico   VARCHAR(10)    = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Intencion = NULL, @Distancia = NULL, @Candidata = NULL, @Titulo = NULL, @Texto = NULL, @Enlace = NULL, @Grafico = NULL;
    DECLARE @i VARCHAR(20), @d FLOAT, @cand VARCHAR(20);
    EXEC ia.usp_ClasificarPregunta @Pregunta = @Pregunta, @Intencion = @i OUTPUT, @Distancia = @d OUTPUT, @Candidata = @cand OUTPUT,
         @A = @A OUTPUT, @B = @B OUTPUT, @Jornada = @N OUTPUT;

    SET @Titulo = (SELECT Titulo FROM ia.Intencion WHERE Intencion = @i);   -- (@texto, @enlace y @grafico son los propios parámetros de salida)
    DECLARE @jornadas INT = (SELECT MAX(j.Numero) FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID WHERE p.Estado = 'Finalizado');

    IF @i = 'clasificacion'
    BEGIN
        -- Según lo que se pregunte, el texto da justo ese dato (con empates, todos los equipos empatados).
        DECLARE @lista NVARCHAR(400), @valor INT;
        IF REGEXP_LIKE(@Pregunta, N'saca|ventaja|diferencia|distancia', 'i')
            SELECT @texto = CONCAT(N'El líder, ', a.Equipo, N', le saca ', a.Pts - b.Pts, N' puntos al segundo, ', b.Equipo, N'.')
            FROM (SELECT TOP (1) Equipo, Pts FROM liga.vw_Clasificacion WHERE Posicion = 1 ORDER BY Equipo) AS a
            CROSS JOIN (SELECT TOP (1) Equipo, Pts FROM liga.vw_Clasificacion WHERE Posicion = 2 ORDER BY Equipo) AS b;
        ELSE IF REGEXP_LIKE(@Pregunta, N'encajad|en contra|menos goles', 'i')
        BEGIN
            SELECT @lista = STRING_AGG(Equipo, N', ') WITHIN GROUP (ORDER BY Equipo), @valor = MIN(GC)
            FROM liga.vw_Clasificacion WHERE GC = (SELECT MIN(GC) FROM liga.vw_Clasificacion);
            SET @lista = CASE WHEN CHARINDEX(N', ', @lista) > 0 THEN STUFF(@lista, LEN(@lista) - CHARINDEX(N' ,', REVERSE(@lista)), 2, N' y ') ELSE @lista END;
            SET @texto = CONCAT(N'El equipo que menos goles ha encajado es ', @lista, N', con ', @valor, N' goles en contra.');
        END
        ELSE IF REGEXP_LIKE(@Pregunta, N'marcad|a favor|m[aá]s goles', 'i')
        BEGIN
            SELECT @lista = STRING_AGG(Equipo, N', ') WITHIN GROUP (ORDER BY Equipo), @valor = MAX(GF)
            FROM liga.vw_Clasificacion WHERE GF = (SELECT MAX(GF) FROM liga.vw_Clasificacion);
            SET @lista = CASE WHEN CHARINDEX(N', ', @lista) > 0 THEN STUFF(@lista, LEN(@lista) - CHARINDEX(N' ,', REVERSE(@lista)), 2, N' y ') ELSE @lista END;
            SET @texto = CONCAT(N'El equipo que más goles ha marcado es ', @lista, N', con ', @valor, N' goles a favor.');
        END
        ELSE IF REGEXP_LIKE(@Pregunta, N'segund', 'i')
        BEGIN
            SELECT @lista = STRING_AGG(Equipo, N', ') WITHIN GROUP (ORDER BY Equipo), @valor = MAX(Pts)
            FROM liga.vw_Clasificacion WHERE Posicion = 2;
            SET @lista = CASE WHEN CHARINDEX(N', ', @lista) > 0 THEN STUFF(@lista, LEN(@lista) - CHARINDEX(N' ,', REVERSE(@lista)), 2, N' y ') ELSE @lista END;
            SET @texto = CONCAT(N'El segundo clasificado es ', @lista, N', con ', @valor, N' puntos.');
        END
        ELSE IF REGEXP_LIKE(@Pregunta, N'[uú]ltim', 'i')
        BEGIN
            SELECT @lista = STRING_AGG(Equipo, N', ') WITHIN GROUP (ORDER BY Equipo), @valor = MAX(Pts)
            FROM liga.vw_Clasificacion WHERE Posicion = (SELECT MAX(Posicion) FROM liga.vw_Clasificacion);
            SET @lista = CASE WHEN CHARINDEX(N', ', @lista) > 0 THEN STUFF(@lista, LEN(@lista) - CHARINDEX(N' ,', REVERSE(@lista)), 2, N' y ') ELSE @lista END;
            SET @texto = CONCAT(N'El último de la clasificación es ', @lista, N', con ', @valor, N' puntos.');
        END
        IF @texto IS NULL
            SELECT @texto = CONCAT(a.Equipo, N' lidera con ', a.Pts, N' puntos tras ', @jornadas, N' jornadas. ', z.Equipo, N' es último con ', z.Pts, N'.')
            FROM (SELECT TOP (1) Equipo, Pts FROM liga.vw_Clasificacion ORDER BY Posicion, Equipo) AS a
            CROSS JOIN (SELECT TOP (1) Equipo, Pts FROM liga.vw_Clasificacion ORDER BY Posicion DESC, Equipo DESC) AS z;
        SET @enlace = N'/';
    END
    ELSE IF @i = 'goleadores'
    BEGIN
        SELECT TOP (1) @texto = CONCAT(Anotador, N' (', Equipo, N') es el máximo goleador con ', Goles, N' goles.')
        FROM liga.vw_MaximosGoleadores ORDER BY Posicion, Anotador;
        SET @enlace = N'/rankings';
    END
    ELSE IF @i = 'equipo'
    BEGIN
        SELECT @titulo = c.Equipo, @enlace = CONCAT(N'/equipo/', c.EquipoID),
               @texto = CONCAT(c.Equipo, N' va ', c.Posicion, N'º con ', c.Pts, N' puntos: ', c.G, N' ganados, ', c.E, N' empatados y ', c.P, N' perdidos; ',
                               c.GF, N' goles a favor y ', c.GC, N' en contra.',
                               CASE WHEN c.G = 0 THEN N' No ha ganado ningún partido.' ELSE N'' END,
                               CASE WHEN c.P = 0 THEN N' No ha perdido ningún partido.' ELSE N'' END,
                               (SELECT CONCAT(N' Ha perdido contra: ', STRING_AGG(CONCAT(r.Rival, N' (jornada ', r.Jornada, N')'), N', ') WITHIN GROUP (ORDER BY r.Jornada), N'.')
                                FROM analisis.vw_ResultadoEquipo AS r WHERE r.EquipoID = c.EquipoID AND r.Resultado = 'D' HAVING COUNT(*) > 0),
                               (SELECT CONCAT(N' Ha empatado con: ', STRING_AGG(CONCAT(r.Rival, N' (jornada ', r.Jornada, N')'), N', ') WITHIN GROUP (ORDER BY r.Jornada), N'.')
                                FROM analisis.vw_ResultadoEquipo AS r WHERE r.EquipoID = c.EquipoID AND r.Resultado = 'E' HAVING COUNT(*) > 0),
                               (SELECT TOP (1) CONCAT(N' Su máximo goleador es ', g.Anotador, N' (', g.Goles, N').') FROM liga.vw_MaximosGoleadores AS g
                                JOIN liga.Equipo AS e ON e.Nombre = g.Equipo WHERE e.EquipoID = c.EquipoID ORDER BY g.Goles DESC, g.Anotador))
        FROM liga.vw_Clasificacion AS c WHERE c.EquipoID = @A;
    END
    ELSE IF @i = 'comparar'
    BEGIN
        SELECT @titulo = CONCAT(a.Equipo, N' y ', b.Equipo), @grafico = 'pares',
               @texto = CONCAT(a.Equipo, N' va ', a.Posicion, N'º con ', a.Pts, N' puntos y ', b.Equipo, N' va ', b.Posicion, N'º con ', b.Pts,
                               N': ', ABS(a.Pts - b.Pts), N' puntos de diferencia.')
        FROM liga.vw_Clasificacion AS a CROSS JOIN liga.vw_Clasificacion AS b WHERE a.EquipoID = @A AND b.EquipoID = @B;
    END
    ELSE IF @i = 'enfrentamiento'
    BEGIN
        SELECT @titulo = CONCAT(a.Nombre, N' y ', b.Nombre) FROM liga.Equipo AS a CROSS JOIN liga.Equipo AS b WHERE a.EquipoID = @A AND b.EquipoID = @B;
        SELECT @texto = STRING_AGG(CONCAT(N'Jornada ', j.Numero,
                                          CASE WHEN p.FechaHora IS NOT NULL THEN CONCAT(N' (', FORMAT(p.FechaHora, 'dd/MM/yyyy'), N')') ELSE N'' END, N': ',
                                          l.Nombre, N' ', CASE WHEN p.Estado = 'Finalizado' THEN CONCAT(p.GolesLocal, N'-', p.GolesVisitante) ELSE N'(por jugar)' END, N' ', v.Nombre, N'.',
                                          CASE WHEN a.Nombre IS NOT NULL THEN CONCAT(N' Árbitro: ', a.Nombre, N'.') ELSE N'' END,
                                          CASE WHEN gg.Detalle IS NOT NULL THEN CONCAT(N' Goles: ', gg.Detalle, N'.') ELSE N'' END), N' ')
                                   WITHIN GROUP (ORDER BY j.Numero)
        FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        JOIN liga.Equipo AS l ON l.EquipoID = p.EquipoLocalID JOIN liga.Equipo AS v ON v.EquipoID = p.EquipoVisitanteID
        LEFT JOIN liga.Arbitro AS a ON a.ArbitroID = p.ArbitroPrincipalID
        OUTER APPLY (SELECT STRING_AGG(CONCAT(g.Anotador, N' (', g.Minuto, N''')'), N', ') WITHIN GROUP (ORDER BY g.Minuto, g.GolID) AS Detalle
                     FROM liga.Gol AS g WHERE g.PartidoID = p.PartidoID) AS gg
        WHERE p.EquipoLocalID IN (@A, @B) AND p.EquipoVisitanteID IN (@A, @B) AND (@N IS NULL OR j.Numero = @N);
        IF @texto IS NULL SET @i = NULL;
    END
    ELSE IF @i = 'jugador'
    BEGIN
        -- Goles de las actas; minutos y asistencias de la ficha (que llega hasta su UltimaJornada). Los partidos jugados no constan.
        SELECT @titulo = j.Nombre, @enlace = CONCAT(N'/parecidos?jugador=', j.JugadorID),
               @texto = CONCAT(j.Nombre, N' (', e.Nombre, N') lleva ', g.Goles, N' goles', CASE WHEN g.Penaltis > 0 THEN CONCAT(N', ', g.Penaltis, N' de penalti') ELSE N'' END, N'.',
                               N' Según su ficha (datos hasta la jornada ', COALESCE(j.UltimaJornada, 0), N'): ', j.Asistencias, N' asistencias y ', j.MinutosJugados,
                               N' minutos jugados. Los partidos jugados no constan en la base de datos.')
        FROM liga.Jugador AS j JOIN liga.Equipo AS e ON e.EquipoID = j.EquipoID
        CROSS APPLY (SELECT COUNT(CASE WHEN x.Tipo <> 'PropiaPuerta' THEN 1 END) AS Goles, COUNT(CASE WHEN x.Tipo = 'Penalti' THEN 1 END) AS Penaltis
                     FROM liga.Gol AS x WHERE x.JugadorID = j.JugadorID) AS g
        WHERE j.JugadorID = @A;
    END
    ELSE IF @i = 'arbitro'
    BEGIN
        SELECT @titulo = a.Nombre, @enlace = CONCAT(N'/arbitro/', a.ArbitroID),
               @texto = CONCAT(a.Nombre, N' ha dirigido ', a.Partidos, N' partidos, con ', a.Goles, N' goles en total.')
        FROM analisis.vw_Arbitro AS a WHERE a.ArbitroID = @A;
    END
    ELSE IF @i = 'jornada'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID WHERE j.Numero = @N AND p.Estado = 'Finalizado')
            SET @i = NULL;
        ELSE
            SELECT @titulo = CONCAT(N'Jornada ', @N), @enlace = CONCAT(N'/jornadas/', @N),
                   @texto = CONCAT(N'En la jornada ', @N, N' se han jugado ', COUNT(*), N' partidos con ', SUM(CAST(p.GolesLocal AS INT) + p.GolesVisitante), N' goles en total.')
            FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID WHERE j.Numero = @N AND p.Estado = 'Finalizado';
    END;

    IF @texto IS NULL SET @i = NULL;
    SELECT @Intencion = @i, @Distancia = @d, @Candidata = @cand;
END;
GO

/* Tarjeta completa. Primer resultado: cabecera (Intencion NULL = sin tarjeta). Segundo: las filas. */
CREATE OR ALTER PROCEDURE ia.usp_TarjetaPregunta
    @Pregunta NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i VARCHAR(20), @d FLOAT, @cand VARCHAR(20), @A INT, @B INT, @N INT, @titulo NVARCHAR(150), @texto NVARCHAR(2000), @enlace NVARCHAR(100), @grafico VARCHAR(10);
    EXEC ia.usp_TextoTarjeta @Pregunta = @Pregunta, @Intencion = @i OUTPUT, @Distancia = @d OUTPUT, @Candidata = @cand OUTPUT,
         @A = @A OUTPUT, @B = @B OUTPUT, @N = @N OUTPUT, @Titulo = @titulo OUTPUT, @Texto = @texto OUTPUT, @Enlace = @enlace OUTPUT, @Grafico = @grafico OUTPUT;

    IF @i IS NULL
    BEGIN
        SELECT CAST(NULL AS VARCHAR(20)) AS Intencion, @cand AS Candidata, @d AS Distancia;
        RETURN;
    END;

    SELECT @i AS Intencion, @titulo AS Titulo, @texto AS Texto, @enlace AS Enlace, @grafico AS Grafico, @d AS Distancia;

    IF @i = 'clasificacion'
        SELECT Posicion AS Puesto, Equipo, PJ, G, E, P, GF, GC, Pts AS Puntos FROM liga.vw_Clasificacion ORDER BY Posicion, Equipo;
    ELSE IF @i = 'goleadores'
        SELECT TOP (10) Posicion AS Puesto, Anotador AS Jugador, Equipo, Goles, Penaltis FROM liga.vw_MaximosGoleadores ORDER BY Posicion, Anotador;
    ELSE IF @i = 'equipo'
        SELECT j.Numero AS Jornada,
               CONCAT(CASE WHEN p.EquipoLocalID = @A THEN N'En casa: ' ELSE N'Fuera: ' END, CASE WHEN p.EquipoLocalID = @A THEN v.Nombre ELSE l.Nombre END) AS Rival,
               CONCAT(p.GolesLocal, N'-', p.GolesVisitante) AS Marcador,
               CASE WHEN p.GolesLocal = p.GolesVisitante THEN N'Empate'
                    WHEN (p.GolesLocal > p.GolesVisitante AND p.EquipoLocalID = @A) OR (p.GolesLocal < p.GolesVisitante AND p.EquipoVisitanteID = @A) THEN N'Victoria'
                    ELSE N'Derrota' END AS Resultado
        FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        JOIN liga.Equipo AS l ON l.EquipoID = p.EquipoLocalID JOIN liga.Equipo AS v ON v.EquipoID = p.EquipoVisitanteID
        WHERE p.Estado = 'Finalizado' AND @A IN (p.EquipoLocalID, p.EquipoVisitanteID)
        ORDER BY j.Numero;
    ELSE IF @i = 'comparar'
    BEGIN
        DECLARE @nomA NVARCHAR(60) = (SELECT Equipo FROM liga.vw_Clasificacion WHERE EquipoID = @A),
                @nomB NVARCHAR(60) = (SELECT Equipo FROM liga.vw_Clasificacion WHERE EquipoID = @B);
        -- Los nombres de las columnas son los equipos: la pantalla los usa de cabecera.
        DECLARE @sql NVARCHAR(MAX) = CONCAT(
            N'SELECT v.Dato, v.A AS ', QUOTENAME(@nomA), N', v.B AS ', QUOTENAME(@nomB), N'
              FROM liga.vw_Clasificacion AS a CROSS JOIN liga.vw_Clasificacion AS b
              CROSS APPLY (VALUES (1, N''Puntos'', a.Pts, b.Pts), (2, N''Ganados'', a.G, b.G), (3, N''Empatados'', a.E, b.E), (4, N''Perdidos'', a.P, b.P),
                                  (5, N''Goles a favor'', a.GF, b.GF), (6, N''Goles en contra'', a.GC, b.GC)) AS v (Orden, Dato, A, B)
              WHERE a.EquipoID = @A AND b.EquipoID = @B ORDER BY v.Orden;');
        EXEC sys.sp_executesql @sql, N'@A INT, @B INT', @A = @A, @B = @B;
    END
    ELSE IF @i = 'enfrentamiento'
        SELECT j.Numero AS Jornada, FORMAT(p.FechaHora, 'dd/MM/yyyy') AS Fecha, CONCAT(l.Nombre, N' - ', v.Nombre) AS Partido,
               CASE WHEN p.Estado = 'Finalizado' THEN CONCAT(p.GolesLocal, N'-', p.GolesVisitante) ELSE N'por jugar' END AS Marcador,
               COALESCE(a.Nombre, N'—') AS [Árbitro],
               COALESCE((SELECT STRING_AGG(CONCAT(g.Anotador, N' (', g.Minuto, N''')', CASE g.Tipo WHEN 'Penalti' THEN N' de penalti' WHEN 'PropiaPuerta' THEN N' en propia' ELSE N'' END), N', ')
                                WITHIN GROUP (ORDER BY g.Minuto) FROM liga.Gol AS g WHERE g.PartidoID = p.PartidoID), N'—') AS Goles
        FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        JOIN liga.Equipo AS l ON l.EquipoID = p.EquipoLocalID JOIN liga.Equipo AS v ON v.EquipoID = p.EquipoVisitanteID
        LEFT JOIN liga.Arbitro AS a ON a.ArbitroID = p.ArbitroPrincipalID
        WHERE p.EquipoLocalID IN (@A, @B) AND p.EquipoVisitanteID IN (@A, @B) AND (@N IS NULL OR j.Numero = @N)
        ORDER BY j.Numero;
    ELSE IF @i = 'jugador'
    BEGIN
        -- Goles de las actas; minutos y asistencias de la ficha, que llega hasta su UltimaJornada.
        SELECT v.Dato, v.Valor
        FROM liga.Jugador AS j JOIN liga.Equipo AS e ON e.EquipoID = j.EquipoID
        CROSS APPLY (SELECT COUNT(CASE WHEN x.Tipo <> 'PropiaPuerta' THEN 1 END) AS Goles, COUNT(CASE WHEN x.Tipo = 'Penalti' THEN 1 END) AS Penaltis
                     FROM liga.Gol AS x WHERE x.JugadorID = j.JugadorID) AS g
        CROSS APPLY (VALUES (1, N'Equipo', e.Nombre),
                            (2, N'Posición', CASE j.Posicion WHEN 'PT' THEN N'Portero' WHEN 'DF' THEN N'Defensa' WHEN 'MC' THEN N'Centrocampista' WHEN 'DL' THEN N'Delantero' ELSE N'No consta' END),
                            (3, N'Goles', CONVERT(NVARCHAR(10), g.Goles)), (4, N'De penalti', CONVERT(NVARCHAR(10), g.Penaltis)),
                            (5, CONCAT(N'Asistencias (hasta la jornada ', j.UltimaJornada, N')'), CONVERT(NVARCHAR(10), j.Asistencias)),
                            (6, CONCAT(N'Minutos jugados (hasta la jornada ', j.UltimaJornada, N')'), CONVERT(NVARCHAR(10), j.MinutosJugados)),
                            (7, N'Partidos jugados', N'No consta')) AS v (Orden, Dato, Valor)
        WHERE j.JugadorID = @A ORDER BY v.Orden;
    END
    ELSE IF @i = 'arbitro'
        SELECT v.Dato, v.Valor
        FROM analisis.vw_Arbitro AS a
        CROSS APPLY (VALUES (1, N'Partidos dirigidos', a.Partidos), (2, N'Goles en sus partidos', a.Goles), (3, N'Victorias locales', a.VictoriasLocales),
                            (4, N'Empates', a.Empates), (5, N'Victorias visitantes', a.VictoriasVisitantes), (6, N'Penaltis marcados', a.PenaltisMarcados)) AS v (Orden, Dato, Valor)
        WHERE a.ArbitroID = @A ORDER BY v.Orden;
    ELSE IF @i = 'jornada'
        SELECT CONCAT(l.Nombre, N' - ', v.Nombre) AS Partido, CONCAT(p.GolesLocal, N'-', p.GolesVisitante) AS Marcador
        FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        JOIN liga.Equipo AS l ON l.EquipoID = p.EquipoLocalID JOIN liga.Equipo AS v ON v.EquipoID = p.EquipoVisitanteID
        WHERE j.Numero = @N AND p.Estado = 'Finalizado' ORDER BY p.FechaHora, p.PartidoID;
END;
GO
