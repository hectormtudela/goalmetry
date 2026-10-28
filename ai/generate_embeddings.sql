/* =============================================================================
   generate_embeddings.sql
   Proyecto LigaDB (DP-800, Práctica 09) - Bloque E (2/2)
   Rellena ia.Documento y calcula el embedding de cada texto con el modelo externo
   bge_m3_ollama (ver create_external_model.sql).
     1. Reglamento y FAQ: textos redactados (cada uno con su Fuente).
     2. Fichas de equipo, resúmenes de jornada y crónicas de partido: GENERADOS SOLO
        con los datos de liga.* (STRING_AGG + plantilla fija). No se inventa nada.
     3. Embedding = AI_GENERATE_EMBEDDINGS(Titulo + Texto USE MODEL bge_m3_ollama).
     4. Comprobación de la norma L2 de los vectores (bge-m3 no se da por normalizado).
   Ejecución:  sqlcmd -S localhost -E -C -b -i ai\generate_embeddings.sql
   Idempotente: vacía ia.Documento y lo vuelve a generar (los IDs son reproducibles).
   Requiere: 01-05 ejecutados y bge_m3_ollama creado.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

TRUNCATE TABLE ia.Documento;
GO

/* ---------- 1. Reglamento y FAQ (redactados) ---------- */
INSERT INTO ia.Documento (Tipo, Titulo, Texto, Fuente)
VALUES
 ('reglamento', N'Puntuación de los partidos',
  N'En LaLiga cada victoria vale 3 puntos, cada empate 1 punto y cada derrota 0 puntos. La clasificación se construye sumando los puntos de todos los partidos finalizados.',
  N'Reglamento de la competición (resumen)'),
 ('reglamento', N'Formato de la competición',
  N'LaLiga la juegan 20 equipos en un sistema de liga: todos contra todos a doble vuelta, una vez como local y otra como visitante. Son 38 jornadas, con 10 partidos por jornada.',
  N'Reglamento de la competición (resumen)'),
 ('reglamento', N'Desempates en la clasificación',
  N'Cuando dos equipos empatan a puntos, el reglamento de la competición resuelve el desempate primero con el resultado de los enfrentamientos directos entre ellos. En este proyecto la clasificación usa un desempate simplificado: puntos, diferencia de goles y goles a favor.',
  N'Reglamento de la competición (resumen)'),
 ('reglamento', N'Duración de un partido',
  N'Un partido dura 90 minutos, divididos en dos partes de 45 minutos con un descanso que no supera los 15 minutos. El árbitro añade tiempo al final de cada parte para compensar las interrupciones.',
  N'Reglas de Juego (IFAB), regla 7'),
 ('reglamento', N'Fuera de juego',
  N'Un jugador está en posición de fuera de juego si, en el momento del pase, cualquier parte de su cabeza, cuerpo o pies que pueda marcar gol está más cerca de la línea de meta contraria que el balón y que el penúltimo adversario. Estar en posición de fuera de juego no es una infracción: solo se sanciona si el jugador participa en la jugada. No hay fuera de juego en un saque de banda, un saque de esquina ni un saque de puerta.',
  N'Reglas de Juego (IFAB), regla 11'),
 ('reglamento', N'Tarjetas amarillas y rojas',
  N'La tarjeta amarilla es una amonestación. Un jugador que recibe dos amarillas en el mismo partido es expulsado. La tarjeta roja directa expulsa al jugador sin amonestación previa, y el equipo continúa con un jugador menos.',
  N'Reglas de Juego (IFAB), regla 12'),
 ('reglamento', N'Penalti',
  N'Se concede penalti cuando un defensor comete, dentro de su propia área, una infracción que se sanciona con tiro libre directo. El penalti se lanza desde el punto de penalti, solo con el portero defendiendo la portería.',
  N'Reglas de Juego (IFAB), reglas 12 y 14'),
 ('reglamento', N'Gol en propia puerta',
  N'Un gol en propia puerta es el que un jugador marca en la portería de su propio equipo. Cuenta como gol a favor del equipo rival, pero no se le atribuye a ningún jugador del rival. En la base de datos del proyecto, el campo EquipoID de cada gol es el equipo beneficiado.',
  N'Reglas de Juego (IFAB), regla 10; criterio del proyecto'),
 ('reglamento', N'Árbitro asistente de vídeo (VAR)',
  N'El VAR ayuda al árbitro en cuatro tipos de decisiones: goles, penaltis, tarjetas rojas directas y errores de identidad del jugador sancionado. La decisión final la sigue tomando siempre el árbitro del campo.',
  N'Protocolo VAR (IFAB)'),
 ('reglamento', N'Sustituciones',
  N'Cada equipo puede hacer hasta 5 cambios por partido, repartidos en un máximo de 3 ventanas de sustitución. Además se permite un cambio extra cuando un jugador sufre una conmoción en la cabeza. Un jugador que ha sido sustituido no puede volver a jugar ese partido.',
  N'Reglas de Juego (IFAB), regla 3 (cifras aportadas por el alumno)'),
 ('faq', N'¿Cuántos partidos se juegan en una jornada?',
  N'Cada jornada tiene 10 partidos, porque participan 20 equipos y cada uno juega un partido por jornada.',
  N'Reglamento de la competición (resumen)'),
 ('faq', N'¿Qué significa que un partido esté Programado o Finalizado?',
  N'En la base de datos, un partido Programado todavía no se ha jugado y no tiene marcador. Un partido Finalizado ya se ha jugado y tiene su resultado y sus goles. La clasificación solo cuenta los partidos Finalizados.',
  N'Criterio del proyecto (liga.Partido.Estado)'),
 ('faq', N'¿Qué temporada y qué jornadas contiene la base de datos?',
  N'Contiene la temporada 2026-27 de LaLiga, de la jornada 1 a la 10. La jornada 10 está incompleta: algunos partidos ya tienen marcador y los demás siguen programados.',
  N'Criterio del proyecto'),
 ('faq', N'¿De dónde salen los datos de la liga?',
  N'Los partidos, resultados, goles y jugadores se tomaron de futbolfantasy.com, matchscan.co y Wikipedia, y se cargan desde los ficheros CSV de la carpeta data. Los textos de fichas, resúmenes y crónicas se generan automáticamente a partir de esos datos.',
  N'README del proyecto y docs/verificacion.md'),
 ('faq', N'¿Por qué el total de goles de los jugadores puede no coincidir con el de los partidos?',
  N'Los goles por jugador y los goles por partido proceden de dos fuentes distintas, que pueden diferir ligeramente en los partidos más recientes. Los goleadores del proyecto se calculan siempre desde el detalle de cada gol (tabla liga.Gol).',
  N'docs/verificacion.md'),
 ('faq', N'¿Los abonados y las entradas son reales?',
  N'No. Los abonados y las entradas son datos ficticios generados por un script con semilla fija, solo para practicar seguridad y optimización. No corresponden a personas ni a ventas reales.',
  N'README del proyecto');
GO

/* ---------- 2a. Fichas de equipo (generadas) ---------- */
INSERT INTO ia.Documento (Tipo, Titulo, Texto, EquipoID, Fuente)
SELECT 'ficha_equipo',
       CONCAT(N'Ficha de ', e.Nombre),
       CONCAT(e.Nombre, N' (', e.Ciudad, N'). Juega como local en ', es.Nombre,
              N', con capacidad para ', es.Capacidad, N' espectadores. ',
              N'Clasificación: puesto ', c.Posicion, N' con ', c.Pts, N' puntos tras ', c.PJ,
              N' partidos (', c.G, N' ganados, ', c.E, N' empatados y ', c.P, N' perdidos), ',
              c.GF, N' goles a favor y ', c.GC, N' en contra (diferencia de goles ', c.DG, N'). ',
              N'Plantilla con ', pl.Jugadores, N' jugadores registrados.',
              CASE WHEN g.Goleadores IS NOT NULL
                   THEN CONCAT(N' Máximos goleadores del equipo: ', g.Goleadores, N'.') ELSE N'' END),
       e.EquipoID,
       N'LigaDB (generado desde liga.vw_Clasificacion, liga.Jugador y liga.Gol)'
FROM liga.Equipo AS e
JOIN liga.Estadio AS es ON es.EquipoID = e.EquipoID
JOIN liga.vw_Clasificacion AS c ON c.EquipoID = e.EquipoID
CROSS APPLY (SELECT COUNT(*) AS Jugadores FROM liga.Jugador AS j WHERE j.EquipoID = e.EquipoID) AS pl
OUTER APPLY (SELECT STRING_AGG(CONCAT(t.Anotador, N' (', t.Goles, N')'), N', ')
                    WITHIN GROUP (ORDER BY t.Goles DESC, t.Anotador) AS Goleadores
             FROM (SELECT TOP (3) m.Anotador, m.Goles
                   FROM liga.vw_MaximosGoleadores AS m
                   WHERE m.Equipo = e.Nombre
                   ORDER BY m.Goles DESC, m.Anotador) AS t) AS g
ORDER BY e.EquipoID;
GO

/* ---------- 2b. Resúmenes de jornada (generados) ---------- */
INSERT INTO ia.Documento (Tipo, Titulo, Texto, Fuente)
SELECT 'resumen_jornada',
       CONCAT(N'Resumen de la jornada ', j.Numero),
       CONCAT(N'Jornada ', j.Numero, N' de LaLiga ', t.Nombre, N'. ',
              N'Partidos finalizados: ', r.Finalizados, N' de ', r.Total, N', con ', r.Goles, N' goles. ',
              CASE WHEN r.Resultados IS NOT NULL THEN CONCAT(N'Resultados: ', r.Resultados, N'. ') ELSE N'' END,
              CASE WHEN r.Pendientes IS NOT NULL THEN CONCAT(N'Pendientes de jugar: ', r.Pendientes, N'.') ELSE N'' END),
       N'LigaDB (generado desde liga.Partido)'
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
ORDER BY j.Numero;
GO

/* ---------- 2c. Crónicas de partido (generadas; solo partidos Finalizados) ---------- */
INSERT INTO ia.Documento (Tipo, Titulo, Texto, PartidoID, Fuente)
SELECT 'cronica_partido',
       CONCAT(l.Nombre, N' ', p.GolesLocal, N'-', p.GolesVisitante, N' ', v.Nombre, N' (jornada ', j.Numero, N')'),
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
                   ELSE N'' END),
       p.PartidoID,
       N'LigaDB (generado desde liga.Partido y liga.Gol)'
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
WHERE p.Estado = 'Finalizado'
ORDER BY p.PartidoID;
GO

PRINT N'--- Documentos por tipo ---';
SELECT Tipo, COUNT(*) AS Documentos, MIN(LEN(Texto)) AS LongMin, MAX(LEN(Texto)) AS LongMax
FROM ia.Documento GROUP BY Tipo ORDER BY Tipo;

PRINT N'--- Ejemplos de texto generado (primeros 330 caracteres) ---';
SELECT Tipo, CAST(Titulo AS NVARCHAR(45)) AS Titulo, CAST(LEFT(Texto, 330) AS NVARCHAR(330)) AS Texto
FROM ia.Documento
WHERE DocumentoID IN (
    (SELECT MIN(DocumentoID) FROM ia.Documento WHERE Tipo = 'ficha_equipo'),
    (SELECT MIN(DocumentoID) FROM ia.Documento WHERE Tipo = 'resumen_jornada'),
    (SELECT MAX(DocumentoID) FROM ia.Documento WHERE Tipo = 'resumen_jornada'),
    (SELECT MIN(DocumentoID) FROM ia.Documento WHERE Tipo = 'cronica_partido'))
ORDER BY DocumentoID;
GO

/* ---------- 3. Embeddings ---------- */
PRINT N'--- Calculando embeddings con bge_m3_ollama ---';
DECLARE @inicio DATETIME2 = SYSDATETIME();

UPDATE ia.Documento
SET Embedding       = AI_GENERATE_EMBEDDINGS(CONCAT(Titulo, N'. ', Texto) USE MODEL bge_m3_ollama),
    EmbeddingModelo = N'bge-m3',
    EmbeddingFecha  = SYSDATETIME()
WHERE Embedding IS NULL;

SELECT COUNT(*) AS DocumentosConEmbedding,
       DATEDIFF(MILLISECOND, @inicio, SYSDATETIME()) AS Milisegundos
FROM ia.Documento WHERE Embedding IS NOT NULL;

IF EXISTS (SELECT 1 FROM ia.Documento WHERE Embedding IS NULL)
    THROW 50101, N'Quedan documentos sin embedding.', 1;
GO

/* ---------- 4. Comprobación de la norma L2 ---------- */
PRINT N'--- Norma L2 de los vectores (VECTOR_NORM, norm2) ---';
SELECT COUNT(*)                                                  AS Vectores,
       CAST(MIN(VECTOR_NORM(Embedding, 'norm2')) AS DECIMAL(9,6)) AS NormaMin,
       CAST(AVG(VECTOR_NORM(Embedding, 'norm2')) AS DECIMAL(9,6)) AS NormaMedia,
       CAST(MAX(VECTOR_NORM(Embedding, 'norm2')) AS DECIMAL(9,6)) AS NormaMax,
       CAST(MIN(VECTORPROPERTY(Embedding, 'Dimensions')) AS INT)  AS Dimensiones
FROM ia.Documento;

SELECT Tipo,
       CAST(MIN(VECTOR_NORM(Embedding, 'norm2')) AS DECIMAL(9,6)) AS NormaMin,
       CAST(MAX(VECTOR_NORM(Embedding, 'norm2')) AS DECIMAL(9,6)) AS NormaMax
FROM ia.Documento GROUP BY Tipo ORDER BY Tipo;
GO

/* ---------- 5. Si ya existe el índice Full-Text (Bloque F), esperar a que esté al día ----------
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
