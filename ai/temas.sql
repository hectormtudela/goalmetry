/* =============================================================================
   ai/temas.sql
   Goalmetry - Idea 7: temas de los que la base de datos NO tiene datos (lesiones, xG,
   alineaciones...). Si la pregunta trata de uno, se responde «No tengo ese dato» sin llamar
   al modelo: es más rápido, gasta menos memoria y no puede inventarse nada.
   Excepcion evita falsos positivos: «tarjetas» o «tiros» también salen en el reglamento,
   y de eso sí hay documentos.
   Se decide con expresiones regulares, sin LLM, y se mide en tests/tests_temas.sql.
   Ejecución:  sqlcmd -S localhost -E -C -b -i ai\temas.sql
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

IF OBJECT_ID(N'ia.TemaNoSoportado', N'U') IS NULL
CREATE TABLE ia.TemaNoSoportado
(
    Tema        VARCHAR(24)    NOT NULL,
    Descripcion NVARCHAR(100)  NOT NULL,   -- completa la frase «la base de datos no guarda ...»
    Patron      NVARCHAR(400)  NOT NULL,
    Excepcion   NVARCHAR(400)  NULL,
    Alternativa NVARCHAR(200)  NOT NULL,
    CONSTRAINT PK_TemaNoSoportado PRIMARY KEY (Tema)
);
GO

MERGE ia.TemaNoSoportado AS d
USING (VALUES
 ('lesiones', N'lesiones ni bajas médicas',
    N'\b(lesi[oó]n|lesiones|lesionad[oa]s?|baja m[eé]dica|bajas m[eé]dicas)\b',
    N'reglamento|regla|norma',
    N'Sí tengo sus goles, asistencias y minutos jugados.'),
 ('xg', N'goles esperados (xG)',
    N'\bxg\b|goles esperados|expected goals', NULL,
    N'Sí tengo los goles reales de cada partido.'),
 ('alineaciones', N'alineaciones ni convocatorias',
    N'\b(alineaci[oó]n|alineaciones|titular|titulares|once inicial|once titular|convocatoria|convocad[oa]s)\b', NULL,
    N'Sí tengo los minutos jugados de cada jugador.'),
 ('fichajes', N'fichajes, traspasos ni contratos',
    N'\b(fichaje|fichajes|ficha(r|do|ron|r[aá])|traspaso|traspasos|cl[aá]usula|contrato|valor de mercado)\b', NULL,
    N'Sí tengo la plantilla actual de cada equipo.'),
 ('sueldos', N'sueldos ni presupuestos',
    N'\b(salario|salarios|sueldo|sueldos|presupuesto)\b|cu[aá]nto (cobra|cobran|gana|ganan)\b', NULL,
    N'Sí tengo los datos deportivos de cada jugador.'),
 ('tarjetas', N'las tarjetas de cada partido',
    N'(cu[aá]nt[ao]s|qui[eé]n|qu[eé] (equipo|jugador|[aá]rbitro)|m[aá]s|menos|ha visto|ha sacado|lleva).*\b(tarjetas?|amarillas?|expulsad[oa]s?|expulsiones)\b|\b(tarjetas?|amarillas?)\b.*\b(tiene|lleva|ha visto|vio|sac[oó]|ha sacado)\b',
    N'reglamento|regla|norma|qu[eé] (pasa|ocurre|significa)|para (ser|que)|hacen falta|cu[aá]ntas amarillas (hacen|son|supone)|\b(recibe|mismo partido)\b',
    N'Sí tengo los partidos que ha dirigido cada árbitro y sus goles.'),
 ('estadisticas', N'posesión, tiros ni córneres',
    N'\b(posesi[oó]n|tiros?|disparos?|remates?|c[oó]rners?|c[oó]rneres|saques? de esquina)\b',
    N'reglamento|regla|norma|qu[eé] (pasa|ocurre|significa|es)\b|c[oó]mo se (saca|lanza)',
    N'Sí tengo los goles y el marcador de cada partido.'),
 ('otras_competiciones', N'otras competiciones ni temporadas anteriores',
    N'\b(mundial|eurocopa|europa league|conference league|copa del rey|supercopa|bal[oó]n de oro|selecci[oó]n)\b|\bchampions\b|temporada (pasada|anterior)|a[nñ]o pasado',
    N'opciones|clasifica|plaza|puesto|probabilidad',
    N'Sí tengo LaLiga 2026-27, jornada a jornada.'),
 ('apuestas', N'cuotas de apuestas',
    N'\b(cuota|cuotas|apuesta|apuestas|apostar)\b', NULL,
    N'Sí tengo una estimación propia en la pantalla Predicciones.')
) AS o (Tema, Descripcion, Patron, Excepcion, Alternativa)
   ON d.Tema = o.Tema
WHEN MATCHED THEN UPDATE SET Descripcion = o.Descripcion, Patron = o.Patron, Excepcion = o.Excepcion, Alternativa = o.Alternativa
WHEN NOT MATCHED THEN INSERT (Tema, Descripcion, Patron, Excepcion, Alternativa) VALUES (o.Tema, o.Descripcion, o.Patron, o.Excepcion, o.Alternativa)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
GO

CREATE OR ALTER PROCEDURE ia.usp_TemaNoSoportado
    @Pregunta NVARCHAR(500),
    @Tema     VARCHAR(24)    = NULL OUTPUT,
    @Mensaje  NVARCHAR(400)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Tema = NULL, @Mensaje = NULL;
    SELECT TOP (1) @Tema = t.Tema,
           @Mensaje = CONCAT(N'No tengo ese dato: la base de datos no guarda ', t.Descripcion, N'. ', t.Alternativa)
    FROM ia.TemaNoSoportado AS t
    WHERE REGEXP_LIKE(@Pregunta, t.Patron, 'i')
      AND (t.Excepcion IS NULL OR NOT REGEXP_LIKE(@Pregunta, t.Excepcion, 'i'))
    ORDER BY t.Tema;
END;
GO
