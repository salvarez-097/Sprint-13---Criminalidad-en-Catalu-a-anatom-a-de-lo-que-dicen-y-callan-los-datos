# -*- coding: utf-8 -*-
# =============================================================================
#  Proyecto: Criminalistica Cataluna
#  Fichero : 01_cargar_datos.py
#  Objetivo: Cargar los 13 CSV de data/clean/ en la BD MySQL criminalistica_cat
#            (creada por 00_crear_base_datos.sql) usando SQLAlchemy + PyMySQL.
#
#  Conexion: utf8mb4 (caracteres catalanes). Credenciales por variables de
#            entorno; si falta la contrasena se pide por consola (getpass):
#              MYSQL_USER (def. root), MYSQL_PASSWORD, MYSQL_HOST (def. localhost),
#              MYSQL_PORT (def. 3306), MYSQL_DB (def. criminalistica_cat).
#
#  Notas:
#    - if_exists='append' (NO 'replace'): respeta el schema/charset/FK del SQL.
#    - Orden de carga FK-safe: dimensiones -> facts -> contextos -> geo.
#    - Columnas FK/enteras nullable -> Int64 (137.0/NaN entran como INT/NULL).
#    - geo_territorio: chunksize pequeno (polígonos WKT de hasta ~1,45 M chars).
#    - Consola Windows CP1252: se evitan caracteres no-ASCII en los print.
# =============================================================================

import os
import sys
import getpass
from urllib.parse import quote_plus

import pandas as pd
from sqlalchemy import create_engine, text

# --- Rutas (relativas a este script: sql/ -> ../data/clean) --------------------
SQL_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(SQL_DIR)
DATA_CLEAN = os.path.join(PROJECT, "data", "clean")

# --- Credenciales --------------------------------------------------------------
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

# Si es True, vacia las tablas (TRUNCATE, FK off) antes de cargar -> re-ejecutable.
RESET = True

# --- Orden de carga FK-safe: (tabla, fichero_csv) ------------------------------
LOAD_ORDER = [
    ("dim_tiempo",                 "dim_tiempo.csv"),
    ("dim_territorio",             "dim_territorio.csv"),
    ("dim_tipo_delito",            "dim_tipo_delito.csv"),
    ("dim_demografia",             "dim_demografia.csv"),
    ("fact_delitos_mossos",        "fact_delitos_mossos.csv"),
    ("fact_incidentes_gub",        "fact_incidentes_gub.csv"),
    ("fact_criminalidad_agregada", "fact_criminalidad_agregada.csv"),
    ("contexto_penitenciaria",     "contexto_penitenciaria.csv"),
    ("contexto_socioeconomico",    "contexto_socioeconomico.csv"),
    ("contexto_poblacion",         "contexto_poblacion.csv"),
    ("contexto_encuestas",         "contexto_encuestas.csv"),
    ("contexto_renta_barri",       "contexto_renta_barri.csv"),
    ("geo_territorio",             "geo_territorio.csv"),
]

# Columnas enteras nullable (pandas las lee como float por los NaN) -> Int64.
INT_COLS = {
    "dim_tiempo":                 ["mes", "trimestre"],
    "dim_territorio":             ["cod_barri", "cod_districte"],
    "fact_criminalidad_agregada": ["id_tipo_delito", "id_demografia"],
    "contexto_socioeconomico":    ["id_territori"],
    "contexto_poblacion":         ["id_territori"],
    "contexto_encuestas":         ["id_territori"],
    "geo_territorio":             ["codi"],
}

# Columnas de texto que vienen 100% vacias (pandas las infiere como float NaN)
# -> se fuerzan a None para que entren como NULL en las columnas VARCHAR.
TEXT_NULL_COLS = {
    "dim_demografia":       ["tipus_nacionalitat"],
    "contexto_renta_barri": ["categoria", "sexe"],
}

# chunksize por tabla (defecto 5000); geo lleva polígonos enormes.
CHUNK = {"geo_territorio": 10}
CHUNK_DEFAULT = 5000


def construir_engine():
    url = "mysql+pymysql://%s:%s@%s:%s/%s?charset=utf8mb4" % (
        DB_USER, quote_plus(DB_PASS), DB_HOST, DB_PORT, DB_NAME,
    )
    return create_engine(url)


def verificar_conexion_y_schema(engine):
    """Comprueba conexion, charset de la BD y que existan las 13 tablas."""
    print("[*] Verificando conexion y schema...")
    with engine.connect() as conn:
        charset = conn.execute(text(
            "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA "
            "WHERE SCHEMA_NAME = :db"), {"db": DB_NAME}).scalar()
        print("    BD '%s' charset = %s" % (DB_NAME, charset))
        if charset != "utf8mb4":
            print("    [AVISO] el charset de la BD no es utf8mb4.")
        existentes = set(r[0] for r in conn.execute(text(
            "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = :db"),
            {"db": DB_NAME}).fetchall())
    faltan = [t for t, _ in LOAD_ORDER if t not in existentes]
    if faltan:
        print("    [ERROR] faltan tablas en la BD: %s" % faltan)
        print("            Ejecuta antes 00_crear_base_datos.sql.")
        sys.exit(1)
    print("    OK: las 13 tablas existen.")


def reset_tablas(engine):
    """Vacia todas las tablas (FK off, orden inverso) para una carga limpia."""
    print("[*] RESET: vaciando tablas (TRUNCATE)...")
    with engine.begin() as conn:
        conn.execute(text("SET FOREIGN_KEY_CHECKS = 0"))
        for tabla, _ in reversed(LOAD_ORDER):
            conn.execute(text("TRUNCATE TABLE %s" % tabla))
        conn.execute(text("SET FOREIGN_KEY_CHECKS = 1"))
    print("    OK: tablas vacias.")


def preparar_df(tabla, df):
    """Ajusta tipos antes de insertar: enteros nullable -> Int64; vacias -> None."""
    for col in INT_COLS.get(tabla, []):
        if col in df.columns:
            df[col] = df[col].astype("Int64")
    for col in TEXT_NULL_COLS.get(tabla, []):
        if col in df.columns:
            df[col] = df[col].astype("object").where(df[col].notna(), None)
    return df


def cargar(engine):
    print("[*] Cargando CSV -> MySQL (if_exists='append')...")
    leidos = {}
    for tabla, fichero in LOAD_ORDER:
        ruta = os.path.join(DATA_CLEAN, fichero)
        df = pd.read_csv(ruta, low_memory=False, encoding="utf-8")
        df = preparar_df(tabla, df)
        leidos[tabla] = len(df)
        df.to_sql(tabla, engine, if_exists="append", index=False,
                  chunksize=CHUNK.get(tabla, CHUNK_DEFAULT))
        print("    [OK] %-28s %8d filas" % (tabla, len(df)))
    return leidos


def verificar_conteos(engine, leidos):
    print("[*] Verificacion final (CSV vs BD):")
    print("    %-28s %10s %10s  %s" % ("tabla", "csv", "bd", "estado"))
    total_csv = total_bd = 0
    todo_ok = True
    with engine.connect() as conn:
        for tabla, _ in LOAD_ORDER:
            n_bd = conn.execute(text("SELECT COUNT(*) FROM %s" % tabla)).scalar()
            n_csv = leidos.get(tabla, -1)
            ok = (n_bd == n_csv)
            todo_ok = todo_ok and ok
            total_csv += n_csv
            total_bd += n_bd
            print("    %-28s %10d %10d  %s" % (tabla, n_csv, n_bd, "[OK]" if ok else "[FALLO]"))
    print("    %-28s %10d %10d  %s" % ("TOTAL", total_csv, total_bd,
                                       "[OK]" if total_csv == total_bd else "[FALLO]"))
    print("\n[RESULTADO] %s" % ("CARGA COMPLETA Y COHERENTE." if todo_ok
                                 else "Hay discrepancias, revisar."))


def main():
    engine = construir_engine()
    verificar_conexion_y_schema(engine)
    if RESET:
        reset_tablas(engine)
    leidos = cargar(engine)
    verificar_conteos(engine, leidos)


if __name__ == "__main__":
    main()
