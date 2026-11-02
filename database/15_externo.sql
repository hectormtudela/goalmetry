/* =============================================================================
   15_externo.sql
   Goalmetry - Esquema externo: datos de fuentes públicas gratuitas (football-data.co.uk y
   openfootball), SIEMPRE separados de los datos reales de liga.* y con su columna Fuente.
   Nunca se escriben en liga.* ni en los CSV de data/. Los carga externo\importar_externo.ps1,
   que los descarga en una carpeta ignorada por git: no se copian al repositorio.
   Si no hay Internet, estas tablas quedan vacías y la aplicación lo dice en pantalla.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\15_externo.sql
   Idempotente: no borra lo ya importado.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

IF SCHEMA_ID(N'externo') IS NULL EXEC (N'CREATE SCHEMA externo AUTHORIZATION dbo;');
GO

-- Cómo llama cada fuente a cada equipo. Un nombre sin alias se anota para revisarlo a mano.
IF OBJECT_ID(N'externo.Alias', N'U') IS NULL
CREATE TABLE externo.Alias
(
    Fuente VARCHAR(20) NOT NULL, NombreExterno NVARCHAR(60) NOT NULL, EquipoID INT NOT NULL,
    CONSTRAINT PK_Alias PRIMARY KEY (Fuente, NombreExterno)
);
GO
MERGE externo.Alias AS d
USING (SELECT f.Fuente, a.NombreExterno, e.EquipoID
       FROM (VALUES
         ('football-data', N'Alaves', N'Deportivo Alavés'), ('football-data', N'Ath Bilbao', N'Athletic Bilbao'), ('football-data', N'Ath Madrid', N'Atlético Madrid'),
         ('football-data', N'Barcelona', N'Barcelona'), ('football-data', N'Betis', N'Real Betis'), ('football-data', N'Celta', N'Celta Vigo'),
         ('football-data', N'Elche', N'Elche CF'), ('football-data', N'Espanol', N'RCD Espanyol'), ('football-data', N'Getafe', N'Getafe'),
         ('football-data', N'La Coruna', N'Deportivo de A Coruña'), ('football-data', N'Levante', N'Levante UD'), ('football-data', N'Malaga', N'Málaga CF'),
         ('football-data', N'Osasuna', N'Osasuna'), ('football-data', N'Real Madrid', N'Real Madrid'), ('football-data', N'Santander', N'Real Racing Club'),
         ('football-data', N'Sevilla', N'Sevilla'), ('football-data', N'Sociedad', N'Real Sociedad'), ('football-data', N'Valencia', N'Valencia'),
         ('football-data', N'Vallecano', N'Rayo Vallecano de Madrid'), ('football-data', N'Villarreal', N'Villarreal'),
         ('openfootball', N'Deportivo Alavés', N'Deportivo Alavés'), ('openfootball', N'Athletic Club', N'Athletic Bilbao'), ('openfootball', N'Club Atlético de Madrid', N'Atlético Madrid'),
         ('openfootball', N'FC Barcelona', N'Barcelona'), ('openfootball', N'Real Betis Balompié', N'Real Betis'), ('openfootball', N'RC Celta de Vigo', N'Celta Vigo'),
         ('openfootball', N'Elche CF', N'Elche CF'), ('openfootball', N'RCD Espanyol de Barcelona', N'RCD Espanyol'), ('openfootball', N'Getafe CF', N'Getafe'),
         ('openfootball', N'RC Deportivo La Coruña', N'Deportivo de A Coruña'), ('openfootball', N'Levante UD', N'Levante UD'), ('openfootball', N'Málaga CF', N'Málaga CF'),
         ('openfootball', N'CA Osasuna', N'Osasuna'), ('openfootball', N'Real Madrid CF', N'Real Madrid'), ('openfootball', N'Real Racing Club de Santander', N'Real Racing Club'),
         ('openfootball', N'Sevilla FC', N'Sevilla'), ('openfootball', N'Real Sociedad de Fútbol', N'Real Sociedad'), ('openfootball', N'Valencia CF', N'Valencia'),
         ('openfootball', N'Rayo Vallecano de Madrid', N'Rayo Vallecano de Madrid'), ('openfootball', N'Villarreal CF', N'Villarreal')
       ) AS a (Fuente, NombreExterno, Equipo)
       CROSS APPLY (SELECT a.Fuente) AS f
       JOIN liga.Equipo AS e ON e.Nombre = a.Equipo) AS o
   ON d.Fuente = o.Fuente AND d.NombreExterno = o.NombreExterno
WHEN NOT MATCHED THEN INSERT (Fuente, NombreExterno, EquipoID) VALUES (o.Fuente, o.NombreExterno, o.EquipoID);
GO

-- Calendario: partidos que aún no están jugados en liga.Partido. SEPARADO de los partidos jugados.
IF OBJECT_ID(N'externo.PartidoFuturo', N'U') IS NULL
CREATE TABLE externo.PartidoFuturo
(
    Jornada TINYINT NOT NULL, Fecha DATE NULL, Hora VARCHAR(5) NULL, LocalID INT NOT NULL, VisitanteID INT NOT NULL,
    Fuente VARCHAR(40) NOT NULL, Importado DATETIME2(0) NOT NULL CONSTRAINT DF_PartidoFuturo_Importado DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_PartidoFuturo PRIMARY KEY (LocalID, VisitanteID)
);
-- Estadísticas por partido que no están en los CSV: tiros, córneres, tarjetas y xG.
IF OBJECT_ID(N'externo.PartidoExtra', N'U') IS NULL
CREATE TABLE externo.PartidoExtra
(
    LocalID INT NOT NULL, VisitanteID INT NOT NULL, Fecha DATE NOT NULL,
    GolesLocal TINYINT NULL, GolesVisitante TINYINT NULL,
    TirosL TINYINT NULL, TirosV TINYINT NULL, APuertaL TINYINT NULL, APuertaV TINYINT NULL,
    CornersL TINYINT NULL, CornersV TINYINT NULL, AmarillasL TINYINT NULL, AmarillasV TINYINT NULL,
    RojasL TINYINT NULL, RojasV TINYINT NULL, XgL DECIMAL(4,2) NULL, XgV DECIMAL(4,2) NULL,
    Fuente VARCHAR(40) NOT NULL, Importado DATETIME2(0) NOT NULL CONSTRAINT DF_PartidoExtra_Importado DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_PartidoExtra PRIMARY KEY (LocalID, VisitanteID)
);
-- Cuotas medias de apuestas: solo como referencia externa con la que comparar el modelo.
IF OBJECT_ID(N'externo.Cuota', N'U') IS NULL
CREATE TABLE externo.Cuota
(
    LocalID INT NOT NULL, VisitanteID INT NOT NULL, CuotaLocal DECIMAL(6,2) NOT NULL, CuotaEmpate DECIMAL(6,2) NOT NULL, CuotaVisitante DECIMAL(6,2) NOT NULL,
    Fuente VARCHAR(40) NOT NULL, Importado DATETIME2(0) NOT NULL CONSTRAINT DF_Cuota_Importado DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_Cuota PRIMARY KEY (LocalID, VisitanteID)
);
-- Resultados de temporadas anteriores: solo para el punto de partida del Elo.
IF OBJECT_ID(N'externo.PartidoHistorico', N'U') IS NULL
CREATE TABLE externo.PartidoHistorico
(
    Temporada CHAR(7) NOT NULL, Orden INT NOT NULL, Fecha DATE NULL, LocalID INT NULL, VisitanteID INT NULL,
    LocalNombre NVARCHAR(60) NOT NULL, VisitanteNombre NVARCHAR(60) NOT NULL, GolesLocal TINYINT NOT NULL, GolesVisitante TINYINT NOT NULL,
    Fuente VARCHAR(40) NOT NULL,
    CONSTRAINT PK_PartidoHistorico PRIMARY KEY (Temporada, Orden)
);
-- Lo que no se ha podido contrastar: no se usa y queda para revisarlo a mano.
IF OBJECT_ID(N'externo.PendienteRevision', N'U') IS NULL
CREATE TABLE externo.PendienteRevision
(
    PendienteID INT IDENTITY(1,1) NOT NULL, Motivo NVARCHAR(60) NOT NULL, Detalle NVARCHAR(300) NOT NULL, Fuente VARCHAR(40) NOT NULL,
    CONSTRAINT PK_PendienteRevision PRIMARY KEY (PendienteID)
);
GO

IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
    GRANT SELECT ON SCHEMA::externo TO rol_web_publico;
GO
