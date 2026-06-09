-- =============================================================================
--  Proyecto: Criminalística Cataluña — análisis de criminalidad 2010-2025
--  Fichero : 00_crear_base_datos.sql
--  Objetivo: Crear la base de datos MySQL (star schema) lista para cargar los
--            13 CSVs limpios de data/clean/ con 01_cargar_datos.py (to_sql).
--
--  CHARSET : utf8mb4 / utf8mb4_unicode_ci en TODA la BD y todas las tablas
--            (imprescindible para los caracteres catalanes: à è í ï ò ó ú ç ·l).
--  ENGINE  : InnoDB (necesario para las claves foráneas del star schema).
--
--  Estructura: 4 dimensiones + 3 facts + 5 contextos + 1 geo = 13 tablas.
--
--  ORDEN DE CARGA (respetar en 01_cargar_datos.py por las claves foráneas):
--    1) dimensiones  2) facts  3) contextos  4) geo
--
--  ⚠ ADVERTENCIA: este script hace DROP DATABASE IF EXISTS para garantizar un
--    esquema reproducible desde cero. Los datos viven en data/clean/*.csv
--    (fuente de verdad), así que se recargan con 01_cargar_datos.py.
--
--  Tipos derivados de la inspección real de los 13 CSVs (filas, nulls, longitud
--    máxima de cada columna). NOT NULL solo donde la fuente no tiene nulls.
-- =============================================================================

SET NAMES utf8mb4;

DROP DATABASE IF EXISTS criminalistica_cat;
CREATE DATABASE criminalistica_cat
  CHARACTER SET utf8mb4
  COLLATE       utf8mb4_unicode_ci;
USE criminalistica_cat;


-- =============================================================================
--  1. DIMENSIONES  (sin dependencias — se crean y cargan primero)
-- =============================================================================

-- dim_tiempo: 208 filas = 192 meses (2010-2025) + 16 años completos.
--   En las filas anuales mes y trimestre son NULL (nom_mes = 'Any complet').
CREATE TABLE dim_tiempo (
  id_tiempo   INT          NOT NULL,
  anyo        SMALLINT     NOT NULL,
  mes         TINYINT      NULL,          -- NULL en las 16 filas anuales
  trimestre   TINYINT      NULL,          -- NULL en las 16 filas anuales
  nom_mes     VARCHAR(20)  NOT NULL,
  PRIMARY KEY (id_tiempo)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- dim_territorio: 141 filas. Niveles conviven (barri / abp / provincia / ccaa);
--   las columnas no aplicables a un nivel quedan NULL.
--   Cataluña CCAA=137, Barcelona=138, Girona=139, Lleida=140, Tarragona=141.
CREATE TABLE dim_territorio (
  id_territorio      INT          NOT NULL,
  cod_barri          SMALLINT     NULL,   -- admite -1 como centinela
  nom_barri          VARCHAR(80)  NULL,
  cod_districte      SMALLINT     NULL,   -- admite -1 como centinela
  nom_districte      VARCHAR(50)  NULL,
  municipio          VARCHAR(50)  NULL,
  provincia          VARCHAR(50)  NULL,
  ccaa               VARCHAR(50)  NOT NULL,
  abp                VARCHAR(60)  NULL,
  region_policial    VARCHAR(60)  NULL,
  nivel_territorial  VARCHAR(20)  NOT NULL,  -- 'barri' | 'abp' | 'provincia' | 'ccaa'
  fuente             VARCHAR(20)  NOT NULL,
  PRIMARY KEY (id_territorio)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- dim_tipo_delito: 356 filas (mossos + gub + ministerio/ine). Jerárquica.
CREATE TABLE dim_tipo_delito (
  id_tipo_delito   INT           NOT NULL,
  codigo           VARCHAR(10)   NULL,    -- alfanumérico (p.ej. '21M')
  descripcio       VARCHAR(150)  NOT NULL,
  titol_cp         VARCHAR(200)  NULL,
  categoria        VARCHAR(200)  NULL,
  nivel_tipologia  VARCHAR(20)   NOT NULL, -- 'total'|'categoria'|'subcategoria'|'detalle'
  fuente           VARCHAR(20)   NOT NULL,
  PRIMARY KEY (id_tipo_delito)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- dim_demografia: 75 filas (sexo / grupo de edad / nacionalidad).
--   tipus_nacionalitat está siempre vacía en la fuente actual (se conserva).
CREATE TABLE dim_demografia (
  id_demografia       INT          NOT NULL,
  sexo                VARCHAR(20)  NULL,
  grup_edat           VARCHAR(30)  NULL,
  nacionalitat        VARCHAR(40)  NULL,
  tipus_nacionalitat  VARCHAR(50)  NULL,
  fuente              VARCHAR(20)  NOT NULL,
  PRIMARY KEY (id_demografia)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =============================================================================
--  2. FACT TABLES  (dependen de las dimensiones)
--     La columna id viene del CSV → se inserta tal cual (PK, sin AUTO_INCREMENT).
-- =============================================================================

-- fact_delitos_mossos: 321.188 filas. Mensual, por ABP, 2011-2025.
CREATE TABLE fact_delitos_mossos (
  id              INT  NOT NULL,
  id_tiempo       INT  NOT NULL,
  id_territorio   INT  NOT NULL,
  id_tipo_delito  INT  NOT NULL,
  coneguts        INT  NOT NULL,
  resolts         INT  NOT NULL,
  detencions      INT  NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_mossos_tiempo     FOREIGN KEY (id_tiempo)      REFERENCES dim_tiempo(id_tiempo),
  CONSTRAINT fk_mossos_territorio FOREIGN KEY (id_territorio)  REFERENCES dim_territorio(id_territorio),
  CONSTRAINT fk_mossos_tipo       FOREIGN KEY (id_tipo_delito) REFERENCES dim_tipo_delito(id_tipo_delito)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- fact_incidentes_gub: 543.709 filas. Mensual, por barrio, 2010-2025.
--   id_tipo_incident referencia dim_tipo_delito (tipos GUB, ids 125-250).
CREATE TABLE fact_incidentes_gub (
  id                INT  NOT NULL,
  id_tiempo         INT  NOT NULL,
  id_territorio     INT  NOT NULL,
  id_tipo_incident  INT  NOT NULL,
  num_incidents     INT  NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_gub_tiempo     FOREIGN KEY (id_tiempo)        REFERENCES dim_tiempo(id_tiempo),
  CONSTRAINT fk_gub_territorio FOREIGN KEY (id_territorio)    REFERENCES dim_territorio(id_territorio),
  CONSTRAINT fk_gub_tipo       FOREIGN KEY (id_tipo_incident) REFERENCES dim_tipo_delito(id_tipo_delito)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- fact_criminalidad_agregada: 22.248 filas. Anual, 5 territorios catalanes (137-141).
--   id_tipo_delito e id_demografia son FK NULLABLE (no todas las métricas las usan).
CREATE TABLE fact_criminalidad_agregada (
  id              INT          NOT NULL,
  id_tiempo       INT          NOT NULL,
  id_territorio   INT          NOT NULL,
  id_tipo_delito  INT          NULL,
  id_demografia   INT          NULL,
  total           INT          NOT NULL,
  metrica         VARCHAR(30)  NOT NULL,
  fuente          VARCHAR(20)  NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_crim_tiempo     FOREIGN KEY (id_tiempo)      REFERENCES dim_tiempo(id_tiempo),
  CONSTRAINT fk_crim_territorio FOREIGN KEY (id_territorio)  REFERENCES dim_territorio(id_territorio),
  CONSTRAINT fk_crim_tipo       FOREIGN KEY (id_tipo_delito) REFERENCES dim_tipo_delito(id_tipo_delito),
  CONSTRAINT fk_crim_demografia FOREIGN KEY (id_demografia)  REFERENCES dim_demografia(id_demografia)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =============================================================================
--  3. CONTEXTOS  (tablas largas; se unen al star por anyo + id_territori)
--     No traen columna id en el CSV → id INT AUTO_INCREMENT PK.
--     OJO: la columna se llama id_territori (catalán, sin 'o' final), pero la
--     FK referencia dim_territorio.id_territorio.
-- =============================================================================

-- contexto_penitenciaria: 12.240 filas. Idescat 2010-2023 (formato largo).
CREATE TABLE contexto_penitenciaria (
  id            INT          NOT NULL AUTO_INCREMENT,
  anyo          SMALLINT     NOT NULL,
  id_territori  INT          NOT NULL,
  territori     VARCHAR(50)  NOT NULL,
  desglose      VARCHAR(20)  NOT NULL,   -- nacionalitat|edat_delicte|regim_sexe|altes|baixes
  categoria     VARCHAR(120) NOT NULL,
  subcategoria  VARCHAR(60)  NULL,
  sexe          VARCHAR(10)  NULL,
  grup_edat     VARCHAR(10)  NULL,
  valor         INT          NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_penit_territorio FOREIGN KEY (id_territori) REFERENCES dim_territorio(id_territorio)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- contexto_socioeconomico: 1.247 filas. Renta / paro / tasa paro / nivel educativo.
--   valor es DOUBLE (mezcla euros, %, personas). id_territori NULLABLE.
CREATE TABLE contexto_socioeconomico (
  id                 INT          NOT NULL AUTO_INCREMENT,
  anyo               SMALLINT     NOT NULL,
  id_territori       INT          NULL,
  territori          VARCHAR(80)  NOT NULL,
  nivel_territorial  VARCHAR(20)  NULL,
  indicador          VARCHAR(30)  NOT NULL,
  categoria          VARCHAR(80)  NULL,
  sexe               VARCHAR(10)  NULL,
  valor              DOUBLE       NOT NULL,
  unitat             VARCHAR(30)  NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_socio_territorio FOREIGN KEY (id_territori) REFERENCES dim_territorio(id_territorio)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- contexto_poblacion: 79.587 filas. Padrón 1998-2025 (Cataluña + municipios).
--   id_territori solo informado para la fila agregada Cataluña (137); resto NULL.
CREATE TABLE contexto_poblacion (
  id                 INT          NOT NULL AUTO_INCREMENT,
  anyo               SMALLINT     NOT NULL,
  id_territori       INT          NULL,
  territori          VARCHAR(80)  NOT NULL,
  nivel_territorial  VARCHAR(20)  NOT NULL,
  sexe               VARCHAR(10)  NOT NULL,
  valor              INT          NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_pob_territorio FOREIGN KEY (id_territori) REFERENCES dim_territorio(id_territorio)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- contexto_encuestas: 513 filas. EVB / ESPC / ISC (victimización, percepción).
--   valor es DOUBLE (admite negativos: objetivo UE -50%). anyo llega a 2030 (target).
CREATE TABLE contexto_encuestas (
  id                 INT          NOT NULL AUTO_INCREMENT,
  font               VARCHAR(10)  NOT NULL,   -- EVB | ESPC | ISC
  anyo               SMALLINT     NOT NULL,
  id_territori       INT          NULL,
  territori          VARCHAR(50)  NOT NULL,
  nivel_territorial  VARCHAR(20)  NOT NULL,
  categoria          VARCHAR(80)  NULL,
  subcategoria       VARCHAR(80)  NULL,
  indicador          VARCHAR(100) NOT NULL,
  valor              DOUBLE       NOT NULL,
  unitat             VARCHAR(30)  NOT NULL,
  nota               VARCHAR(150) NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_enq_territorio FOREIGN KEY (id_territori) REFERENCES dim_territorio(id_territorio)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- contexto_renta_barri: 1.241 filas. Renta a nivel barri 2015-2023.
--   id_territori = barri GUB (63-136) → joinable con fact_incidentes_gub.
--   categoria y sexe están siempre vacías en la fuente actual (se conservan).
CREATE TABLE contexto_renta_barri (
  id                 INT          NOT NULL AUTO_INCREMENT,
  anyo               SMALLINT     NOT NULL,
  id_territori       INT          NOT NULL,
  territori          VARCHAR(80)  NOT NULL,
  nivel_territorial  VARCHAR(20)  NOT NULL,
  indicador          VARCHAR(30)  NOT NULL,
  categoria          VARCHAR(50)  NULL,
  sexe               VARCHAR(10)  NULL,
  valor              INT          NOT NULL,
  unitat             VARCHAR(10)  NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_renta_territorio FOREIGN KEY (id_territori) REFERENCES dim_territorio(id_territorio)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =============================================================================
--  4. GEO  (geometrías para ML espacial; depende de dim_territorio)
-- =============================================================================

-- geo_territorio: 129 filas (73 barris + 56 ABPs). id_territorio único → PK natural.
--   geometria_wgs84 son polígonos WKT que llegan a ~1,45 M de caracteres → LONGTEXT
--   (TEXT/MEDIUMTEXT se quedarían cortos). Se cargan como texto con to_sql.
--   Para análisis espacial nativo se puede materializar una columna GEOMETRY, p.ej.:
--     ALTER TABLE geo_territorio ADD COLUMN geom GEOMETRY SRID 4326 NULL;
--     UPDATE geo_territorio SET geom = ST_GeomFromText(geometria_wgs84, 4326);
CREATE TABLE geo_territorio (
  id_territorio      INT          NOT NULL,
  nivel_territorial  VARCHAR(20)  NOT NULL,   -- 'barri' | 'abp'
  codi               SMALLINT     NULL,
  nom                VARCHAR(80)  NOT NULL,
  geometria_wgs84    LONGTEXT     NOT NULL,
  PRIMARY KEY (id_territorio),
  CONSTRAINT fk_geo_territorio FOREIGN KEY (id_territorio) REFERENCES dim_territorio(id_territorio)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =============================================================================
--  Fin del esquema. Comprobación rápida tras crear:
--    SHOW TABLES;
--    SELECT TABLE_NAME, TABLE_COLLATION FROM information_schema.TABLES
--      WHERE TABLE_SCHEMA = 'criminalistica_cat';   -- todas utf8mb4_unicode_ci
--  Siguiente paso: cargar data/clean/*.csv con sql/01_cargar_datos.py
-- =============================================================================
