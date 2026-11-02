/* =============================================================================
   externo/cargar_externo.sql
   Goalmetry - Contrasta y carga en externo.* lo que dejó normalizado importar_externo.ps1.
   NUNCA escribe en liga.*. Reglas:
     - Equipo sin alias, marcador distinto del de liga.Partido o jornada distinta: NO se usa y queda
       en externo.PendienteRevision para revisarlo a mano.
     - Las estadísticas solo se guardan de partidos que ya están en liga.Partido con el mismo marcador.
     - Si una fuente viene vacía (sin Internet), se conserva lo importado la última vez.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

DELETE FROM externo.PendienteRevision;
GO

/* ---------- football-data: estadísticas y cuotas de partidos ya jugados ---------- */
DECLARE @j NVARCHAR(MAX);
SELECT @j = BulkColumn FROM OPENROWSET(BULK N'$(RutaExterno)\norm_resultados.json', SINGLE_NCLOB) AS x;

SELECT r.*, al.EquipoID AS L, av.EquipoID AS V
INTO #R
FROM OPENJSON(@j) WITH (Fecha DATE, Hora VARCHAR(5), Local NVARCHAR(60), Visitante NVARCHAR(60), GL TINYINT, GV TINYINT, TL TINYINT, TV TINYINT,
                        APL TINYINT, APV TINYINT, CL TINYINT, CV TINYINT, AL TINYINT, AV TINYINT, RL TINYINT, RV TINYINT,
                        XgL DECIMAL(4,2), XgV DECIMAL(4,2), C1 DECIMAL(6,2), CX DECIMAL(6,2), C2 DECIMAL(6,2)) AS r
LEFT JOIN externo.Alias AS al ON al.Fuente = 'football-data' AND al.NombreExterno = r.Local COLLATE DATABASE_DEFAULT
LEFT JOIN externo.Alias AS av ON av.Fuente = 'football-data' AND av.NombreExterno = r.Visitante COLLATE DATABASE_DEFAULT;

INSERT externo.PendienteRevision (Motivo, Detalle, Fuente)
SELECT N'Equipo sin alias', CONCAT(Local, N' - ', Visitante, N' (', Fecha, N')'), 'football-data' FROM #R WHERE L IS NULL OR V IS NULL;

INSERT externo.PendienteRevision (Motivo, Detalle, Fuente)
SELECT N'Marcador distinto', CONCAT(r.Local, N' - ', r.Visitante, N': fuente ', r.GL, N'-', r.GV, N', base de datos ', p.GolesLocal, N'-', p.GolesVisitante), 'football-data'
FROM #R AS r JOIN liga.Partido AS p ON p.EquipoLocalID = r.L AND p.EquipoVisitanteID = r.V AND p.Estado = 'Finalizado'
WHERE r.GL <> p.GolesLocal OR r.GV <> p.GolesVisitante;

-- Partidos de la base de datos que esta fuente no trae: quedan sin estadísticas y se dice.
IF EXISTS (SELECT 1 FROM #R)
    INSERT externo.PendienteRevision (Motivo, Detalle, Fuente)
    SELECT N'Partido que la fuente no trae', CONCAT(N'J', j.Numero, N' ', l.Nombre, N' - ', v.Nombre, N' (', p.GolesLocal, N'-', p.GolesVisitante, N')'), 'football-data'
    FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
    JOIN liga.Equipo AS l ON l.EquipoID = p.EquipoLocalID JOIN liga.Equipo AS v ON v.EquipoID = p.EquipoVisitanteID
    WHERE p.Estado = 'Finalizado' AND NOT EXISTS (SELECT 1 FROM #R AS r WHERE r.L = p.EquipoLocalID AND r.V = p.EquipoVisitanteID);

IF EXISTS (SELECT 1 FROM #R)
BEGIN
    DELETE FROM externo.PartidoExtra;
    DELETE FROM externo.Cuota;
    INSERT externo.PartidoExtra (LocalID, VisitanteID, Fecha, GolesLocal, GolesVisitante, TirosL, TirosV, APuertaL, APuertaV, CornersL, CornersV,
                                 AmarillasL, AmarillasV, RojasL, RojasV, XgL, XgV, Fuente)
    SELECT r.L, r.V, r.Fecha, r.GL, r.GV, r.TL, r.TV, r.APL, r.APV, r.CL, r.CV, r.AL, r.AV, r.RL, r.RV, r.XgL, r.XgV, 'football-data.co.uk'
    FROM #R AS r JOIN liga.Partido AS p ON p.EquipoLocalID = r.L AND p.EquipoVisitanteID = r.V AND p.Estado = 'Finalizado'
    WHERE r.GL = p.GolesLocal AND r.GV = p.GolesVisitante;

    INSERT externo.Cuota (LocalID, VisitanteID, CuotaLocal, CuotaEmpate, CuotaVisitante, Fuente)
    SELECT r.L, r.V, r.C1, r.CX, r.C2, 'football-data.co.uk (media de casas)'
    FROM #R AS r JOIN liga.Partido AS p ON p.EquipoLocalID = r.L AND p.EquipoVisitanteID = r.V AND p.Estado = 'Finalizado'
    WHERE r.GL = p.GolesLocal AND r.GV = p.GolesVisitante AND r.C1 > 1 AND r.CX > 1 AND r.C2 > 1;
END;

/* ---------- football-data: próximos partidos, para contrastar el calendario ---------- */
SELECT @j = BulkColumn FROM OPENROWSET(BULK N'$(RutaExterno)\norm_proximos.json', SINGLE_NCLOB) AS x;
SELECT r.Fecha, r.Hora, al.EquipoID AS L, av.EquipoID AS V
INTO #P
FROM OPENJSON(@j) WITH (Fecha DATE, Hora VARCHAR(5), Local NVARCHAR(60), Visitante NVARCHAR(60)) AS r
JOIN externo.Alias AS al ON al.Fuente = 'football-data' AND al.NombreExterno = r.Local COLLATE DATABASE_DEFAULT
JOIN externo.Alias AS av ON av.Fuente = 'football-data' AND av.NombreExterno = r.Visitante COLLATE DATABASE_DEFAULT
UNION
SELECT Fecha, Hora, L, V FROM #R WHERE L IS NOT NULL AND V IS NOT NULL;

/* ---------- openfootball: calendario 2026-27 ---------- */
SELECT @j = BulkColumn FROM OPENROWSET(BULK N'$(RutaExterno)\norm_calendario.json', SINGLE_NCLOB) AS x;
SELECT r.*, al.EquipoID AS L, av.EquipoID AS V
INTO #C
FROM OPENJSON(@j) WITH (Jornada TINYINT, Fecha DATE, Hora VARCHAR(5), Local NVARCHAR(60), Visitante NVARCHAR(60), GL TINYINT, GV TINYINT) AS r
LEFT JOIN externo.Alias AS al ON al.Fuente = 'openfootball' AND al.NombreExterno = r.Local COLLATE DATABASE_DEFAULT
LEFT JOIN externo.Alias AS av ON av.Fuente = 'openfootball' AND av.NombreExterno = r.Visitante COLLATE DATABASE_DEFAULT;

INSERT externo.PendienteRevision (Motivo, Detalle, Fuente)
SELECT N'Equipo sin alias', CONCAT(Local, N' - ', Visitante), 'openfootball' FROM #C WHERE L IS NULL OR V IS NULL;

INSERT externo.PendienteRevision (Motivo, Detalle, Fuente)
SELECT N'Marcador distinto', CONCAT(c.Local, N' - ', c.Visitante, N': fuente ', c.GL, N'-', c.GV, N', base de datos ', p.GolesLocal, N'-', p.GolesVisitante), 'openfootball'
FROM #C AS c JOIN liga.Partido AS p ON p.EquipoLocalID = c.L AND p.EquipoVisitanteID = c.V AND p.Estado = 'Finalizado'
WHERE c.GL IS NOT NULL AND (c.GL <> p.GolesLocal OR c.GV <> p.GolesVisitante);

INSERT externo.PendienteRevision (Motivo, Detalle, Fuente)
SELECT N'Jornada distinta', CONCAT(c.Local, N' - ', c.Visitante, N': fuente J', c.Jornada, N', base de datos J', j.Numero), 'openfootball'
FROM #C AS c JOIN liga.Partido AS p ON p.EquipoLocalID = c.L AND p.EquipoVisitanteID = c.V
JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
WHERE c.Jornada <> j.Numero;

IF EXISTS (SELECT 1 FROM #C)
BEGIN
    DELETE FROM externo.PartidoFuturo;
    -- Con football-data, la fecha está contrastada; sin ella, la de openfootball es solo orientativa
    -- (a menudo pone la misma fecha a toda la jornada).
    INSERT externo.PartidoFuturo (Jornada, Fecha, Hora, LocalID, VisitanteID, Contrastado, Fuente)
    SELECT c.Jornada, COALESCE(x.Fecha, c.Fecha), COALESCE(x.Hora, c.Hora), c.L, c.V,
           CASE WHEN x.L IS NULL THEN 0 ELSE 1 END,
           CASE WHEN x.L IS NULL THEN 'openfootball' ELSE 'openfootball y football-data.co.uk' END
    FROM #C AS c
    OUTER APPLY (SELECT TOP (1) p.Fecha, p.Hora, p.L FROM #P AS p WHERE p.L = c.L AND p.V = c.V ORDER BY p.Fecha) AS x
    WHERE c.L IS NOT NULL AND c.V IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM liga.Partido AS p WHERE p.EquipoLocalID = c.L AND p.EquipoVisitanteID = c.V AND p.Estado = 'Finalizado');
END;

/* ---------- openfootball: temporadas anteriores, para el punto de partida del Elo ---------- */
SELECT @j = BulkColumn FROM OPENROWSET(BULK N'$(RutaExterno)\norm_historico.json', SINGLE_NCLOB) AS x;
SELECT ROW_NUMBER() OVER (PARTITION BY r.Temporada ORDER BY r.Fecha, r.Jornada, r.Local) AS Orden, r.*
INTO #H
FROM OPENJSON(@j) WITH (Temporada CHAR(7), Jornada TINYINT, Fecha DATE, Local NVARCHAR(60), Visitante NVARCHAR(60), GL TINYINT, GV TINYINT) AS r
WHERE r.GL IS NOT NULL AND r.GV IS NOT NULL;

DELETE FROM externo.PartidoHistorico WHERE Temporada IN (SELECT Temporada COLLATE DATABASE_DEFAULT FROM #H);
INSERT externo.PartidoHistorico (Temporada, Orden, Fecha, LocalID, VisitanteID, LocalNombre, VisitanteNombre, GolesLocal, GolesVisitante, Fuente)
SELECT h.Temporada, h.Orden, h.Fecha, al.EquipoID, av.EquipoID, h.Local, h.Visitante, h.GL, h.GV, 'openfootball'
FROM #H AS h
LEFT JOIN externo.Alias AS al ON al.Fuente = 'openfootball' AND al.NombreExterno = h.Local COLLATE DATABASE_DEFAULT
LEFT JOIN externo.Alias AS av ON av.Fuente = 'openfootball' AND av.NombreExterno = h.Visitante COLLATE DATABASE_DEFAULT;
GO

SELECT N'Partidos con estadísticas' AS Dato, COUNT(*) AS N FROM externo.PartidoExtra
UNION ALL SELECT N'Partidos con cuotas', COUNT(*) FROM externo.Cuota
UNION ALL SELECT N'Calendario pendiente', COUNT(*) FROM externo.PartidoFuturo
UNION ALL SELECT N'Calendario contrastado con dos fuentes', COUNT(*) FROM externo.PartidoFuturo WHERE Contrastado = 1
UNION ALL SELECT N'Temporadas anteriores (partidos)', COUNT(*) FROM externo.PartidoHistorico
UNION ALL SELECT N'Pendiente de revisión manual', COUNT(*) FROM externo.PendienteRevision;
SELECT Motivo, Fuente, CAST(Detalle AS NVARCHAR(100)) AS Detalle FROM externo.PendienteRevision ORDER BY Motivo, PendienteID;
GO
