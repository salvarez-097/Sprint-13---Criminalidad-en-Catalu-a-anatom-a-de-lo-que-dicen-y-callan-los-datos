# Criminalidad en Cataluña: anatomía de lo que dicen (y callan) los datos 🔍

**De 500+ archivos en bruto a un dashboard interactivo, pasando por un modelo predictivo.**

Proyecto final del bootcamp de Data Analytics (IT Academy, Barcelona). Combina ingeniería de datos, análisis estadístico, machine learning y visualización, con un enfoque en la **honestidad metodológica**: no solo *qué* dicen los datos, sino *qué no pueden decir*.

---

## 🎯 De qué va

El proyecto analiza la criminalidad en Cataluña y, con más detalle, en los barrios de Barcelona, cruzando datos policiales con contexto socioeconómico, encuestas de victimización y datos de afluencia urbana.

El hilo conductor es una pregunta aparentemente simple —*¿dónde y por qué hay más delincuencia?*— cuya respuesta resulta contraintuitiva y obliga a corregir un sesgo que está presente en muchos análisis de criminalidad.

### Los cuatro hallazgos clave

1. **Sesgo de exposición.** A primera vista, los barrios con más renta tienen *más* incidentes (correlación +0,33), lo cual no tiene sentido. La explicación: los barrios céntricos y turísticos (Raval, Gòtic, Eixample) acumulan incidentes porque por ellos **transita** mucha gente, no porque vivan personas más conflictivas. Al normalizar por población residente, la correlación con la renta **desaparece** (−0,04). Se confirma de cuatro formas independientes: per cápita, datos de afluencia de OpenStreetMap (+0,89), regresión OLS y la importancia de variables del modelo de ML.

2. **Cifra negra.** Los datos de Mossos y Guardia Urbana solo recogen delitos *denunciados*. Según la Encuesta de Victimización, alrededor del **80% de los delitos reales nunca se denuncian**. Es decir, los datos policiales miden actividad policial y denuncias, no criminalidad real.

3. **Tendencia estable.** Pese a la percepción habitual, la tasa de criminalidad per cápita **no muestra una tendencia creciente significativa** (test de Mann-Kendall, p=0,66). El único movimiento brusco es la caída del confinamiento de 2020.

4. **El modelo simple gana al complejo.** Un baseline ingenuo ("este mes habrá lo mismo que el anterior") predice mejor (MAE 57) que Random Forest (93) o XGBoost (74), porque la criminalidad de cada barrio es muy estable mes a mes. El valor del machine learning aquí no está en la predicción pura, sino en *entender* qué variables explican el crimen y dónde se concentra.

---

## 🏗️ Arquitectura del proyecto

```
Fuentes (500+ archivos)
   │  Mossos d'Esquadra · Guardia Urbana · Idescat · INE · Open Data Barcelona
   ▼
ETL en Python ──────────► MySQL (star schema, 14 tablas)
   │                         4 dimensiones + 3 tablas de hechos + contexto
   ▼
Análisis (Jupyter)
   ├── 08 · EDA (exploración y detección de patrones)
   ├── 09 · Estadístico (tests formales + afluencia OSM)
   └── 10 · Machine Learning (Random Forest, XGBoost, Prophet)
   │
   ▼
14 vistas SQL ──────────► Dashboard Power BI (6 páginas interactivas)
```

### Stack técnico

| Capa | Herramientas |
|------|--------------|
| **Ingesta / ETL** | Python (pandas), MySQL |
| **Base de datos** | MySQL 8 (esquema en estrella, InnoDB, utf8mb4) |
| **Análisis** | Jupyter, pandas, scipy, statsmodels, scikit-learn |
| **Geo** | shapely, geopandas, osmnx (OpenStreetMap) |
| **Machine Learning** | scikit-learn (Random Forest), XGBoost, Prophet |
| **Visualización** | Power BI (conexión directa a MySQL, mapas de Azure) |

---

## 📁 Estructura del repositorio

```
criminalistica_cat/
├── notebooks/                      # ETL: datos crudos → CSV limpios (8 notebooks)
│   ├── 01_etl_dimensiones.ipynb
│   ├── 02_etl_mossos.ipynb
│   ├── 03_etl_gub_barcelona.ipynb
│   ├── 04_etl_ministerio_ine.ipynb
│   ├── 05_etl_penitenciaria.ipynb
│   ├── 06_etl_socioeconomico.ipynb
│   ├── 07_etl_encuestas.ipynb
│   └── 08_etl_geo_renta_barri.ipynb
│
├── sql/                            # Creación de la BD, carga y vistas
│   ├── 00_crear_base_datos.sql     # Esquema en estrella (14 tablas)
│   ├── 01_cargar_datos.py          # Carga de los CSV limpios a MySQL
│   ├── 02_crear_contexto_afluencia.sql
│   ├── 02_cargar_afluencia.py      # Loader de afluencia OSM (esquema ancho)
│   └── vistas_powerbi.sql          # Las 14 vistas del dashboard
│
├── analisis/                       # Análisis y modelado
│   ├── 08_eda.ipynb                # Análisis exploratorio
│   ├── 09_analisis_estadistico.ipynb
│   └── 10_modelo_ml.ipynb          # Modelado predictivo
│
├── data/
│   ├── clean/                      # CSVs procesados (salida del ETL + ML)
│   └── raw/                        # Datos crudos (~551 archivos, 9 fuentes)
│
├── dashboard/
│   └── criminalistica_cat_dashboards.pbix   # Dashboard (6 páginas)
│
├── docs/                           # Geometrías y material de apoyo
│
├── web/   · app/                   # Líneas futuras (ver más abajo)
│
├── requirements.txt                # Dependencias Python
└── README.md
```

> Las carpetas `api/`, `chatbot/`, `web/` y `app/` corresponden a las líneas futuras (web y app); quedan fuera del pipeline de datos actual.

---

## 📊 El dashboard (6 páginas)

Conectado directamente a MySQL mediante 14 vistas SQL agregadas. Cada página refleja un bloque del análisis, pensado para que alguien sin conocimientos técnicos pueda explorar los hallazgos.

1. **Visión general** — KPIs y evolución temporal (con las líneas de la reforma penal de 2015 y el COVID).
2. **Geografía** — Dos mapas interactivos: Cataluña por área policial (Mossos) y Barcelona por barrio (Guardia Urbana). El sesgo de exposición, hecho visual.
3. **Tipología y demografía** — Qué delitos predominan y perfil demográfico de las detenciones.
4. **Socioeconómico** — El hallazgo estrella: la correlación renta-incidentes que se desvanece al normalizar, frente a la afluencia que sí explica.
5. **Percepción y cifra negra** — Datos denunciados frente a victimización real autopercibida.
6. **Modelo predictivo** — Predicción frente a realidad, error por barrio y métricas de los modelos.

---

## 🔬 Notas metodológicas

Lo que distingue este proyecto no son los modelos, sino el **criterio aplicado a los datos**:

- **Cada fuente se usa en su granularidad natural.** Guardia Urbana opera a nivel de barrio de Barcelona; Mossos, a nivel de área básica policial de toda Cataluña; el Ministerio, a nivel autonómico. No se fuerzan cruces entre niveles incompatibles.
- **Tasa per cápita, no valores absolutos**, para comparar de forma justa años con poblaciones distintas y barrios de distinto tamaño.
- **Tests no paramétricos** (Mann-Kendall, Mann-Whitney, Spearman), porque los datos no siguen una distribución normal.
- **Detección y corrección de multicolinealidad** (VIF) en la regresión.
- **Limitaciones reconocidas, no escondidas**: la afluencia de OpenStreetMap es un *proxy* (mejor mapeado en el centro que en la periferia); 4 áreas policiales usan centroide aproximado de municipio (marcado explícitamente); la reforma penal de 2015 afecta a la comparación de series.

---

## ⚠️ Limitaciones y variables no incluidas

Un análisis honesto reconoce sus límites. Estos son los principales:

- **Datos denunciados, no criminalidad real.** Las fuentes policiales recogen denuncias y detenciones, no delitos cometidos. Con una cifra negra estimada del ~80%, el análisis describe la criminalidad *registrada*, no la real.
- **Sesgo de selección en los datos.** Una zona o un colectivo más vigilado aparece más en las estadísticas aunque no delinca más. Por eso el proyecto evita conclusiones causales sobre *quién* comete delitos y se centra en patrones espaciales y temporales.
- **Variables socioeconómicas que faltan o no son medibles.** Factores como la situación administrativa de las personas no existen como estadística pública fiable ligada a datos delictivos, y su uso sería metodológicamente incorrecto. Además, cualquier correlación de ese tipo caería en el mismo **sesgo de exposición** que el proyecto demuestra con la renta: reflejaría afluencia y densidad, no causalidad. El análisis trabaja deliberadamente solo con variables de datos fiables (renta, educación, afluencia, densidad).
- **La afluencia es un proxy.** Se mide con puntos de interés de OpenStreetMap, mejor mapeados en el centro que en la periferia, lo que puede inflar el indicador en zonas céntricas.
- **Cobertura geográfica.** Cuatro áreas básicas policiales usan un centroide aproximado de municipio (marcado explícitamente) por no disponer de su polígono oficial.
- **Granularidades distintas entre fuentes.** Guardia Urbana (barrio), Mossos (área policial) y Ministerio (autonómico) no son directamente comparables en valor absoluto y se analizan por separado.

La conclusión del proyecto es, por tanto, prudente: identifica **dónde** se concentran los incidentes y **por qué** (afluencia), sin atribuir causalidad a características de las personas.

## 🚀 Líneas futuras

El proyecto está planteado de forma modular para poder crecer. Próximos pasos:

- **Aplicación web** — Llevar el análisis a una web interactiva, accesible sin Power BI, para consulta pública.
- **Aplicación móvil** — Versión para dispositivos móviles centrada en la consulta rápida por zona.
- **Importancia de variables en el dashboard** — Exportar el gráfico de feature importance del notebook 10 a una página del dashboard.
- **Geometrías completas de ABP** — Incorporar los polígonos oficiales de las 4 áreas policiales que faltan, para un mapa de Cataluña con cobertura total.
- **Actualización automática** — Pipeline para incorporar nuevos datos a medida que las fuentes publiquen ejercicios más recientes.

---

## 📐 Datos y alcance

- **Periodo analizado:** 2013–2024 (ventana donde coinciden todas las fuentes fiables; datos disponibles 2010–2025).
- **Cobertura:** Cataluña (datos de Mossos) y 73 barrios de Barcelona (datos de Guardia Urbana).
- **Volumen:** ~1 millón de registros tras el ETL, sobre 25 conjuntos de datos activos.
- **Fuentes:** Mossos d'Esquadra, Guardia Urbana de Barcelona, Idescat, INE, Open Data Barcelona, OpenStreetMap.

---

## ⚙️ Cómo reproducirlo

1. **Instalar dependencias:** `pip install -r requirements.txt`
2. **ETL:** ejecutar los notebooks de `notebooks/` (01 a 08) para procesar los datos crudos de `data/raw/` en los CSV limpios de `data/clean/`.
3. **Crear la base de datos:** ejecutar `sql/00_crear_base_datos.sql` en MySQL.
4. **Cargar los datos:** ejecutar `sql/01_cargar_datos.py` y `sql/02_cargar_afluencia.py` (configurar antes las credenciales mediante variable de entorno, nunca en el código).
5. **Crear las vistas:** ejecutar `sql/vistas_powerbi.sql`.
6. **Análisis:** abrir los notebooks de `analisis/` (08 EDA, 09 estadístico, 10 ML).
7. **Dashboard:** abrir `dashboard/criminalistica_cat_dashboards.pbix` y actualizar la conexión a MySQL.

---

*Proyecto desarrollado como Trabajo Final del bootcamp de Data Analytics — IT Academy, Barcelona.*

---

## 📚 Fuentes de datos

- **Mossos d'Esquadra** — Datos de criminalidad registrada en Cataluña (2011–2025). Departament d'Interior, Generalitat de Catalunya. Disponible en https://mossos.gencat.cat/es/els_mossos_desquadra/indicadors_i_qualitat/dades_obertes/ y https://analisi.transparenciacatalunya.cat. Consultado en mayo de 2026.
- **Guàrdia Urbana de Barcelona** — Incidentes gestionados (2010–2025). Ajuntament de Barcelona, Open Data BCN. https://opendata-ajuntament.barcelona.cat/es. Consultado en mayo de 2026.
- **Idescat** — Institut d'Estadística de Catalunya (padrón, renta, nivel educativo, paro). https://www.idescat.cat. Consultado en mayo de 2026.
- **INE** — Instituto Nacional de Estadística (datos demográficos y socioeconómicos filtrados para Cataluña). https://www.ine.es. Consultado en mayo de 2026.
- **Open Data BCN** — Portal de datos abiertos del Ajuntament de Barcelona (renta tributaria, unidades administrativas, geometrías de barrios). https://opendata-ajuntament.barcelona.cat/es. Consultado en mayo de 2026.
- **Encuestas de seguridad y victimización:**
  - **EVB** — Enquesta de Victimització de Barcelona (1983–2025). Ajuntament de Barcelona. https://ajuntament.barcelona.cat/seguretatiprevencio/es/documentacion/encuesta-de-victimizacion-de-barcelona. Consultado en mayo de 2026.
  - **ESPC** — Enquesta de Seguretat Pública de Catalunya. Departament d'Interior, Generalitat de Catalunya. https://interior.gencat.cat/es/el_departament/publicacions/seguretat/estudis-i-enquestes/enquesta_de_seguretat_publica_de_catalunya/ y https://analisi.transparenciacatalunya.cat. Consultado en mayo de 2026.
  - **ISC** — Informe de Seguretat de Catalunya. Departament d'Interior, Generalitat de Catalunya. https://interior.gencat.cat. Consultado en mayo de 2026.
- **Ministerio del Interior** — Portal estadístico de criminalidad (hechos conocidos, detenciones). https://estadisticasdecriminalidad.ses.mir.es. Consultado en mayo de 2026.
- **OpenStreetMap** — Datos de puntos de interés, vía la librería OSMnx. © OpenStreetMap contributors, disponibles bajo licencia ODbL. https://www.openstreetmap.org. Consultado en mayo de 2026.

> Los datos geográficos de áreas básicas policiales proceden del ICGC (Institut Cartogràfic i Geològic de Catalunya). Las licencias de reutilización de cada fuente se indican en sus respectivos portales.
