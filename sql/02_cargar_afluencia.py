# -*- coding: utf-8 -*-
# =============================================================================
#  Proyecto: Criminalistica Cataluna
#  Fichero : 02_cargar_afluencia.py
#  Objetivo: Crear (esquema ANCHO) y cargar la tabla contexto_afluencia (14a tabla)
#            desde data/clean/osm_afluencia_barri.csv. SIN Overpass.
#
#  Uso:
#    python sql/02_cargar_afluencia.py
#
#  Reemplaza a 02_cargar_afluencia_osm.py (OBSOLETO: buscaba un cache largo
#  data/clean/contexto_afluencia.csv que nunca se genero -> habria descargado de
#  Overpass y producido el formato largo viejo). Este loader usa el CSV ANCHO de
#  nb09 (la misma fuente que features_ml.csv / el modelo ML).
#
#  Flujo:
#    1. Ejecuta sql/02_crear_contexto_afluencia.sql (DROP + CREATE, esquema ancho).
#    2. Carga osm_afluencia_barri.csv (6 columnas) con pandas.to_sql.
#    3. Verifica: 73 barrios y afluencia_total == suma de los 4 POIs.
#
#  Credenciales por variables de entorno (igual que 01_cargar_datos.py):
#    MYSQL_USER (def. root), MYSQL_PASSWORD, MYSQL_HOST (def. localhost),
#    MYSQL_PORT (def. 3306), MYSQL_DB (def. criminalistica_cat).
#  Consola Windows CP1252: se evitan caracteres no-ASCII en los print().
# =============================================================================

import os
import sys
import getpass
from urllib.parse import quote_plus

import pandas as pd
from sqlalchemy import create_engine, text

# --- Rutas -------------------------------------------------------------------
SQL_DIR    = os.path.dirname(os.path.abspath(__file__))
PROJECT    = os.path.dirname(SQL_DIR)
CSV_PATH   = os.path.join(PROJECT, "data", "clean", "osm_afluencia_barri.csv")
DDL_PATH   = os.path.join(SQL_DIR, "02_crear_contexto_afluencia.sql")

COLS = ["id_territorio", "n_ocio", "n_turismo", "n_comercio", "n_transport", "afluencia_total"]

# --- Credenciales ------------------------------------------------------------
DB_USER = os.environ.get("MYSQL_USER", "root")
DB_HOST = os.environ.get("MYSQL_HOST", "localhost")
DB_PORT = os.environ.get("MYSQL_PORT", "3306")
DB_NAME = os.environ.get("MYSQL_DB", "criminalistica_cat")
# IMPORTANTE: define la variable de entorno MYSQL_PASSWORD ANTES de ejecutar este script.
#   PowerShell:  $env:MYSQL_PASSWORD = "tu_password"
#   Bash:        export MYSQL_PASSWORD="tu_password"
# La contrasena NUNCA debe escribirse en el codigo. Si la variable no esta definida,
# se pedira por consola de forma segura (getpass).
DB_PASS = os.environ.get("MYSQL_PASSWORD")
if DB_PASS is None:
    DB_PASS = getpass.getpass("Password MySQL para %s@%s: " % (DB_USER, DB_HOST))


def construir_engine():
    url = "mysql+pymysql://%s:%s@%s:%s/%s?charset=utf8mb4" % (
        DB_USER, quote_plus(DB_PASS), DB_HOST, DB_PORT, DB_NAME,
    )
    return create_engine(url)


def ejecutar_ddl(engine):
    """Ejecuta 02_crear_contexto_afluencia.sql (DROP + CREATE, idempotente)."""
    print("[1] Creando tabla contexto_afluencia (esquema ancho)...")
    with open(DDL_PATH, encoding="utf-8") as f:
        script = f.read()
    # Quitar comentarios -- y dividir por ';'; descartar vacios y la sentencia USE
    sin_com = "\n".join(l.split("--", 1)[0] for l in script.splitlines())
    stmts = [s.strip() for s in sin_com.split(";")
             if s.strip() and not s.strip().upper().startswith("USE")]
    with engine.begin() as conn:
        for s in stmts:
            conn.execute(text(s))
    print("    [OK] tabla creada (%d sentencias)." % len(stmts))


def cargar_csv(engine):
    print("[2] Cargando %s ..." % os.path.basename(CSV_PATH))
    if not os.path.exists(CSV_PATH):
        print("    [ERROR] No existe el CSV: %s" % CSV_PATH)
        print("            Generarlo primero ejecutando 09_analisis_estadistico.ipynb (seccion S0).")
        sys.exit(1)
    df = pd.read_csv(CSV_PATH)
    faltan = [c for c in COLS if c not in df.columns]
    if faltan:
        print("    [ERROR] Faltan columnas en el CSV: %s" % faltan)
        sys.exit(1)
    df[COLS].to_sql("contexto_afluencia", engine,
                    if_exists="append", index=False, chunksize=1000)
    print("    [OK] %d filas cargadas." % len(df))
    return df


def validar(engine):
    print("[3] Validacion:")
    with engine.connect() as conn:
        n = conn.execute(text("SELECT COUNT(*) FROM contexto_afluencia")).scalar()
        descuadre = conn.execute(text(
            "SELECT COUNT(*) FROM contexto_afluencia "
            "WHERE n_ocio + n_turismo + n_comercio + n_transport <> afluencia_total"
        )).scalar()
        suma = conn.execute(text("SELECT SUM(afluencia_total) FROM contexto_afluencia")).scalar()
    print("    Barrios               : %d (esperado 73)" % n)
    print("    afluencia_total OK    : %s (filas descuadradas: %d)" % (descuadre == 0, descuadre))
    print("    Suma afluencia_total  : %d" % suma)
    ok = (n == 73 and descuadre == 0)
    print("    [%s] contexto_afluencia %s." % ("OK" if ok else "AVISO",
          "cargada correctamente" if ok else "cargada CON AVISOS"))
    return ok


def main():
    engine = construir_engine()
    with engine.connect() as conn:
        tablas = set(r[0] for r in conn.execute(text(
            "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = :db"
        ), {"db": DB_NAME}).fetchall())
    if "dim_territorio" not in tablas:
        print("[ERROR] La BD '%s' no contiene dim_territorio." % DB_NAME)
        print("        Ejecuta 00_crear_base_datos.sql y 01_cargar_datos.py primero.")
        sys.exit(1)
    ejecutar_ddl(engine)
    cargar_csv(engine)
    validar(engine)
    print("[FIN] contexto_afluencia lista. Vista: v_pbi_afluencia_barri (vistas_powerbi.sql).")


if __name__ == "__main__":
    main()
