/* =============================================================================
   17_parecidos.sql
   Goalmetry - Idea 9: jugadores parecidos por sus números. Cada jugador con al menos 270 minutos
   tiene un perfil VECTOR(3) con goles/90, asistencias/90 y minutos, normalizados (z-score) dentro
   de su posición para que ninguna medida pese más por su escala. VECTOR_DISTANCE busca los más
   cercanos de su misma posición.
   Es una similitud estadística: no dice nada de cómo juega cada uno.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\17_parecidos.sql
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

IF OBJECT_ID(N'analisis.JugadorPerfil', N'U') IS NULL
CREATE TABLE analisis.JugadorPerfil
(
    JugadorID INT        NOT NULL,
    Posicion  CHAR(2)    NOT NULL,
    Perfil    VECTOR(3)  NOT NULL,
    CONSTRAINT PK_JugadorPerfil PRIMARY KEY (JugadorID)
);
GO

CREATE OR ALTER PROCEDURE analisis.usp_RecalcularPerfiles
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRANSACTION;
    DELETE FROM analisis.JugadorPerfil;
    ;WITH Base AS
    (
        SELECT JugadorID, Posicion, CONVERT(FLOAT, GolesPor90) AS G, CONVERT(FLOAT, AsistenciasPor90) AS A, CONVERT(FLOAT, MinutosJugados) AS M
        FROM analisis.vw_JugadorPor90
        WHERE MinutosJugados >= 270 AND Posicion IS NOT NULL
    ),
    Z AS
    (
        SELECT JugadorID, Posicion,
               COALESCE((G - AVG(G) OVER (PARTITION BY Posicion)) / NULLIF(STDEV(G) OVER (PARTITION BY Posicion), 0), 0) AS ZG,
               COALESCE((A - AVG(A) OVER (PARTITION BY Posicion)) / NULLIF(STDEV(A) OVER (PARTITION BY Posicion), 0), 0) AS ZA,
               COALESCE((M - AVG(M) OVER (PARTITION BY Posicion)) / NULLIF(STDEV(M) OVER (PARTITION BY Posicion), 0), 0) AS ZM
        FROM Base
    )
    INSERT INTO analisis.JugadorPerfil (JugadorID, Posicion, Perfil)
    SELECT JugadorID, Posicion,
           CAST(CONCAT(N'[', CONVERT(VARCHAR(30), CONVERT(DECIMAL(9,5), ZG)), N',', CONVERT(VARCHAR(30), CONVERT(DECIMAL(9,5), ZA)), N',',
                       CONVERT(VARCHAR(30), CONVERT(DECIMAL(9,5), ZM)), N']') AS VECTOR(3))
    FROM Z;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE analisis.usp_JugadoresConPerfil
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.JugadorID, r.Nombre, r.Equipo, r.Posicion
    FROM analisis.JugadorPerfil AS p JOIN analisis.vw_JugadorPor90 AS r ON r.JugadorID = p.JugadorID
    ORDER BY CASE r.Posicion WHEN 'PT' THEN 1 WHEN 'DF' THEN 2 WHEN 'MC' THEN 3 ELSE 4 END, r.Nombre;
END;
GO

CREATE OR ALTER PROCEDURE analisis.usp_Parecidos
    @JugadorID INT,
    @Top       INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM liga.Jugador WHERE JugadorID = @JugadorID)
        THROW 50806, N'Ese jugador no existe.', 1;
    IF @Top NOT BETWEEN 1 AND 20
        THROW 50807, N'@Top debe estar entre 1 y 20.', 1;

    SELECT r.JugadorID, r.Nombre, r.EquipoID, r.Equipo, r.Posicion, r.MinutosJugados, r.Goles, r.Asistencias, r.UltimaJornada,
           r.GolesPor90, r.AsistenciasPor90,
           CASE WHEN p.JugadorID IS NULL THEN 0 ELSE 1 END AS TienePerfil
    FROM analisis.vw_JugadorPor90 AS r LEFT JOIN analisis.JugadorPerfil AS p ON p.JugadorID = r.JugadorID
    WHERE r.JugadorID = @JugadorID;

    SELECT TOP (@Top) r.JugadorID, r.Nombre, r.EquipoID, r.Equipo, r.MinutosJugados, r.Goles, r.Asistencias, r.GolesPor90, r.AsistenciasPor90,
           VECTOR_DISTANCE('euclidean', a.Perfil, b.Perfil) AS Distancia,
           100.0 / (1 + VECTOR_DISTANCE('euclidean', a.Perfil, b.Perfil)) AS Similitud
    FROM analisis.JugadorPerfil AS a
    JOIN analisis.JugadorPerfil AS b ON b.Posicion = a.Posicion AND b.JugadorID <> a.JugadorID
    JOIN analisis.vw_JugadorPor90 AS r ON r.JugadorID = b.JugadorID
    WHERE a.JugadorID = @JugadorID
    ORDER BY Distancia, r.Nombre;
END;
GO

EXEC analisis.usp_RecalcularPerfiles;
GO

IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
BEGIN
    GRANT EXECUTE ON OBJECT::analisis.usp_Parecidos TO rol_web_publico;
    GRANT EXECUTE ON OBJECT::analisis.usp_JugadoresConPerfil TO rol_web_publico;
END;
GO
