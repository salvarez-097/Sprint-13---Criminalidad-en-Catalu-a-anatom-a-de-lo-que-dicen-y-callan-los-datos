-- =============================================================================
--  Proyecto: Criminalística Cataluña
--  Fichero : 02_crear_contexto_afluencia.sql
--  Objetivo: Añadir la tabla contexto_afluencia al star schema.
--            Corre DESPUÉS de 00_crear_base_datos.sql (necesita dim_territorio).
--
--  Tabla   : contexto_afluencia (14ª tabla del esquema, contexto OSM)
--  Fuente  : OpenStreetMap (POIs por barrio) — afluencia como proxy de exposición.
--  Carga   : data/clean/osm_afluencia_barri.csv (generado por nb09, la MISMA fuente
--            que usa features_ml.csv / el modelo ML). Carga directa con pandas.to_sql.
--
--  Se une al star por id_territorio (= id de barri de dim_territorio),
--  igual que contexto_renta_barri. UNA fila por barrio (73 barrios reales).
--
--  -------------------------------------------------------------------------
--  CAMBIO DE ESQUEMA: de formato LARGO (3 categorías:
--  transporte/comercio_ocio/turismo, con n_equipamientos + densidad_km2) a
--  formato ANCHO (1 fila/barrio con los 4 POIs separados + afluencia_total).
--  Motivo: el CSV realmente disponible y usado por el ML/EDA es
--  data/clean/osm_afluencia_barri.csv (ancho, de nb09), NO el contexto_afluencia.csv
--  largo (que nunca se generará). El formato ancho coincide 1:1 con ese CSV y con
--  features_ml.csv, y permite la vista v_pbi_afluencia_barri con los 4 POIs por
--  separado. Se prescinde de densidad_km2 y fecha_snapshot_osm (no están en el CSV).
--  -------------------------------------------------------------------------
--
--  IDEMPOTENTE: DROP TABLE IF EXISTS antes de CREATE.
-- =============================================================================

USE criminalistica_cat;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS contexto_afluencia;
SET FOREIGN_KEY_CHECKS = 1;

CREATE TABLE contexto_afluencia (
  -- PK natural: un barrio = una fila (la afluencia OSM es estática, sin año)
  id_territorio    INT NOT NULL,
  -- Conteos brutos de POIs OSM dentro del polígono del barrio, por categoría:
  n_ocio           INT NOT NULL,   -- restaurantes, bares, cafés, pubs, fast_food
  n_turismo        INT NOT NULL,   -- hoteles, hostales, guest_house, apartamentos
  n_comercio       INT NOT NULL,   -- tiendas (shop=*)
  n_transport      INT NOT NULL,   -- metro, tram, bus, stop_position
  -- Suma de los 4 anteriores (proxy de afluencia total del barrio)
  afluencia_total  INT NOT NULL,
  PRIMARY KEY (id_territorio),
  CONSTRAINT fk_afluencia_territorio
    FOREIGN KEY (id_territorio) REFERENCES dim_territorio(id_territorio)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =============================================================================
-- Carga: data/clean/osm_afluencia_barri.csv -> pandas.to_sql (sin Overpass).
--   El antiguo sql/02_cargar_afluencia_osm.py queda OBSOLETO para este esquema
--   (buscaba un cache largo inexistente y descargaría de Overpass).
--
-- Verificación tras la carga:
--   SELECT COUNT(*) FROM contexto_afluencia;                     -- 73 barrios
--   SELECT * FROM contexto_afluencia ORDER BY afluencia_total DESC LIMIT 5;
--
-- Vista para Power BI: v_pbi_afluencia_barri (en sql/vistas_powerbi.sql).
-- =============================================================================
