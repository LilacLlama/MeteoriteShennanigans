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


EMPTY_YIELD = {
    "summary": {"count": 0, "total_mass_g": 0.0, "year_range": [None, None]},
    "by_class": [],
}


def get_yield(magnets: list[tuple[float, float, float]]) -> dict:
    """
    Compute the expected meteorite catch for a set of magnet placements.

    Args:
        magnets: list of (lat, lon, radius_km) tuples.

    Returns total count, total mass, year range, and the top-20 classification
    breakdown. Meteorites caught by overlapping magnets are counted once.
    """
    if not magnets:
        return EMPTY_YIELD

    lats = [lat for lat, _, _ in magnets]
    lons = [lon for _, lon, _ in magnets]
    radii = [r for _, _, r in magnets]

    # One query, one scan: pull the deduplicated caught set, then aggregate in
    # Python. Cheaper than two SQL passes and avoids any string-built SQL.
    caught = (
        get_conn()
        .execute(
            f"""
        WITH magnets(mlat, mlon, radius_km) AS (
            SELECT unnest(?), unnest(?), unnest(?)
        )
        SELECT DISTINCT m.id, m.recclass, m.mass_g, m.year_landed
        FROM main_marts.meteorites m
        CROSS JOIN magnets mag
        WHERE {_HAVERSINE_KM} <= mag.radius_km
        """,
            [lats, lons, radii],
        )
        .fetchall()
    )

    if not caught:
        return EMPTY_YIELD

    total_mass = sum(mass for _, _, mass, _ in caught if mass is not None)
    years = [year for _, _, _, year in caught if year is not None]
    year_range = [min(years), max(years)] if years else [None, None]

    by_class_agg: dict[str, list[float]] = {}
    for _, recclass, mass, _ in caught:
        agg = by_class_agg.setdefault(recclass, [0, 0.0])
        agg[0] += 1
        if mass is not None:
            agg[1] += mass

    by_class = sorted(
        ({"recclass": c, "count": int(n), "total_mass_g": m} for c, (n, m) in by_class_agg.items()),
        key=lambda row: -row["count"],
    )[:20]

    return {
        "summary": {
            "count": len(caught),
            "total_mass_g": float(total_mass),
            "year_range": year_range,
        },
        "by_class": by_class,
    }
