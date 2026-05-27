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


def get_s2_cells(level: int = 5) -> list[dict]:
    """S2 density grid at the requested level (3..7)."""
    return query(
        """
        SELECT
            s2_cell, count, total_mass_g, iron_mass_g,
            centroid_lat, centroid_lon,
            boundary_lats, boundary_lons,
            level
        FROM main_marts.meteorites_by_s2
        WHERE level = ?
        ORDER BY count DESC
        """,
        [level],
    )


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
    "summary": {
        "count": 0,
        "catchable_count": 0,
        "total_mass_g": 0.0,
        "iron_mass_g": 0.0,
        "year_range": [None, None],
    },
    "by_class": [],
}


def get_yield(magnets: list[tuple[float, float, float]]) -> dict:
    """
    Compute the expected meteorite catch for a set of magnet placements.

    Args:
        magnets: list of (lat, lon, radius_km) tuples.

    Returns:
        summary.count            — meteorites geographically inside any radius
        summary.catchable_count  — subset whose class has non-zero metal content
        summary.total_mass_g     — bulk mass of all caught meteorites
        summary.iron_mass_g      — physically meaningful yield: sum of
                                   mass_g * metal_fraction_pct / 100
        summary.year_range       — [first, last] year landed (None if all unknown)
        by_class                 — full per-class_group breakdown (no top-N cap;
                                   there are only ~35 class groups). Each row
                                   carries magnetic_tier, count, total_mass_g,
                                   iron_mass_g so the frontend can sort by any
                                   field. Default sort is (iron_mass_g desc,
                                   count desc) — deterministic for tests.

    Meteorites caught by overlapping magnets are counted once.
    """
    if not magnets:
        return EMPTY_YIELD

    lats = [lat for lat, _, _ in magnets]
    lons = [lon for _, lon, _ in magnets]
    radii = [r for _, _, r in magnets]

    # Query through `int_meteorites_with_iron` so the runtime yield and the
    # offline heatmap mart share one definition of iron_mass_g. The
    # intermediate is materialised as a view, so query cost is identical to
    # the raw join. The `magnetic_tier IS NOT NULL` filter is defensive
    # against the relationships test getting disabled or the `unknown` seed
    # row going missing — under normal conditions it's a no-op since every
    # class_group has a dim row.
    caught = (
        get_conn()
        .execute(
            f"""
        WITH magnets(mlat, mlon, radius_km) AS (
            SELECT unnest(?), unnest(?), unnest(?)
        )
        SELECT DISTINCT
            m.id,
            m.class_group,
            m.magnetic_tier,
            m.mass_g,
            m.iron_mass_g,
            m.year_landed
        FROM main_intermediate.int_meteorites_with_iron m
        CROSS JOIN magnets mag
        WHERE m.magnetic_tier IS NOT NULL
          AND {_HAVERSINE_KM} <= mag.radius_km
        """,
            [lats, lons, radii],
        )
        .fetchall()
    )

    if not caught:
        return EMPTY_YIELD

    total_mass = sum(mass for _, _, _, mass, _, _ in caught if mass is not None)
    total_iron = sum(iron for _, _, _, _, iron, _ in caught if iron is not None)
    catchable_count = sum(1 for _, _, tier, _, _, _ in caught if tier != "none")
    years = [year for _, _, _, _, _, year in caught if year is not None]
    year_range = [min(years), max(years)] if years else [None, None]

    # Aggregate by class_group; tier is a function of class_group so it's
    # safe to carry the first tier seen for each group.
    by_class_agg: dict[str, list] = {}
    for _, class_group, tier, mass, iron, _ in caught:
        agg = by_class_agg.setdefault(class_group, [tier, 0, 0.0, 0.0])
        agg[1] += 1
        if mass is not None:
            agg[2] += mass
        if iron is not None:
            agg[3] += iron

    by_class = sorted(
        (
            {
                "class_group": cg,
                "magnetic_tier": tier,
                "count": int(n),
                "total_mass_g": float(m),
                "iron_mass_g": float(i),
            }
            for cg, (tier, n, m, i) in by_class_agg.items()
        ),
        key=lambda row: (-row["iron_mass_g"], -row["count"]),
    )

    return {
        "summary": {
            "count": len(caught),
            "catchable_count": catchable_count,
            "total_mass_g": float(total_mass),
            "iron_mass_g": float(total_iron),
            "year_range": year_range,
        },
        "by_class": by_class,
    }
