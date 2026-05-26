"""
DuckDB in-process database layer.
Loads the NASA meteorite CSV once at startup into an in-memory DuckDB instance.
"""

import logging
import os

import duckdb

logger = logging.getLogger(__name__)

_conn: duckdb.DuckDBPyConnection | None = None

DATA_PATH = os.path.join(os.path.dirname(__file__), "data", "Meteorite_Landings.csv")


def get_conn() -> duckdb.DuckDBPyConnection:
    """Return the singleton DuckDB connection, initializing if needed."""
    global _conn
    if _conn is None:
        logger.info("Initializing DuckDB and loading meteorite data...")
        _conn = duckdb.connect(":memory:")
        _conn.execute(f"""
            CREATE TABLE meteorites AS
            SELECT
                name,
                id,
                nametype,
                recclass,
                "mass (g)"          AS mass_g,
                fall,
                TRY_CAST(year AS INTEGER) AS year,
                reclat,
                reclong
            FROM read_csv_auto('{DATA_PATH}', nullstr='')
            WHERE reclat IS NOT NULL
              AND reclong IS NOT NULL
        """)
        count = _conn.execute("SELECT COUNT(*) FROM meteorites").fetchone()[0]
        logger.info(f"Loaded {count:,} meteorites into DuckDB.")
    return _conn


def query(sql: str) -> list[dict]:
    """Execute a SQL query and return rows as a list of dicts."""
    conn = get_conn()
    rel = conn.execute(sql)
    cols = [d[0] for d in rel.description]
    rows = rel.fetchall()
    return [dict(zip(cols, row, strict=False)) for row in rows]


def get_schema() -> dict:
    """Return column names and types for the meteorites table."""
    conn = get_conn()
    rows = conn.execute("""
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = 'meteorites'
        ORDER BY ordinal_position
    """).fetchall()
    return {col: dtype for col, dtype in rows}


def get_all_points() -> list[dict]:
    """Lightweight fetch of all map points (id, name, lat, lon, recclass, mass_g, year, fall)."""
    return query("""
        SELECT id, name, reclat, reclong, recclass, mass_g, year, fall
        FROM meteorites
        WHERE reclat IS NOT NULL AND reclong IS NOT NULL
        ORDER BY id
    """)
