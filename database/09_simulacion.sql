/* =============================================================================
   09_simulacion.sql
   Goalmetry - Predicciones: simula las jornadas que faltan miles de veces.
   Todo vive en el esquema simulacion: ESTIMACIONES, nunca resultados. No escribe en
   liga, ventas ni ia, y no usa los CSV.
   Este script solo crea los objetos; el cálculo se lanza aparte (desde la web, con
   actualizar.ps1 o con EXEC simulacion.usp_ActualizarPredicciones).
   Modelo:
     - Goles de cada partido: Poisson. Goles esperados del local = media de goles de los
       locales x ataque del local x defensa del visitante (y al revés para el visitante).
     - Ataque y defensa con encogimiento hacia la media (@K partidos imaginarios "normales"):
       con pocos partidos no se puede creer el dato en bruto.
     - En cada temporada simulada, cada equipo recibe un ruido (@Sigma) en su fuerza: no
       sabemos cuánto vale de verdad y así el modelo no se cree demasiado seguro.
     - Azar: SHA-256 de semilla + temporada + partido. Misma semilla, mismo resultado.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\09_simulacion.sql
   Idempotente: no borra resultados ya calculados.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

IF SCHEMA_ID(N'simulacion') IS NULL EXEC (N'CREATE SCHEMA simulacion AUTHORIZATION dbo;');
GO

/* ---------- 1. Tablas (sin FK a liga: 02_create_tables.sql tiene que poder recrearlas) ---------- */
IF OBJECT_ID(N'simulacion.Ejecucion', N'U') IS NULL
CREATE TABLE simulacion.Ejecucion
(
    EjecucionID  INT IDENTITY(1,1) NOT NULL,
    Tipo         VARCHAR(12)  NOT NULL,   -- Principal | Historia | Validacion
    HastaJornada TINYINT      NOT NULL,   -- datos usados: los partidos jugados hasta esta jornada
    Temporadas   INT          NOT NULL,
    Hechas       INT          NOT NULL CONSTRAINT DF_Ejecucion_Hechas DEFAULT (0),
    Semilla      INT          NOT NULL,
    K            FLOAT        NOT NULL,
    Sigma        FLOAT        NOT NULL,
    Estado       VARCHAR(12)  NOT NULL CONSTRAINT DF_Ejecucion_Estado DEFAULT ('En curso'),
    HuellaDatos  INT          NULL,       -- para saber si los resultados han cambiado después
    Inicio       DATETIME2(0) NOT NULL CONSTRAINT DF_Ejecucion_Inicio DEFAULT (SYSDATETIME()),
    Fin          DATETIME2(0) NULL,
    CONSTRAINT PK_Ejecucion PRIMARY KEY (EjecucionID),
    CONSTRAINT CK_Ejecucion_Tipo CHECK (Tipo IN ('Principal', 'Historia', 'Validacion')),
    CONSTRAINT CK_Ejecucion_Estado CHECK (Estado IN ('En curso', 'Terminada', 'Error'))
);

-- Cuántas temporadas acabó cada equipo en cada puesto, y sus puntos acumulados.
IF OBJECT_ID(N'simulacion.Probabilidad', N'U') IS NULL
CREATE TABLE simulacion.Probabilidad
(
    EjecucionID INT     NOT NULL,
    EquipoID    INT     NOT NULL,
    Puesto      TINYINT NOT NULL,
    Veces       INT     NOT NULL,
    SumaPuntos  BIGINT  NOT NULL,
    CONSTRAINT PK_Probabilidad PRIMARY KEY (EjecucionID, EquipoID, Puesto)
);

-- Detalle de la última ejecución Principal, para el «¿y si...?». Columnstore: millones de filas pequeñas.
IF OBJECT_ID(N'simulacion.PartidoSimulado', N'U') IS NULL
CREATE TABLE simulacion.PartidoSimulado
(
    Sim INT NOT NULL, LocalID TINYINT NOT NULL, VisitanteID TINYINT NOT NULL,
    Signo CHAR(1) NOT NULL,   -- 1, X o 2
    INDEX CCI_PartidoSimulado CLUSTERED COLUMNSTORE
);
IF OBJECT_ID(N'simulacion.PuestoSimulado', N'U') IS NULL
CREATE TABLE simulacion.PuestoSimulado
(
    Sim INT NOT NULL, EquipoID TINYINT NOT NULL, Puesto TINYINT NOT NULL, Puntos SMALLINT NOT NULL,
    INDEX CCI_PuestoSimulado CLUSTERED COLUMNSTORE
);

-- Prueba contra la realidad: puntos previstos (percentiles) frente a los reales.
IF OBJECT_ID(N'simulacion.Validacion', N'U') IS NULL
CREATE TABLE simulacion.Validacion
(
    EjecucionID INT NOT NULL, EquipoID INT NOT NULL,
    P10 FLOAT NOT NULL, P50 FLOAT NOT NULL, P90 FLOAT NOT NULL, PuntosReales INT NOT NULL,
    CONSTRAINT PK_Validacion PRIMARY KEY (EjecucionID, EquipoID)
);

-- Tabla de Poisson: goles para cada media (LamIdx x 0,05) y cada cubo de azar (B, de 0 a 999).
IF OBJECT_ID(N'simulacion.Poisson', N'U') IS NULL
CREATE TABLE simulacion.Poisson
(
    LamIdx SMALLINT NOT NULL, B SMALLINT NOT NULL, Goles TINYINT NOT NULL,
    CONSTRAINT PK_Poisson PRIMARY KEY (LamIdx, B)
);
GO

IF NOT EXISTS (SELECT 1 FROM simulacion.Poisson)
BEGIN
    WITH Pmf AS
    (
        SELECT l.value AS LamIdx, k.value AS Goles,
               EXP(-(l.value * 0.05) + k.value * LOG(l.value * 0.05)
                   - COALESCE((SELECT SUM(LOG(CAST(s.value AS FLOAT))) FROM GENERATE_SERIES(1, k.value) AS s WHERE k.value > 0), 0)) AS P
        FROM GENERATE_SERIES(1, 160) AS l CROSS JOIN GENERATE_SERIES(0, 25) AS k
    ),
    Cdf AS
    (
        SELECT LamIdx, Goles, SUM(P) OVER (PARTITION BY LamIdx ORDER BY Goles ROWS UNBOUNDED PRECEDING) AS Hi FROM Pmf
    ),
    Rango AS
    (
        SELECT LamIdx, Goles, COALESCE(LAG(Hi) OVER (PARTITION BY LamIdx ORDER BY Goles), 0) AS Lo,
               CASE WHEN Goles = 25 THEN 2.0 ELSE Hi END AS Hi
        FROM Cdf
    )
    INSERT INTO simulacion.Poisson (LamIdx, B, Goles)
    SELECT r.LamIdx, b.value, r.Goles
    FROM Rango AS r
    JOIN GENERATE_SERIES(0, 999) AS b ON (b.value + 0.5) / 1000.0 >= r.Lo AND (b.value + 0.5) / 1000.0 < r.Hi;
END;
GO

/* ---------- 2. Una simulación ----------
   @HastaJornada: con qué datos se calcula (NULL: la última jornada con partidos jugados).
   @EvaluarHasta: solo para la prueba contra la realidad: en vez de los partidos que faltan,
                  simula los ya jugados de las jornadas siguientes hasta esta.
   EXECUTE AS OWNER: la web solo necesita permiso para ejecutar, no para escribir en las tablas. */
CREATE OR ALTER PROCEDURE simulacion.usp_Simular
    @HastaJornada TINYINT = NULL,
    @Temporadas   INT     = 10000,
    @Semilla      INT     = NULL,
    @K            FLOAT   = 5,
    @Sigma        FLOAT   = 0.30,   -- K y Sigma elegidos con tests\simulacion_validacion.sql
    @Tipo         VARCHAR(12) = 'Principal',
    @EvaluarHasta TINYINT = NULL,
    @EjecucionID  INT     = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Temporadas NOT BETWEEN 1 AND 100000
        THROW 50702, N'El número de temporadas debe estar entre 1 y 100.000.', 1;
    IF @Tipo NOT IN ('Principal', 'Historia', 'Validacion')
        THROW 50703, N'Tipo de ejecución no válido.', 1;

    SET @HastaJornada = COALESCE(@HastaJornada,
        (SELECT MAX(j.Numero) FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID WHERE p.Estado = 'Finalizado'));
    IF @HastaJornada IS NULL
        THROW 50704, N'No hay partidos jugados con los que calcular.', 1;
    SET @Semilla = COALESCE(@Semilla, ABS(CHECKSUM(NEWID())) % 2000000000);

    INSERT INTO simulacion.Ejecucion (Tipo, HastaJornada, Temporadas, Semilla, K, Sigma, HuellaDatos)
    SELECT @Tipo, @HastaJornada, @Temporadas, @Semilla, @K, @Sigma,
           (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(PartidoID, GolesLocal, GolesVisitante, Estado)) FROM liga.Partido);
    SET @EjecucionID = SCOPE_IDENTITY();

    IF @Tipo = 'Principal'
    BEGIN
        TRUNCATE TABLE simulacion.PartidoSimulado;
        TRUNCATE TABLE simulacion.PuestoSimulado;
    END;

    BEGIN TRY
        /* Partidos conocidos en este corte */
        SELECT p.EquipoLocalID AS L, p.EquipoVisitanteID AS V, p.GolesLocal AS GL, p.GolesVisitante AS GV
        INTO #Jugado
        FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        WHERE p.Estado = 'Finalizado' AND j.Numero <= @HastaJornada;

        DECLARE @mL FLOAT, @mV FLOAT;
        SELECT @mL = AVG(GL * 1.0), @mV = AVG(GV * 1.0) FROM #Jugado;
        DECLARE @m FLOAT = (@mL + @mV) / 2;

        /* Fuerza de cada equipo, encogida hacia la media */
        SELECT e.EquipoID, COALESCE(t.PJ, 0) AS PJ, COALESCE(t.GF, 0) AS GF, COALESCE(t.GC, 0) AS GC, COALESCE(t.Pts, 0) AS Pts,
               ((COALESCE(t.GF, 0) + @K * @m) / (COALESCE(t.PJ, 0) + @K)) / @m AS Ataque,
               ((COALESCE(t.GC, 0) + @K * @m) / (COALESCE(t.PJ, 0) + @K)) / @m AS Defensa
        INTO #Eq
        FROM liga.Equipo AS e
        LEFT JOIN (SELECT EquipoID, COUNT(*) AS PJ, SUM(GF) AS GF, SUM(GC) AS GC,
                          SUM(CASE WHEN GF > GC THEN 3 WHEN GF = GC THEN 1 ELSE 0 END) AS Pts
                   FROM (SELECT L AS EquipoID, CAST(GL AS INT) AS GF, CAST(GV AS INT) AS GC FROM #Jugado
                         UNION ALL SELECT V, GV, GL FROM #Jugado) AS x
                   GROUP BY EquipoID) AS t ON t.EquipoID = e.EquipoID;

        /* Partidos que se simulan */
        CREATE TABLE #Pend (L INT NOT NULL, V INT NOT NULL);
        IF @EvaluarHasta IS NULL
            INSERT #Pend SELECT a.EquipoID, b.EquipoID
            FROM liga.Equipo AS a CROSS JOIN liga.Equipo AS b
            WHERE a.EquipoID <> b.EquipoID
              AND NOT EXISTS (SELECT 1 FROM #Jugado AS j WHERE j.L = a.EquipoID AND j.V = b.EquipoID);
        ELSE
            INSERT #Pend SELECT p.EquipoLocalID, p.EquipoVisitanteID
            FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
            WHERE p.Estado = 'Finalizado' AND j.Numero > @HastaJornada AND j.Numero <= @EvaluarHasta;

        CREATE TABLE #Pts (Sim INT NOT NULL, EquipoID INT NOT NULL, Puntos INT NOT NULL);
        DECLARE @ini INT = 1, @fin INT, @lote INT = 500;

        WHILE @ini <= @Temporadas
        BEGIN
            SET @fin = LEAST(@ini + @lote - 1, @Temporadas);

            /* Ruido de la fuerza de cada equipo en cada temporada (normal: Box-Muller) */
            SELECT s.value AS Sim, e.EquipoID,
                   EXP(@Sigma * SQRT(-2 * LOG(u.U1)) * COS(2 * PI() * u.U2) - @Sigma * @Sigma / 2) AS FA,
                   EXP(@Sigma * SQRT(-2 * LOG(u.U3)) * COS(2 * PI() * u.U4) - @Sigma * @Sigma / 2) AS FD
            INTO #Ruido
            FROM GENERATE_SERIES(@ini, @fin) AS s
            CROSS JOIN #Eq AS e
            CROSS APPLY (SELECT HASHBYTES('SHA2_256', CONCAT(@Semilla, N'|e|', s.value, N'|', e.EquipoID)) AS H) AS h
            CROSS APPLY (SELECT (CONVERT(BIGINT, SUBSTRING(h.H, 1, 6)) + 0.5) / 281474976710656.0 AS U1,
                                (CONVERT(BIGINT, SUBSTRING(h.H, 7, 6)) + 0.5) / 281474976710656.0 AS U2,
                                (CONVERT(BIGINT, SUBSTRING(h.H, 13, 6)) + 0.5) / 281474976710656.0 AS U3,
                                (CONVERT(BIGINT, SUBSTRING(h.H, 19, 6)) + 0.5) / 281474976710656.0 AS U4) AS u;

            /* Los partidos */
            SELECT r.Sim, r.L, r.V, pl.Goles AS GL, pv.Goles AS GV
            INTO #P
            FROM (SELECT rl.Sim, f.L, f.V,
                         @mL * el.Ataque * rl.FA * ev.Defensa * rv.FD AS LamL,
                         @mV * ev.Ataque * rv.FA * el.Defensa * rl.FD AS LamV,
                         HASHBYTES('SHA2_256', CONCAT(@Semilla, N'|p|', rl.Sim, N'|', f.L, N'|', f.V)) AS H
                  FROM #Pend AS f
                  JOIN #Eq AS el ON el.EquipoID = f.L
                  JOIN #Eq AS ev ON ev.EquipoID = f.V
                  JOIN #Ruido AS rl ON rl.EquipoID = f.L
                  JOIN #Ruido AS rv ON rv.EquipoID = f.V AND rv.Sim = rl.Sim) AS r
            JOIN simulacion.Poisson AS pl
              ON pl.LamIdx = LEAST(160, GREATEST(1, CONVERT(INT, ROUND(r.LamL / 0.05, 0))))
             AND pl.B = CONVERT(BIGINT, SUBSTRING(r.H, 1, 6)) % 1000
            JOIN simulacion.Poisson AS pv
              ON pv.LamIdx = LEAST(160, GREATEST(1, CONVERT(INT, ROUND(r.LamV / 0.05, 0))))
             AND pv.B = CONVERT(BIGINT, SUBSTRING(r.H, 7, 6)) % 1000;

            /* Clasificación final de cada temporada: mismos criterios que liga.vw_Clasificacion
               y, si aún empatan, sorteo (no por EquipoID, que favorecería a unos equipos). */
            SELECT t.Sim, t.EquipoID, e.Pts + t.P AS Puntos,
                   ROW_NUMBER() OVER (PARTITION BY t.Sim
                                      ORDER BY e.Pts + t.P DESC, e.GF - e.GC + t.G - t.C DESC, e.GF + t.G DESC,
                                               HASHBYTES('SHA2_256', CONCAT(@Semilla, N'|d|', t.Sim, N'|', t.EquipoID))) AS Puesto
            INTO #T
            FROM (SELECT Sim, EquipoID, SUM(P) AS P, SUM(G) AS G, SUM(C) AS C
                  FROM (SELECT Sim, L AS EquipoID, CAST(GL AS INT) AS G, CAST(GV AS INT) AS C,
                               CASE WHEN GL > GV THEN 3 WHEN GL = GV THEN 1 ELSE 0 END AS P FROM #P
                        UNION ALL
                        SELECT Sim, V, GV, GL, CASE WHEN GV > GL THEN 3 WHEN GV = GL THEN 1 ELSE 0 END FROM #P) AS x
                  GROUP BY Sim, EquipoID) AS t
            JOIN #Eq AS e ON e.EquipoID = t.EquipoID;

            /* Guardar: cada lote se confirma por separado, así la web puede enseñar el progreso. */
            MERGE simulacion.Probabilidad AS d
            USING (SELECT @EjecucionID AS EjecucionID, EquipoID, Puesto, COUNT(*) AS Veces, SUM(CAST(Puntos AS BIGINT)) AS SumaPuntos
                   FROM #T GROUP BY EquipoID, Puesto) AS o
               ON d.EjecucionID = o.EjecucionID AND d.EquipoID = o.EquipoID AND d.Puesto = o.Puesto
            WHEN MATCHED THEN UPDATE SET Veces = d.Veces + o.Veces, SumaPuntos = d.SumaPuntos + o.SumaPuntos
            WHEN NOT MATCHED THEN INSERT (EjecucionID, EquipoID, Puesto, Veces, SumaPuntos)
                                  VALUES (o.EjecucionID, o.EquipoID, o.Puesto, o.Veces, o.SumaPuntos);

            IF @Tipo = 'Principal'
            BEGIN
                INSERT INTO simulacion.PartidoSimulado (Sim, LocalID, VisitanteID, Signo)
                SELECT Sim, L, V, CASE WHEN GL > GV THEN '1' WHEN GL = GV THEN 'X' ELSE '2' END FROM #P;
                INSERT INTO simulacion.PuestoSimulado (Sim, EquipoID, Puesto, Puntos)
                SELECT Sim, EquipoID, Puesto, Puntos FROM #T;
            END;
            IF @Tipo = 'Validacion'
                INSERT #Pts SELECT Sim, EquipoID, Puntos FROM #T;

            UPDATE simulacion.Ejecucion SET Hechas = @fin WHERE EjecucionID = @EjecucionID;
            DROP TABLE #Ruido, #P, #T;
            SET @ini = @fin + 1;
        END;

        IF @Tipo = 'Validacion'
            INSERT INTO simulacion.Validacion (EjecucionID, EquipoID, P10, P50, P90, PuntosReales)
            SELECT @EjecucionID, d.EquipoID, d.P10, d.P50, d.P90,
                   (SELECT COALESCE(SUM(CASE WHEN x.GF > x.GC THEN 3 WHEN x.GF = x.GC THEN 1 ELSE 0 END), 0)
                    FROM (SELECT p.GolesLocal AS GF, p.GolesVisitante AS GC
                          FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
                          WHERE p.Estado = 'Finalizado' AND j.Numero <= @EvaluarHasta AND p.EquipoLocalID = d.EquipoID
                          UNION ALL
                          SELECT p.GolesVisitante, p.GolesLocal
                          FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
                          WHERE p.Estado = 'Finalizado' AND j.Numero <= @EvaluarHasta AND p.EquipoVisitanteID = d.EquipoID) AS x)
            FROM (SELECT DISTINCT EquipoID,
                         PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY Puntos) OVER (PARTITION BY EquipoID) AS P10,
                         PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY Puntos) OVER (PARTITION BY EquipoID) AS P50,
                         PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY Puntos) OVER (PARTITION BY EquipoID) AS P90
                  FROM #Pts) AS d;

        UPDATE simulacion.Ejecucion SET Estado = 'Terminada', Fin = SYSDATETIME() WHERE EjecucionID = @EjecucionID;

        -- Solo interesa la última de cada corte: las anteriores no se acumulan.
        IF @Tipo <> 'Validacion'
        BEGIN
            DELETE p FROM simulacion.Probabilidad AS p
            JOIN simulacion.Ejecucion AS e ON e.EjecucionID = p.EjecucionID
            WHERE e.HastaJornada = @HastaJornada AND e.Tipo <> 'Validacion' AND e.EjecucionID <> @EjecucionID;
            DELETE FROM simulacion.Ejecucion
            WHERE HastaJornada = @HastaJornada AND Tipo <> 'Validacion' AND EjecucionID <> @EjecucionID;
        END;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        UPDATE simulacion.Ejecucion SET Estado = 'Error', Fin = SYSDATETIME() WHERE EjecucionID = @EjecucionID;
        THROW;
    END CATCH;
END;
GO

/* ---------- 3. Poner al día: la simulación principal y los cortes de la evolución que falten ----------
   Un cerrojo evita dos cálculos a la vez. Es de sesión: si el proceso muere, se libera solo. */
CREATE OR ALTER PROCEDURE simulacion.usp_ActualizarPredicciones
    @Temporadas         INT = 10000,
    @TemporadasHistoria INT = 1000,
    @Semilla            INT = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r INT;
    EXEC @r = sys.sp_getapplock @Resource = N'simulacion', @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0;
    IF @r < 0
        THROW 50701, N'Ya hay una simulación en marcha. Espera a que termine.', 1;

    BEGIN TRY
        -- Con el cerrojo en la mano, lo que siga «En curso» es de un proceso que murió.
        UPDATE simulacion.Ejecucion SET Estado = 'Error', Fin = SYSDATETIME() WHERE Estado = 'En curso';

        EXEC simulacion.usp_Simular @Temporadas = @Temporadas, @Semilla = @Semilla, @Tipo = 'Principal';

        DECLARE @ultima TINYINT = (SELECT MAX(j.Numero) FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID WHERE p.Estado = 'Finalizado');
        DECLARE @c TINYINT = 1;
        WHILE @c < @ultima
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM simulacion.Ejecucion
                           WHERE Estado = 'Terminada' AND HastaJornada = @c AND Tipo IN ('Principal', 'Historia'))
                EXEC simulacion.usp_Simular @HastaJornada = @c, @Temporadas = @TemporadasHistoria, @Semilla = @Semilla, @Tipo = 'Historia';
            SET @c += 1;
        END;
    END TRY
    BEGIN CATCH
        EXEC sys.sp_releaseapplock @Resource = N'simulacion', @LockOwner = 'Session';
        THROW;
    END CATCH;
    EXEC sys.sp_releaseapplock @Resource = N'simulacion', @LockOwner = 'Session';
END;
GO

/* ---------- 4. «¿Y si...?» ----------
   No vuelve a simular: se queda con las temporadas ya simuladas en las que ocurren esos
   resultados y recuenta. Vale porque en el modelo los partidos son independientes.
   @Condiciones: JSON, p. ej. [{"L":19,"V":16,"S":"1"}], con S = 1, X o 2. */
CREATE OR ALTER PROCEDURE simulacion.usp_YSi
    @Condiciones NVARCHAR(400)
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@Condiciones) <> 1
        THROW 50705, N'Condiciones no válidas.', 1;

    DECLARE @C TABLE (L TINYINT, V TINYINT, S CHAR(1));
    INSERT @C SELECT L, V, S FROM OPENJSON(@Condiciones) WITH (L TINYINT '$.L', V TINYINT '$.V', S CHAR(1) '$.S');
    DECLARE @n INT = (SELECT COUNT(*) FROM @C);
    IF @n NOT BETWEEN 1 AND 3 OR EXISTS (SELECT 1 FROM @C WHERE L IS NULL OR V IS NULL OR S IS NULL OR S NOT IN ('1', 'X', '2'))
        THROW 50706, N'Elige entre uno y tres resultados.', 1;
    IF (SELECT COUNT(*) FROM (SELECT DISTINCT L, V FROM @C) AS d) <> @n
        THROW 50707, N'Ese partido ya tiene un resultado elegido.', 1;
    IF EXISTS (SELECT 1 FROM @C AS c WHERE NOT EXISTS (SELECT 1 FROM simulacion.PartidoSimulado AS p WHERE p.LocalID = c.L AND p.VisitanteID = c.V AND p.Sim = 1))
        THROW 50708, N'Ese partido no está entre los que faltan por jugar.', 1;

    SELECT p.Sim INTO #Sims
    FROM simulacion.PartidoSimulado AS p JOIN @C AS c ON c.L = p.LocalID AND c.V = p.VisitanteID AND c.S = p.Signo
    GROUP BY p.Sim HAVING COUNT(*) = @n;

    SELECT COUNT(*) AS Temporadas FROM #Sims;
    SELECT q.EquipoID, q.Puesto, COUNT(*) AS Veces, SUM(CAST(q.Puntos AS BIGINT)) AS SumaPuntos
    FROM simulacion.PuestoSimulado AS q JOIN #Sims AS s ON s.Sim = q.Sim
    GROUP BY q.EquipoID, q.Puesto;
END;
GO

/* ---------- 5. Curiosidades para la pantalla de carga: salen de analisis.Curiosidad
   (database\14_posiciones_curiosidades.sql), calculadas con los datos reales ---------- */
CREATE OR ALTER PROCEDURE simulacion.usp_Curiosidades
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CONCAT(Titulo, N': ', Texto) AS Texto FROM analisis.Curiosidad;
END;
GO

/* ---------- 6. Permisos de la web: leer y lanzar, nada más ---------- */
IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
BEGIN
    GRANT SELECT ON SCHEMA::simulacion TO rol_web_publico;
    GRANT EXECUTE ON OBJECT::simulacion.usp_ActualizarPredicciones TO rol_web_publico;
    GRANT EXECUTE ON OBJECT::simulacion.usp_YSi TO rol_web_publico;
    GRANT EXECUTE ON OBJECT::simulacion.usp_Curiosidades TO rol_web_publico;
END;
GO

SELECT COUNT(*) AS FilasPoisson, MAX(Goles) AS MaxGoles FROM simulacion.Poisson;
GO
