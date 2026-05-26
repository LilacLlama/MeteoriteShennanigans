"""
DuckDB query layer.

Opens the pre-built `meteorites.duckdb` warehouse (produced by `dbt build` —
see `dbt/`) in read-only mode. No CSV parsing at runtime; cold start is just
opening a 2 MB file.
"""

import logging
import os

import duckdb

logger = logging.getLogger(__name__)

_conn: duckdb.DuckDBPyConnection | None = None

DB_PATH = os.environ.get(
    "METEORITE_DB_PATH",
    os.path.join(os.path.dirname(__file__), "..", "data", "meteorites.duckdb"),
)


def get_conn() -> duckdb.DuckDBPyConnection:
    """Return the singleton read-only DuckDB connection."""
    global _conn
    if _conn is None:
        logger.info(f"Opening warehouse at {DB_PATH}")
        _conn = duckdb.connect(DB_PATH, read_only=True)
        count = _conn.execute("SELECT COUNT(*) FROM main_marts.meteorites").fetchone()[0]
        logger.info(f"Warehouse ready — {count:,} meteorites in main_marts.meteorites.")
    return _conn


def query(sql: str, params: list | None = None) -> list[dict]:
    """Execute a SQL query and return rows as a list of dicts."""
    conn = get_conn()
    rel = conn.execute(sql, params) if params else conn.execute(sql)
    cols = [d[0] for d in rel.description]
    rows = rel.fetchall()
    return [dict(zip(cols, row, strict=False)) for row in rows]


def get_all_points() -> list[dict]:
    """All meteorite landings, shaped for the map's marker layer."""
    return query("""
        SELECT
            id,
            name,
            latitude    AS reclat,
            longitude   AS reclong,
            recclass,
            mass_g,
            year_landed AS year,
            fall
        FROM main_marts.meteorites
        ORDER BY id
    """)


def get_meteorite(meteorite_id: int) -> dict | None:
    """Single meteorite by NASA id, or None if not found."""
    rows = query(
        """
        SELECT
            id, name, nametype, recclass, mass_g, fall,
            year_landed AS year,
            latitude    AS reclat,
            longitude   AS reclong
        FROM main_marts.meteorites
        WHERE id = ?
        """,
        [meteorite_id],
    )
    return rows[0] if rows else None


def get_h3_cells() -> list[dict]:
    """H3 density grid driving the heatmap layer."""
    return query("""
        SELECT h3_cell, count, total_mass_g, centroid_lat, centroid_lon, resolution
        FROM main_marts.meteorites_by_h3
        ORDER BY count DESC
    """)


# Magnet sizes → effective radius in km.
# Tuned so that S feels city-scale, M region-scale, L continent-slice.
MAGNET_RADII_KM = {"S": 100.0, "M": 500.0, "L": 1500.0}

# Haversine fragment reused by both queries below. `mag` and `m` are the
# CTE aliases (magnet, meteorite). DuckDB clamps acos via LEAST to avoid
# domain errors when float math rounds slightly above 1.
_HAVERSINE_KM = """
    6371.0 * acos(LEAST(1.0,
        sin(radians(m.latitude)) * sin(radians(mag.mlat)) +
        cos(radians(m.latitude)) * cos(radians(mag.mlat)) *
        cos(radians(mag.mlon - m.longitude))
    ))
"""


def get_yield(magnets: list[tuple[float, float, float]]) -> dict:
    """
    Compute the expected meteorite catch for a set of magnet placements.

    Args:
        magnets: list of (lat, lon, radius_km) tuples.

    Returns total count, total mass, year range, and the top-20 classification
    breakdown. Meteorites caught by overlapping magnets are counted once.
    """
    if not magnets:
        return {
            "summary": {"count": 0, "total_mass_g": 0.0, "year_range": [None, None]},
            "by_class": [],
        }

    conn = get_conn()
    # Numeric-only values; pydantic-validated at the route, so safe to inline.
    magnet_values = ", ".join(f"({lat}, {lon}, {r})" for lat, lon, r in magnets)

    summary_row = conn.execute(f"""
        WITH magnets(mlat, mlon, radius_km) AS (VALUES {magnet_values}),
        caught AS (
            SELECT DISTINCT m.id, m.mass_g, m.year_landed
            FROM main_marts.meteorites m
            CROSS JOIN magnets mag
            WHERE {_HAVERSINE_KM} <= mag.radius_km
        )
        SELECT
            COUNT(*),
            COALESCE(SUM(mass_g), 0),
            MIN(year_landed),
            MAX(year_landed)
        FROM caught
    """).fetchone()

    by_class_rows = conn.execute(f"""
        WITH magnets(mlat, mlon, radius_km) AS (VALUES {magnet_values}),
        caught AS (
            SELECT DISTINCT m.id, m.recclass, m.mass_g
            FROM main_marts.meteorites m
            CROSS JOIN magnets mag
            WHERE {_HAVERSINE_KM} <= mag.radius_km
        )
        SELECT recclass, COUNT(*), COALESCE(SUM(mass_g), 0)
        FROM caught
        GROUP BY recclass
        ORDER BY COUNT(*) DESC
        LIMIT 20
    """).fetchall()

    return {
        "summary": {
            "count": summary_row[0],
            "total_mass_g": float(summary_row[1]),
            "year_range": [summary_row[2], summary_row[3]],
        },
        "by_class": [
            {"recclass": r[0], "count": r[1], "total_mass_g": float(r[2])}
            for r in by_class_rows
        ],
    }
