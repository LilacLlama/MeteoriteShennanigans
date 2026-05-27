"""
Meteorites bucketed into S2 cells at multiple levels.

Emits rows at levels 3, 4, 5, 6, 7 in a single materialised table. Each
(level, s2_cell) row carries its own count, masses, centroid, and 4-vertex
boundary — so the frontend renders any level without doing rollup logic
client-side. The active level is selected based on map zoom.

Approximate cell sizes:
  level 3  ~1,600,000 km²  (continent slice)        → world zoom
  level 4    ~400,000 km²  (large country)          → continent zoom
  level 5    ~100,000 km²  (small country / region) → country zoom
  level 6     ~25,000 km²  (state-sized)            → region zoom
  level 7      ~6,000 km²  (large metro / county)   → metro zoom

S2 is a perfect quadtree — sum of any cell's 4 children at level N+1
exactly equals the parent at level N. So this is genuinely the SAME
aggregate computed at four granularities, not four independent estimates.
The rollup property is the whole reason we picked S2 over H3.

Cell IDs are hex tokens (strings) because the underlying int64 loses
precision in JavaScript `Number` (>2^53). Tokens at different levels are
globally distinct (different bit-encodings), so the single `s2_cell`
column remains unique across the whole table.

`iron_mass_g` is sourced from `int_meteorites_with_iron` (same intermediate
as `meteorites_by_class`, so both marts agree on the iron-content
definition by construction).
"""

import pandas as pd
import s2sphere

LEVELS = (3, 4, 5, 6, 7)


def _cell_token(lat: float, lon: float, level: int) -> str:
    latlng = s2sphere.LatLng.from_degrees(lat, lon)
    return s2sphere.CellId.from_lat_lng(latlng).parent(level).to_token()


def _centroid(token: str) -> tuple[float, float]:
    centre = s2sphere.CellId.from_token(token).to_lat_lng()
    return centre.lat().degrees, centre.lng().degrees


def _boundary(token: str) -> tuple[list[float], list[float]]:
    """Four-vertex boundary of the S2 cell. Returned as parallel lat/lon
    arrays — simpler to materialise in DuckDB than a list of structs."""
    cell = s2sphere.Cell(s2sphere.CellId.from_token(token))
    lats, lons = [], []
    for k in range(4):
        ll = s2sphere.LatLng.from_point(cell.get_vertex(k))
        lats.append(ll.lat().degrees)
        lons.append(ll.lng().degrees)
    return lats, lons


def _aggregate_at_level(df: pd.DataFrame, level: int) -> pd.DataFrame:
    tokens = [
        _cell_token(lat, lon, level)
        for lat, lon in zip(df["latitude"], df["longitude"], strict=True)
    ]
    work = df.assign(s2_cell=tokens)

    grouped = work.groupby("s2_cell", as_index=False).agg(
        count=("id", "count"),
        total_mass_g=("mass_g", "sum"),
        iron_mass_g=("iron_mass_g", "sum"),
        first_year=("year_landed", "min"),
        last_year=("year_landed", "max"),
    )

    centroids = [_centroid(t) for t in grouped["s2_cell"]]
    grouped["centroid_lat"] = [c[0] for c in centroids]
    grouped["centroid_lon"] = [c[1] for c in centroids]

    boundaries = [_boundary(t) for t in grouped["s2_cell"]]
    grouped["boundary_lats"] = [b[0] for b in boundaries]
    grouped["boundary_lons"] = [b[1] for b in boundaries]

    grouped["level"] = level
    return grouped


def model(dbt, session):
    dbt.config(materialized="table")

    df: pd.DataFrame = dbt.ref("int_meteorites_with_iron").df()

    per_level = [_aggregate_at_level(df, level) for level in LEVELS]
    return pd.concat(per_level, ignore_index=True)
