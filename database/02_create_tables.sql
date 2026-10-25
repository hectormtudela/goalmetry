/* =============================================================================
   02_create_tables.sql
   Proyecto LigaDB (DP-800, Práctica 09) - Bloque A
   Crea las tablas de los esquemas liga, ventas e ia según docs/modelo-datos.md (v2),
   con PK, FK, CHECK, UNIQUE y DEFAULT con nombre explícito, y los índices básicos.

   Ejecución:  sqlcmd -S localhost -E -C -b -i database\02_create_tables.sql
   Idempotente: borra las tablas (en orden inverso a las FK) antes de crearlas.
   Nota: IX_Entrada_Partido NO se crea aquí; es la mejora que se mide en el Bloque D.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

/* ---------- Limpieza (hijas antes que padres) ---------- */
-- La política de RLS de 06_security.sql usa funciones con SCHEMABINDING sobre las tablas
-- de ventas: hay que quitarla antes, o el DROP TABLE falla.
DROP SECURITY POLICY IF EXISTS seguridad.pol_VentasPorEquipo;
DROP FUNCTION IF EXISTS seguridad.fn_FiltroEntrada;
DROP FUNCTION IF EXISTS seguridad.fn_FiltroEquipo;
DROP TABLE IF EXISTS seguridad.UsuarioEquipo;
GO
DROP TABLE IF EXISTS ia.Documento;
DROP TABLE IF EXISTS ventas.Entrada;
DROP TABLE IF EXISTS ventas.Abonado;
DROP TABLE IF EXISTS liga.PartidoAuditoria;
DROP TABLE IF EXISTS liga.Gol;
DROP TABLE IF EXISTS liga.Jugador;
DROP TABLE IF EXISTS liga.Partido;
DROP TABLE IF EXISTS liga.Jornada;
DROP TABLE IF EXISTS liga.Arbitro;
DROP TABLE IF EXISTS liga.Estadio;
DROP TABLE IF EXISTS liga.Equipo;
DROP TABLE IF EXISTS liga.Temporada;
GO

/* =============================== Esquema liga =============================== */

CREATE TABLE liga.Temporada
(
    TemporadaID SMALLINT IDENTITY(1,1) NOT NULL,
    Nombre      NVARCHAR(9)            NOT NULL,          -- p. ej. '2026-27'
    CONSTRAINT PK_Temporada        PRIMARY KEY (TemporadaID),
    CONSTRAINT UQ_Temporada_Nombre UNIQUE (Nombre),
    CONSTRAINT CK_Temporada_Nombre CHECK (Nombre LIKE N'[0-9][0-9][0-9][0-9]-[0-9][0-9]')
);

CREATE TABLE liga.Equipo
(
    EquipoID      INT IDENTITY(1,1) NOT NULL,
    Nombre        NVARCHAR(60)      NOT NULL,
    NombreCorto   NVARCHAR(30)      NOT NULL,
    Ciudad        NVARCHAR(60)      NOT NULL,
    AnioFundacion SMALLINT          NULL,                 -- no se carga: dato sin verificar
    CONSTRAINT PK_Equipo        PRIMARY KEY (EquipoID),
    CONSTRAINT UQ_Equipo_Nombre UNIQUE (Nombre),
    CONSTRAINT CK_Equipo_AnioFundacion CHECK (AnioFundacion BETWEEN 1850 AND 2100)
);

CREATE TABLE liga.Estadio
(
    EstadioID INT IDENTITY(1,1) NOT NULL,
    Nombre    NVARCHAR(80)      NOT NULL,
    Capacidad INT               NOT NULL,
    EquipoID  INT               NOT NULL,
    CONSTRAINT PK_Estadio           PRIMARY KEY (EstadioID),
    CONSTRAINT UQ_Estadio_Nombre    UNIQUE (Nombre),
    CONSTRAINT UQ_Estadio_Equipo    UNIQUE (EquipoID),    -- relación 1:1 equipo-estadio
    CONSTRAINT CK_Estadio_Capacidad CHECK (Capacidad > 0),
    CONSTRAINT FK_Estadio_Equipo    FOREIGN KEY (EquipoID) REFERENCES liga.Equipo (EquipoID)
);

CREATE TABLE liga.Arbitro
(
    ArbitroID INT IDENTITY(1,1) NOT NULL,
    Nombre    NVARCHAR(80)      NOT NULL,
    CONSTRAINT PK_Arbitro        PRIMARY KEY (ArbitroID),
    CONSTRAINT UQ_Arbitro_Nombre UNIQUE (Nombre)
);

CREATE TABLE liga.Jornada
(
    JornadaID   INT IDENTITY(1,1) NOT NULL,
    TemporadaID SMALLINT          NOT NULL,
    Numero      TINYINT           NOT NULL,
    CONSTRAINT PK_Jornada                PRIMARY KEY (JornadaID),
    CONSTRAINT UQ_Jornada_TemporadaNumero UNIQUE (TemporadaID, Numero),
    CONSTRAINT CK_Jornada_Numero         CHECK (Numero BETWEEN 1 AND 38),
    CONSTRAINT FK_Jornada_Temporada      FOREIGN KEY (TemporadaID) REFERENCES liga.Temporada (TemporadaID)
);

CREATE TABLE liga.Partido
(
    PartidoID          INT IDENTITY(1,1) NOT NULL,
    JornadaID          INT               NOT NULL,
    EquipoLocalID      INT               NOT NULL,
    EquipoVisitanteID  INT               NOT NULL,
    EstadioID          INT               NOT NULL,
    ArbitroPrincipalID INT               NULL,            -- NULL: árbitro aún sin designar
    FechaHora          DATETIME2(0)      NULL,
    GolesLocal         TINYINT           NULL,            -- NULL hasta que se juega
    GolesVisitante     TINYINT           NULL,
    Estado             VARCHAR(12)       NOT NULL CONSTRAINT DF_Partido_Estado DEFAULT ('Programado'),
    CONSTRAINT PK_Partido                 PRIMARY KEY (PartidoID),
    CONSTRAINT UQ_Partido_JornadaLocal     UNIQUE (JornadaID, EquipoLocalID),      -- un equipo juega
    CONSTRAINT UQ_Partido_JornadaVisitante UNIQUE (JornadaID, EquipoVisitanteID),  -- una vez por jornada
    CONSTRAINT CK_Partido_Equipos         CHECK (EquipoLocalID <> EquipoVisitanteID),
    CONSTRAINT CK_Partido_Estado          CHECK (Estado IN ('Programado', 'En juego', 'Finalizado')),
    -- Programado => sin marcador; En juego / Finalizado => marcador completo
    CONSTRAINT CK_Partido_Goles CHECK (
           (Estado = 'Programado'               AND GolesLocal IS NULL     AND GolesVisitante IS NULL)
        OR (Estado IN ('En juego', 'Finalizado') AND GolesLocal IS NOT NULL AND GolesVisitante IS NOT NULL)
    ),
    CONSTRAINT FK_Partido_Jornada   FOREIGN KEY (JornadaID)          REFERENCES liga.Jornada (JornadaID),
    CONSTRAINT FK_Partido_Local     FOREIGN KEY (EquipoLocalID)      REFERENCES liga.Equipo  (EquipoID),
    CONSTRAINT FK_Partido_Visitante FOREIGN KEY (EquipoVisitanteID)  REFERENCES liga.Equipo  (EquipoID),
    CONSTRAINT FK_Partido_Estadio   FOREIGN KEY (EstadioID)          REFERENCES liga.Estadio (EstadioID),
    CONSTRAINT FK_Partido_Arbitro   FOREIGN KEY (ArbitroPrincipalID) REFERENCES liga.Arbitro (ArbitroID)
);

CREATE TABLE liga.Jugador
(
    JugadorID      INT IDENTITY(1,1) NOT NULL,
    EquipoID       INT               NOT NULL,
    Nombre         NVARCHAR(100)     NOT NULL,
    Posicion       CHAR(2)           NULL,                -- 1 jugador sin posición en la fuente
    MinutosJugados INT               NOT NULL CONSTRAINT DF_Jugador_Minutos     DEFAULT (0),
    Goles          SMALLINT          NOT NULL CONSTRAINT DF_Jugador_Goles       DEFAULT (0),
    Asistencias    SMALLINT          NOT NULL CONSTRAINT DF_Jugador_Asistencias DEFAULT (0),
    UltimaJornada  TINYINT           NULL,                -- hasta qué jornada llegan los totales
    CONSTRAINT PK_Jugador               PRIMARY KEY (JugadorID),
    CONSTRAINT CK_Jugador_Posicion      CHECK (Posicion IN ('PT', 'DF', 'MC', 'DL')),
    CONSTRAINT CK_Jugador_Minutos       CHECK (MinutosJugados >= 0),
    CONSTRAINT CK_Jugador_Goles         CHECK (Goles >= 0),
    CONSTRAINT CK_Jugador_Asistencias   CHECK (Asistencias >= 0),
    CONSTRAINT CK_Jugador_UltimaJornada CHECK (UltimaJornada BETWEEN 1 AND 38),
    CONSTRAINT FK_Jugador_Equipo        FOREIGN KEY (EquipoID) REFERENCES liga.Equipo (EquipoID)
);

CREATE TABLE liga.Gol
(
    GolID     INT IDENTITY(1,1) NOT NULL,
    PartidoID INT               NOT NULL,
    EquipoID  INT               NOT NULL,   -- equipo al que se acredita (en propia puerta, el beneficiado)
    JugadorID INT               NULL,       -- NULL: el anotador no figura en la fuente de jugadores
    Anotador  NVARCHAR(100)     NOT NULL,
    Minuto    TINYINT           NOT NULL,
    Tipo      VARCHAR(12)       NOT NULL CONSTRAINT DF_Gol_Tipo DEFAULT ('Normal'),
    CONSTRAINT PK_Gol         PRIMARY KEY (GolID),
    CONSTRAINT CK_Gol_Minuto  CHECK (Minuto BETWEEN 1 AND 130),
    CONSTRAINT CK_Gol_Tipo    CHECK (Tipo IN ('Normal', 'Penalti', 'PropiaPuerta')),
    CONSTRAINT FK_Gol_Partido FOREIGN KEY (PartidoID) REFERENCES liga.Partido (PartidoID),
    CONSTRAINT FK_Gol_Equipo  FOREIGN KEY (EquipoID)  REFERENCES liga.Equipo  (EquipoID),
    CONSTRAINT FK_Gol_Jugador FOREIGN KEY (JugadorID) REFERENCES liga.Jugador (JugadorID)
);

-- Auditoría de cambios de resultado (la rellena el trigger de 05_procedures_triggers.sql).
CREATE TABLE liga.PartidoAuditoria
(
    AuditoriaID            BIGINT IDENTITY(1,1) NOT NULL,
    PartidoID              INT                  NOT NULL,
    EstadoAnterior         VARCHAR(12)          NULL,
    GolesLocalAnterior     TINYINT              NULL,
    GolesVisitanteAnterior TINYINT              NULL,
    EstadoNuevo            VARCHAR(12)          NULL,
    GolesLocalNuevo        TINYINT              NULL,
    GolesVisitanteNuevo    TINYINT              NULL,
    -- Usuario de la BD + login real: con EXECUTE AS USER sobre un usuario WITHOUT LOGIN,
    -- SUSER_SNAME() solo devuelve un SID ('S-1-9-3-...'). Ej.: 'u_admin (EQUIPO\Usuario)'.
    Usuario                NVARCHAR(260)        NOT NULL CONSTRAINT DF_PartidoAuditoria_Usuario
                                                DEFAULT (CONCAT(USER_NAME(), N' (', ORIGINAL_LOGIN(), N')')),
    FechaCambio            DATETIME2(0)         NOT NULL CONSTRAINT DF_PartidoAuditoria_Fecha   DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_PartidoAuditoria         PRIMARY KEY (AuditoriaID),
    CONSTRAINT FK_PartidoAuditoria_Partido FOREIGN KEY (PartidoID) REFERENCES liga.Partido (PartidoID)
);
GO

/* ============================== Esquema ventas ============================== */

CREATE TABLE ventas.Abonado
(
    AbonadoID INT IDENTITY(1,1) NOT NULL,
    EquipoID  INT               NOT NULL,
    Nombre    NVARCHAR(100)     NOT NULL,
    Email     NVARCHAR(120)     NOT NULL,   -- enmascarado en el Bloque C (DDM)
    Telefono  VARCHAR(20)       NULL,       -- enmascarado en el Bloque C (DDM)
    Documento CHAR(9)           NOT NULL,   -- DNI ficticio; enmascarado en el Bloque C (DDM)
    CONSTRAINT PK_Abonado           PRIMARY KEY (AbonadoID),
    CONSTRAINT UQ_Abonado_Email     UNIQUE (Email),
    CONSTRAINT UQ_Abonado_Documento UNIQUE (Documento),
    CONSTRAINT FK_Abonado_Equipo    FOREIGN KEY (EquipoID) REFERENCES liga.Equipo (EquipoID)
);

CREATE TABLE ventas.Entrada
(
    EntradaID   BIGINT IDENTITY(1,1) NOT NULL,
    AbonadoID   INT                  NOT NULL,
    PartidoID   INT                  NOT NULL,
    Precio      DECIMAL(8,2)         NOT NULL,
    FechaCompra DATETIME2(0)         NOT NULL,
    CONSTRAINT PK_Entrada         PRIMARY KEY (EntradaID),
    CONSTRAINT CK_Entrada_Precio  CHECK (Precio > 0),
    CONSTRAINT FK_Entrada_Abonado FOREIGN KEY (AbonadoID) REFERENCES ventas.Abonado (AbonadoID),
    CONSTRAINT FK_Entrada_Partido FOREIGN KEY (PartidoID) REFERENCES liga.Partido (PartidoID)
);
GO

/* ================================ Esquema ia ================================ */

CREATE TABLE ia.Documento
(
    DocumentoID     INT IDENTITY(1,1) NOT NULL,
    Tipo            VARCHAR(20)       NOT NULL,
    Titulo          NVARCHAR(150)     NOT NULL,
    Texto           NVARCHAR(MAX)     NOT NULL,
    EquipoID        INT               NULL,
    PartidoID       INT               NULL,
    Fuente          NVARCHAR(200)     NULL,
    Embedding       VECTOR(1024)      NULL,    -- bge-m3 devuelve 1024 dimensiones
    EmbeddingModelo NVARCHAR(100)     NULL,
    EmbeddingFecha  DATETIME2(0)      NULL,
    CONSTRAINT PK_Documento         PRIMARY KEY (DocumentoID),
    CONSTRAINT CK_Documento_Tipo    CHECK (Tipo IN ('reglamento', 'faq', 'ficha_equipo', 'resumen_jornada')),
    CONSTRAINT CK_Documento_Texto   CHECK (LEN(Texto) > 0),
    CONSTRAINT FK_Documento_Equipo  FOREIGN KEY (EquipoID)  REFERENCES liga.Equipo  (EquipoID),
    CONSTRAINT FK_Documento_Partido FOREIGN KEY (PartidoID) REFERENCES liga.Partido (PartidoID)
);
GO

/* ============================ Índices básicos ============================ */
-- Claves foráneas más consultadas (joins de clasificación, plantillas y goles).
CREATE NONCLUSTERED INDEX IX_Partido_Jornada ON liga.Partido (JornadaID);
CREATE NONCLUSTERED INDEX IX_Jugador_Equipo  ON liga.Jugador (EquipoID);
CREATE NONCLUSTERED INDEX IX_Gol_Partido     ON liga.Gol     (PartidoID);
CREATE NONCLUSTERED INDEX IX_Gol_Jugador     ON liga.Gol     (JugadorID);
GO

/* ============================== Comprobación ============================== */
SELECT s.name + N'.' + t.name AS Tabla,
       SUM(CASE WHEN o.type = 'PK' THEN 1 ELSE 0 END) AS PK,
       SUM(CASE WHEN o.type = 'F'  THEN 1 ELSE 0 END) AS FK,
       SUM(CASE WHEN o.type = 'UQ' THEN 1 ELSE 0 END) AS UQ,
       SUM(CASE WHEN o.type = 'C'  THEN 1 ELSE 0 END) AS CK,
       SUM(CASE WHEN o.type = 'D'  THEN 1 ELSE 0 END) AS DF
FROM sys.tables  AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
LEFT JOIN sys.objects AS o ON o.parent_object_id = t.object_id
WHERE s.name IN (N'liga', N'ventas', N'ia')
GROUP BY s.name, t.name
ORDER BY s.name, t.name;

SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS Tabla,
       i.name      AS Indice,
       i.type_desc AS Tipo
FROM sys.indexes AS i
WHERE i.name LIKE N'IX[_]%'
  AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
ORDER BY Tabla, Indice;

SELECT c.name AS Columna, TYPE_NAME(c.user_type_id) AS Tipo, c.max_length AS LongitudBytes
FROM sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'ia.Documento') AND c.name = N'Embedding';
GO
