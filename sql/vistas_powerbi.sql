-- =============================================================================
--  VISTAS SQL PARA EL DASHBOARD POWER BI — Criminalística Cataluña
--  Base: criminalistica_cat
--
--  Diseño: cada fuente se usa en su granularidad natural (no se cruzan fuentes
--  a niveles territoriales incompatibles). GUB = barrio (Barcelona), Mossos =
--  ABP (Cataluña), agregada = provincia/CCAA (macro).
--
--  Estas vistas se importan en Power BI (modo Import). Forman un mini esquema
--  en estrella: las dimensiones (dim_*) se importan tal cual, y estas vistas
--  son las tablas de hechos ya preparadas para visualizar.
--
--  Convención: todas las vistas empiezan por v_pbi_ para identificarlas fácil.
-- =============================================================================

USE criminalistica_cat;

-- =============================================================================
--  PÁGINA 1 — VISIÓN GENERAL
--  KPIs + evolución temporal. Combina GUB y Mossos a nivel anual de toda
--  Cataluña, con población para calcular la tasa per cápita en Power BI.
-- =============================================================================

-- 1a. Serie anual de incidentes/delitos por fuente (para la línea temporal y KPIs)
CREATE OR REPLACE VIEW v_pbi_serie_anual AS
SELECT
    t.anyo,
    'GUB (Barcelona)'        AS fuente,
    SUM(g.num_incidents)     AS total
FROM fact_incidentes_gub g
JOIN dim_tiempo t ON g.id_tiempo = t.id_tiempo
WHERE t.mes IS NOT NULL                      -- excluir filas anuales agregadas
GROUP BY t.anyo
UNION ALL
SELECT
    t.anyo,
    'Mossos (Cataluña)'      AS fuente,
    SUM(m.coneguts)          AS total
FROM fact_delitos_mossos m
JOIN dim_tiempo t ON m.id_tiempo = t.id_tiempo
WHERE t.mes IS NOT NULL
GROUP BY t.anyo;

-- 1b. Serie mensual GUB (para estacionalidad y detalle temporal fino)
CREATE OR REPLACE VIEW v_pbi_serie_mensual AS
SELECT
    t.anyo,
    t.mes,
    t.nom_mes,
    t.trimestre,
    SUM(g.num_incidents) AS total_incidentes
FROM fact_incidentes_gub g
JOIN dim_tiempo t ON g.id_tiempo = t.id_tiempo
WHERE t.mes IS NOT NULL
GROUP BY t.anyo, t.mes, t.nom_mes, t.trimestre;

-- 1c. Población de Cataluña por año (denominador de la tasa per cápita)
--     Se toma el nivel CCAA, sexo Total.
CREATE OR REPLACE VIEW v_pbi_poblacion_anual AS
SELECT
    p.anyo,
    SUM(p.valor) AS poblacion
FROM contexto_poblacion p
WHERE p.nivel_territorial = 'ccaa'
  AND p.sexe = 'Total'
GROUP BY p.anyo;


-- =============================================================================
--  PÁGINA 2 — GEOGRAFÍA
--  Mapa por barrio (GUB) + ranking. Incluye geometría para el mapa de formas.
--  Nivel: barrio de Barcelona (la granularidad fina que tiene GUB).
-- =============================================================================

-- 2a. Incidentes totales por barrio + geometría (para el mapa coroplético)
--     IMPORTANTE: la agregación se hace en una subconsulta por id_territorio y la
--     geometría se une DESPUÉS. Nunca poner geometria_wgs84 en el GROUP BY: es un
--     LONGTEXT de hasta 1,4 M de caracteres y agrupar por él hace la consulta inviable.
CREATE OR REPLACE VIEW v_pbi_geo_barrio AS
SELECT
    d.id_territorio,
    d.nom_barri,
    d.nom_districte,
    geo.geometria_wgs84,
    inc.total_incidentes,
    inc.anyos_con_datos
FROM dim_territorio d
JOIN (
    SELECT
        g.id_territorio,
        SUM(g.num_incidents)   AS total_incidentes,
        COUNT(DISTINCT t.anyo) AS anyos_con_datos
    FROM fact_incidentes_gub g
    JOIN dim_tiempo t ON g.id_tiempo = t.id_tiempo
    WHERE t.mes IS NOT NULL
    GROUP BY g.id_territorio
) inc ON d.id_territorio = inc.id_territorio
LEFT JOIN geo_territorio geo ON d.id_territorio = geo.id_territorio
WHERE d.nom_barri <> 'Desconegut';          -- excluir el agregado sin barrio

-- 2b. Incidentes por barrio y año (para el mapa con filtro temporal / animación)
CREATE OR REPLACE VIEW v_pbi_geo_barrio_anual AS
SELECT
    d.id_territorio,
    d.nom_barri,
    d.nom_districte,
    t.anyo,
    SUM(g.num_incidents) AS total_incidentes
FROM fact_incidentes_gub g
JOIN dim_tiempo t      ON g.id_tiempo = t.id_tiempo
JOIN dim_territorio d  ON g.id_territorio = d.id_territorio
WHERE t.mes IS NOT NULL
  AND d.nom_barri <> 'Desconegut'
GROUP BY d.id_territorio, d.nom_barri, d.nom_districte, t.anyo;

-- 2c. Centroide (lat/lon) por barrio + incidentes (para el mapa de PUNTOS/burbujas)
--     El centroide se deriva del WKT con ST_Centroid; SRID 0 (plano) basta para
--     polígonos pequeños como un barrio (error de centímetros) y deja ST_X=lon,
--     ST_Y=lat. Igual que en 2a, la agregación va en subconsulta y el centroide se
--     calcula UNA vez por fila: nunca agrupar por la geometría LONGTEXT.
CREATE OR REPLACE VIEW v_pbi_geo_barrio_latlon AS
SELECT
    d.id_territorio,
    d.nom_barri,
    d.nom_districte,
    ST_Y(ST_Centroid(ST_GeomFromText(geo.geometria_wgs84))) AS lat,
    ST_X(ST_Centroid(ST_GeomFromText(geo.geometria_wgs84))) AS lon,
    inc.total_incidentes
FROM dim_territorio d
JOIN (
    SELECT g.id_territorio, SUM(g.num_incidents) AS total_incidentes
    FROM fact_incidentes_gub g
    JOIN dim_tiempo t ON g.id_tiempo = t.id_tiempo
    WHERE t.mes IS NOT NULL
    GROUP BY g.id_territorio
) inc ON d.id_territorio = inc.id_territorio
JOIN geo_territorio geo ON d.id_territorio = geo.id_territorio
WHERE d.nom_barri <> 'Desconegut';


-- =============================================================================
--  PÁGINA 3 — TIPOLOGÍA Y DEMOGRAFÍA
--  Qué delitos y contra quién. Usa la fact agregada (nivel macro).
--  Filtra UN solo nivel de tipología para no doble-contar, y normaliza sexo.
-- =============================================================================

-- 3a. Delitos por categoría (nivel 'categoria' para evitar doble conteo)
--     Métrica hechos_conocidos del Ministerio (la más completa para tipología).
--     OJO doble conteo territorial: hechos_conocidos existe a nivel CCAA (Cataluña) Y a
--     nivel provincia (Barcelona+Girona+Lleida+Tarragona), y Cataluña = suma de las 4
--     provincias. Hay que filtrar UN solo nivel: nivel_territorial='ccaa' (toda Cataluña).
--     Sin este filtro la suma sale ×2 (13.338.582 en vez de 6.669.291).
CREATE OR REPLACE VIEW v_pbi_tipologia AS
SELECT
    t.anyo,
    td.descripcio AS categoria,                -- en filas de nivel 'categoria' el nombre
    SUM(a.total) AS total                       -- de la categoría está en descripcio;
FROM fact_criminalidad_agregada a               -- la columna categoria (apunta al padre)
JOIN dim_tiempo t       ON a.id_tiempo = t.id_tiempo   -- es NULL en ese nivel
JOIN dim_tipo_delito td ON a.id_tipo_delito = td.id_tipo_delito
JOIN dim_territorio d   ON a.id_territorio = d.id_territorio
WHERE a.metrica = 'hechos_conocidos'
  AND td.nivel_tipologia = 'categoria'
  AND td.descripcio IS NOT NULL
  AND d.nivel_territorial = 'ccaa'              -- evita sumar Cataluña + sus 4 provincias
GROUP BY t.anyo, td.descripcio;

-- 3b. Demografía: detenciones por sexo y grupo de edad (etiquetas normalizadas)
--     El desglose por edad/sexo (id_demografia) vive en la fuente 'portal'. La fuente
--     'ministerio' trae las detenciones AGREGADAS sin demografía (id_demografia NULL),
--     así que hay que usar 'portal'. Se excluyen los subtotales 'Ambos sexos' y
--     'TOTAL edad' para no doble-contar. Normaliza Masculino -> Hombre, Femenino -> Mujer.
CREATE OR REPLACE VIEW v_pbi_demografia AS
SELECT
    t.anyo,
    CASE
        WHEN dm.sexo IN ('Masculino', 'Hombres', 'Hombre') THEN 'Hombre'
        WHEN dm.sexo IN ('Femenino', 'Mujeres', 'Mujer')   THEN 'Mujer'
        ELSE 'Total'
    END AS sexo,
    dm.grup_edat,
    SUM(a.total) AS total
FROM fact_criminalidad_agregada a
JOIN dim_tiempo t      ON a.id_tiempo = t.id_tiempo
JOIN dim_demografia dm ON a.id_demografia = dm.id_demografia
WHERE a.metrica = 'detenciones'
  AND a.fuente  = 'portal'                    -- 'portal' es la fuente con desglose demográfico
  AND dm.sexo IN ('Masculino', 'Femenino')   -- excluir subtotal 'Ambos sexos'
  AND dm.grup_edat IS NOT NULL
  AND dm.grup_edat <> 'TOTAL edad'           -- excluir subtotal de edad
GROUP BY t.anyo,
         CASE
             WHEN dm.sexo IN ('Masculino', 'Hombres', 'Hombre') THEN 'Hombre'
             WHEN dm.sexo IN ('Femenino', 'Mujeres', 'Mujer')   THEN 'Mujer'
             ELSE 'Total'
         END,
         dm.grup_edat;


-- =============================================================================
--  PÁGINA 4 — SOCIOECONÓMICO (el hallazgo del sesgo de exposición)
--  Por barrio: renta, educación, afluencia OSM e incidentes (abs y per cápita).
--  Esta es la vista que sostiene el argumento estrella del proyecto.
-- =============================================================================

-- 4a. Tabla por barrio con todas las variables socioeconómicas + afluencia
--     La afluencia OSM viene de features_ml (que ya la tiene calculada por barrio).
--     La población adulta por barrio se deriva sumando niveles educativos.
CREATE OR REPLACE VIEW v_pbi_socioeconomico AS
SELECT
    d.id_territorio,
    d.nom_barri,
    d.nom_districte,
    -- incidentes totales del barrio
    inc.total_incidentes,
    -- renta media del barrio (media de los años disponibles)
    rent.renta_media,
    -- % población con baja educación (proporción real)
    edu.pct_baja_edu,
    -- población adulta (denominador para per cápita)
    edu.poblacion_adulta,
    -- incidentes por 1000 habitantes
    ROUND(inc.total_incidentes / NULLIF(edu.poblacion_adulta, 0) * 1000, 1) AS incidentes_per_1000
FROM dim_territorio d
JOIN (
    SELECT g.id_territorio, SUM(g.num_incidents) AS total_incidentes
    FROM fact_incidentes_gub g
    JOIN dim_tiempo t ON g.id_tiempo = t.id_tiempo
    WHERE t.mes IS NOT NULL
    GROUP BY g.id_territorio
) inc ON d.id_territorio = inc.id_territorio
LEFT JOIN (
    SELECT id_territori, AVG(valor) AS renta_media
    FROM contexto_renta_barri
    WHERE indicador = 'renta_tributaria_barri'
    GROUP BY id_territori
) rent ON d.id_territorio = rent.id_territori
LEFT JOIN (
    -- proporción real de baja educación + población adulta total, por barrio
    SELECT
        id_territori,
        AVG(pct) AS pct_baja_edu,
        AVG(pob) AS poblacion_adulta
    FROM (
        SELECT
            id_territori,
            anyo,
            SUM(CASE WHEN LOWER(categoria) LIKE '%primaria o inferior%' THEN valor ELSE 0 END)
                / NULLIF(SUM(valor), 0) * 100 AS pct,
            SUM(valor) AS pob
        FROM contexto_socioeconomico
        WHERE indicador = 'nivell_educatiu'
          AND nivel_territorial = 'barri'
        GROUP BY id_territori, anyo
    ) x
    GROUP BY id_territori
) edu ON d.id_territorio = edu.id_territori
WHERE d.nivel_territorial = 'barri'
  AND d.nom_barri <> 'Desconegut';

-- 4b. Afluencia OSM por barrio (POIs) + incidentes — soporte del sesgo de exposición
--     Fuente: tabla contexto_afluencia (14ª tabla, esquema ANCHO, cargada desde
--     data/clean/osm_afluencia_barri.csv — misma fuente que el ML). La afluencia es
--     ESTÁTICA (un valor por barrio, sin año): se une por id_territorio a nivel barrio.
--     total_incidentes = incidentes GUB acumulados del barrio (todos los años).
CREATE OR REPLACE VIEW v_pbi_afluencia_barri AS
SELECT
    a.id_territorio,
    d.nom_barri,
    a.afluencia_total,
    a.n_ocio,
    a.n_turismo,
    a.n_comercio,
    a.n_transport,
    inc.total_incidentes
FROM contexto_afluencia a
JOIN dim_territorio d ON a.id_territorio = d.id_territorio
LEFT JOIN (
    SELECT g.id_territorio, SUM(g.num_incidents) AS total_incidentes
    FROM fact_incidentes_gub g
    JOIN dim_tiempo t ON g.id_tiempo = t.id_tiempo
    WHERE t.mes IS NOT NULL
    GROUP BY g.id_territorio
) inc ON a.id_territorio = inc.id_territorio
WHERE d.nom_barri <> 'Desconegut';


-- =============================================================================
--  PÁGINA 5 — PERCEPCIÓN Y CIFRA NEGRA
--  EVB / ESPC: victimización y percepción de seguridad por año.
--  Es la nota metodológica: denunciado (facts) vs victimización real (encuestas).
-- =============================================================================

-- 5a. Índices de victimización y percepción (EVB + ESPC) por año
CREATE OR REPLACE VIEW v_pbi_percepcion AS
SELECT
    e.font,
    e.anyo,
    e.indicador,
    e.territori,
    e.valor,
    e.unitat
FROM contexto_encuestas e
WHERE e.font IN ('EVB', 'ESPC')
  AND e.indicador IS NOT NULL;

-- 5b. Comparativa denunciado vs victimización (para el gráfico de cifra negra)
--     Incidentes GUB de Barcelona por año junto al índice de victimización EVB.
CREATE OR REPLACE VIEW v_pbi_cifra_negra AS
SELECT
    t.anyo,
    SUM(g.num_incidents) AS incidentes_denunciados,
    (SELECT AVG(e.valor)
     FROM contexto_encuestas e
     WHERE e.font = 'EVB'
       AND e.anyo = t.anyo
       AND e.indicador LIKE '%victimitzaci%') AS indice_victimizacion_evb
FROM fact_incidentes_gub g
JOIN dim_tiempo t ON g.id_tiempo = t.id_tiempo
WHERE t.mes IS NOT NULL
GROUP BY t.anyo;


-- =============================================================================
--  PÁGINA 6 — MODELO ML
--  Real vs predicho y error por barrio. Viene de predicciones_ml.csv.
--  Si el CSV se carga directo en Power BI, no hace falta vista. Pero si quieres
--  servirlo desde MySQL, primero hay que cargar el CSV a una tabla. Por ahora
--  el camino más simple es importar predicciones_ml.csv directamente en Power BI.
-- =============================================================================
-- (sin vista — importar predicciones_ml.csv como tabla en Power BI)


-- =============================================================================
--  PÁGINA 7 — MAPAS DETALLADOS (puntos con filtro año + categoría/tipo)
--  Patrón de rendimiento: agregar SIEMPRE por claves ENTERAS en una subconsulta
--  y unir las etiquetas (nom_*) y el centroide DESPUÉS. Nunca agrupar por texto
--  ancho ni por la geometría LONGTEXT. Centroide: ST_Centroid sobre el WKT (SRID 0
--  basta para polígonos pequeños; deja ST_X=lon, ST_Y=lat).
-- =============================================================================

-- 7a. Mapa de puntos GUB por barrio × año × categoría de incidente (11 categorías)
--     Los 106 tipos de la GUB se agrupan en 11 categorías con un CASE sobre
--     descripcio (la collation utf8mb4_unicode_ci es insensible a acentos, por eso
--     los patrones funcionan con o sin tildes). 'Altres' es el cajón residual
--     (~5,7%, casi todo 'ALTRES ACTUACIONS DE S,C,' + 'Desconegut', no clasificables).
--     Optimizada: ~13 s (antes ~94 s con GROUP BY por texto ancho).
CREATE OR REPLACE VIEW v_pbi_mapa_detalle AS
SELECT
    base.id_territorio,
    dt.nom_barri,
    dt.nom_districte,
    cent.lat,
    cent.lon,
    base.anyo,
    base.categoria_incidente,
    base.incidentes
FROM (
    SELECT
        g.id_territorio,
        t.anyo,
        CASE
            WHEN td.descripcio LIKE '%TRÀNSIT%' OR td.descripcio LIKE '%TRANSIT%'
                 OR td.descripcio LIKE '%ESTACIONAMENT%' OR td.descripcio LIKE '%GUALS%'
                 OR td.descripcio LIKE '%INFRACCIONS EN MOVIMENT%' OR td.descripcio LIKE '%CONTROLS DE TRÀNSIT%'
                 OR td.descripcio LIKE '%SENYALS%' OR td.descripcio LIKE '%VEHICLES%'
                 OR td.descripcio LIKE '%IMMOBILITZAC%' OR td.descripcio LIKE '%CONDUCTORS%'
                 OR td.descripcio LIKE '%TRASLLATS DE VEHICLES%'
                 OR td.descripcio LIKE '%AFECTACIÓ DE VIA%' OR td.descripcio LIKE '%TRANSPORT PÚBLIC%'
                THEN 'Trànsit i mobilitat'
            WHEN td.descripcio LIKE '%CONVIVÈNCIA%' OR td.descripcio LIKE '%ACTIVITATS MOLESTES%'
                 OR td.descripcio LIKE '%VENDA AMBULANT%' OR td.descripcio LIKE '%OCUPACI%'
                 OR td.descripcio LIKE '%ESPECTACLES%' OR td.descripcio LIKE '%MOLESTIES%'
                 OR td.descripcio LIKE '%ABOCAMENT%' OR td.descripcio LIKE '%OBRES%'
                 OR td.descripcio LIKE '%VANDALISME%' OR td.descripcio LIKE '%TRIBUS URBANES%'
                THEN 'Civisme i convivència'
            WHEN td.descripcio LIKE '%PROPIETAT%' OR td.descripcio LIKE '%BARALLES%'
                 OR td.descripcio LIKE '%AGRESSIONS%' OR td.descripcio LIKE '%ESTUPEFAENTS%'
                 OR td.descripcio LIKE '%LLIBERTAT SEXUAL%' OR td.descripcio LIKE '%ATEMPTAT%'
                 OR td.descripcio LIKE '%ORDRE PÚBLIC%' OR td.descripcio LIKE '%VIOLÈNCIA%'
                 OR td.descripcio LIKE '%DRETS DELS TREBALLADORS%' OR td.descripcio LIKE '%ESTRANGERS%'
                THEN 'Seguretat i delictes'
            WHEN td.descripcio LIKE '%ASSISTÈNCIA%' OR td.descripcio LIKE '%COL·LECTIUS VULNERABLES%'
                 OR td.descripcio LIKE '%PROTECCIÓ DEL MENOR%' OR td.descripcio LIKE '%MALALTS MENTALS%'
                 OR td.descripcio LIKE '%ÀMBIT EDUCATIU%' OR td.descripcio LIKE '%CONDUCCIONS%'
                 OR td.descripcio LIKE '%PLATGES%' OR td.descripcio LIKE '%SALVAMENT%'
                THEN 'Assistència a persones'
            WHEN td.descripcio LIKE '%INCENDI%' OR td.descripcio LIKE '%FOC%'
                 OR td.descripcio LIKE '%EXPLOSI%' OR td.descripcio LIKE '%MATÈRIES PERILLOSES%'
                 OR td.descripcio LIKE '%VENTS FORTS%' OR td.descripcio LIKE '%PLUJA%'
                 OR td.descripcio LIKE '%NEU%' OR td.descripcio LIKE '%SISME%'
                 OR td.descripcio LIKE '%ALARMES%' OR td.descripcio LIKE '%SINISTRES%'
                 OR td.descripcio LIKE '%FOGUERES%' OR td.descripcio LIKE '%QUÍMICS%'
                 OR td.descripcio LIKE '%EMERGÈNCIA%'
                 OR td.descripcio LIKE '%ACCIDENT%' OR td.descripcio LIKE '%PASSAREL%' OR td.descripcio LIKE '%080%'
                THEN 'Emergències i sinistres'
            WHEN td.descripcio LIKE '%LOCALS%' OR td.descripcio LIKE '%INSPECCIONS%'
                 OR td.descripcio LIKE '%P, ADMINISTRATIVA%' OR td.descripcio LIKE '%P. ADMINISTRATIVA%'
                 OR td.descripcio LIKE '%ALIMENT%' OR td.descripcio LIKE '%EDIFICIS OFICIALS%'
                THEN 'Activitat administrativa'
            WHEN td.descripcio LIKE '%VIGILÀNCIA%' OR td.descripcio LIKE '%SUPORT%'
                 OR td.descripcio LIKE '%COL·LAB%' OR td.descripcio LIKE '%COL·LBORACIÓ%'
                 OR td.descripcio LIKE '%MANIFESTACIONS%' OR td.descripcio LIKE '%PRESOS%'
                 OR td.descripcio LIKE '%CUSTÒDIES%' OR td.descripcio LIKE '%ÒRGANS%'
                 OR td.descripcio LIKE '%AUTORITAT%'
                THEN 'Vigilància i suport'
            WHEN td.descripcio LIKE '%ANIMAL%' OR td.descripcio LIKE '%INSECTES%'
                THEN 'Animals'
            WHEN td.descripcio LIKE '%AVARIES%' OR td.descripcio LIKE '%SUBMINISTRAMENT%'
                 OR td.descripcio LIKE '%AVARIA TÈCNICA%' OR td.descripcio LIKE '%SERVEIS MUNICIPALS%'
                 OR td.descripcio LIKE '%SERVEIS PÚBLICS%'
                THEN 'Serveis i infraestructura'
            WHEN td.descripcio LIKE '%MEDI AMBIENT%' OR td.descripcio LIKE '%CAÇA%'
                 OR td.descripcio LIKE '%PESCA%' OR td.descripcio LIKE '%FLORA%' OR td.descripcio LIKE '%FAUNA%'
                THEN 'Medi ambient'
            ELSE 'Altres'
        END AS categoria_incidente,
        SUM(g.num_incidents) AS incidentes
    FROM fact_incidentes_gub g
    JOIN dim_tiempo t       ON g.id_tiempo = t.id_tiempo
    JOIN dim_tipo_delito td ON g.id_tipo_incident = td.id_tipo_delito
    WHERE t.mes IS NOT NULL
      AND g.id_territorio <> (SELECT id_territorio FROM dim_territorio WHERE nom_barri='Desconegut' LIMIT 1)
    GROUP BY g.id_territorio, t.anyo, categoria_incidente
) base
JOIN dim_territorio dt ON base.id_territorio = dt.id_territorio
JOIN (
    SELECT id_territorio,
           ST_Y(ST_Centroid(ST_GeomFromText(geometria_wgs84))) AS lat,
           ST_X(ST_Centroid(ST_GeomFromText(geometria_wgs84))) AS lon
    FROM geo_territorio WHERE nivel_territorial = 'barri'
) cent ON base.id_territorio = cent.id_territorio;

-- 7b. Mapa de puntos Mossos por ABP × año (centroide del ABP + delitos coneguts)
--     Cubre 60 de 62 ABP: 56 con centroide EXACTO (geometría de geo_territorio) + 4 con
--     centroide APROXIMADO manual (municipi/districte), porque su polígono no existe en
--     geo_territorio: 26 Horta-Guinardó, 35 l'Hospitalet, 36 el Prat, 59 Alt Camp-C.Barberà.
--     La columna tipus_centroide ('exacte'/'aproximat') permite distinguirlos en Power BI.
--     Excluidos: 'ABP Virtual' y 'ABP Barcelona' (agregados sin territorio real).
--     Cobertura: 7.407.413 coneguts = 99,6% del crimen geográficamente ubicable
--     (sobre el total bruto 8.024.398 es 92,3%; la diferencia es ABP Virtual + ABP Barcelona).
--     Para tener los 4 con polígono real: cargar el shapefile oficial de ABP (Generalitat/ICGC).
CREATE OR REPLACE VIEW v_pbi_mapa_mossos_abp AS
SELECT
    base.id_territorio,
    dt.abp,
    dt.region_policial,
    COALESCE(cent.lat, manual.lat) AS lat,
    COALESCE(cent.lon, manual.lon) AS lon,
    CASE WHEN cent.lat IS NULL THEN 'aproximat' ELSE 'exacte' END AS tipus_centroide,
    base.anyo,
    base.delitos
FROM (
    SELECT g.id_territorio, t.anyo, SUM(g.coneguts) AS delitos
    FROM fact_delitos_mossos g
    JOIN dim_tiempo t ON g.id_tiempo = t.id_tiempo
    WHERE t.mes IS NOT NULL
    GROUP BY g.id_territorio, t.anyo
) base
JOIN dim_territorio dt ON base.id_territorio = dt.id_territorio
LEFT JOIN (
    SELECT id_territorio,
           ST_Y(ST_Centroid(ST_GeomFromText(geometria_wgs84))) AS lat,
           ST_X(ST_Centroid(ST_GeomFromText(geometria_wgs84))) AS lon
    FROM geo_territorio WHERE nivel_territorial = 'abp'
) cent ON base.id_territorio = cent.id_territorio
LEFT JOIN (
    SELECT 26 AS id_territorio, 41.42916 AS lat, 2.15057 AS lon   -- ABP Horta-Guinardó
    UNION ALL SELECT 35, 41.3596, 2.0996                          -- ABP l'Hospitalet de Llobregat
    UNION ALL SELECT 36, 41.3246, 2.0947                          -- ABP el Prat de Llobregat
    UNION ALL SELECT 59, 41.2861, 1.2497                          -- ABP Alt Camp - C. de Barberà (Valls)
) manual ON base.id_territorio = manual.id_territorio
WHERE dt.abp <> 'ABP Virtual'
  AND (cent.lat IS NOT NULL OR manual.lat IS NOT NULL);          -- deja fuera 'ABP Barcelona' (sin geo ni manual)


-- =============================================================================
--  COMPROBACIÓN: listar las vistas creadas y sus filas
-- =============================================================================
-- SELECT TABLE_NAME FROM information_schema.VIEWS
--   WHERE TABLE_SCHEMA = 'criminalistica_cat' AND TABLE_NAME LIKE 'v_pbi_%';
