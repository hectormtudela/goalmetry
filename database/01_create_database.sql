/* =============================================================================
   01_create_database.sql
   Proyecto LigaDB (DP-800, Práctica 09) - Bloque A
   Crea la base de datos LigaDB desde cero y sus esquemas.

   Ejecución:  sqlcmd -S localhost -E -C -b -i database\01_create_database.sql
   Idempotente: si LigaDB existe, se elimina y se vuelve a crear.
   Es el ÚNICO script del proyecto con DROP DATABASE y solo afecta a LigaDB.
   ============================================================================= */
SET NOCOUNT ON;
USE master;
GO

IF DB_ID(N'LigaDB') IS NOT NULL
BEGIN
    PRINT N'LigaDB existe: se cierra cualquier conexión abierta y se elimina.';
    ALTER DATABASE LigaDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE LigaDB;
END;
GO

-- Collation española que ignora mayúsculas y tildes ('Atletico' = 'Atlético').
CREATE DATABASE LigaDB
    COLLATE Modern_Spanish_100_CI_AI;
GO

-- 170 = SQL Server 2025: necesario para REGEXP_LIKE y las funciones JSON nuevas.
-- SIMPLE: base de datos de prácticas, no se necesitan copias del log.
ALTER DATABASE LigaDB SET COMPATIBILITY_LEVEL = 170;
ALTER DATABASE LigaDB SET RECOVERY SIMPLE;
GO

USE LigaDB;
GO

-- Funciones en vista previa de SQL Server 2025 RTM (EDIT_DISTANCE, EDIT_DISTANCE_SIMILARITY...).
-- Configuración con ámbito de base de datos: solo afecta a LigaDB, no al resto de la instancia.
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

CREATE SCHEMA liga   AUTHORIZATION dbo;   -- núcleo: temporada, equipos, partidos, jugadores, goles
GO
CREATE SCHEMA ventas  AUTHORIZATION dbo;   -- abonados y entradas (datos generados por script)
GO
CREATE SCHEMA ia      AUTHORIZATION dbo;   -- documentos y embeddings para búsqueda semántica y RAG
GO
CREATE SCHEMA staging AUTHORIZATION dbo;   -- tablas temporales de carga de los CSV (se vacían al terminar)
GO

-- Comprobación
SELECT name                         AS BaseDeDatos,
       collation_name               AS Collation,
       compatibility_level          AS NivelCompatibilidad,
       recovery_model_desc          AS ModeloRecuperacion
FROM sys.databases
WHERE name = N'LigaDB';

SELECT name AS Configuracion, value AS Valor
FROM sys.database_scoped_configurations
WHERE name = N'PREVIEW_FEATURES';

SELECT name AS Esquema
FROM sys.schemas
WHERE name IN (N'liga', N'ventas', N'ia', N'staging')
ORDER BY name;
GO
