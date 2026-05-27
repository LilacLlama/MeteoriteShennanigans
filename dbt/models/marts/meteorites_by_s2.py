"""
Meteorites bucketed into S2 cells.

S2 level 5 gives ~5,500 cells globally (~100,000 km² per cell on average) —
coarse enough to be legible at world zoom and fine enough that Antarctica,
the Sahara, and Oman clearly stand out.

S2 is a perfect quadtree: every cell has exactly 4 children at the next
level, so a coarser-level view is the exact sum of its 4 children — no
overlap, no pentagon edge cases (unlike H3). The hex `to_token()` form is
both compact and a prefix of its children's tokens, so future hierarchical
rollups can be done by string prefix.

Cell IDs are stored as STRINGS (hex tokens) because the underlying int64
loses precision in JavaScript `Number` (>2^53). The string form is the
safe end-to-end shape across Python, DuckDB, JSON, and JS.

`iron_mass_g` comes pre-computed from `int_meteorites_with_iron` (same
intermediate that feeds `meteorites_by_class`, so both marts agree on
the iron-content definition by construction). Rows with no class_group
match contribute 0 iron mass but still count in `count`, so the heatmap
can colour by either "density of landings" or "actual magnet-catchable
mass."
"""

import pandas as pd
import s2sphere

S2_LEVEL = 5


def _cell_token(lat: float, lon: float) -> str:
    latlng = s2sphere.LatLng.from_degrees(lat, lon)
    return s2sphere.CellId.from_lat_lng(latlng).parent(S2_LEVEL).to_token()


def _centroid(token: str) -> tuple[float, float]:
    centre = s2sphere.CellId.from_token(token).to_lat_lng()
    return centre.lat().degrees, centre.lng().degrees


def _boundary(token: str) -> tuple[list[float], list[float]]:
    """Four-vertex boundary of the S2 cell. Returned as parallel lat/lon
    arrays — simpler to materialise in DuckDB than a list of structs.
    Order is consistent across cells, so the frontend can polygon-close
    by re-appending the first vertex."""
    cell = s2sphere.Cell(s2sphere.CellId.from_token(token))
    lats, lons = [], []
    for k in range(4):
        ll = s2sphere.LatLng.from_point(cell.get_vertex(k))
        lats.append(ll.lat().degrees)
        lons.append(ll.lng().degrees)
    return lats, lons


def model(dbt, session):
    dbt.config(materialized="table")

    df: pd.DataFrame = dbt.ref("int_meteorites_with_iron").df()

    df["s2_cell"] = [
        _cell_token(lat, lon) for lat, lon in zip(df["latitude"], df["longitude"], strict=True)
    ]

    grouped = df.groupby("s2_cell", as_index=False).agg(
        count=("id", "count"),
        total_mass_g=("mass_g", "sum"),
        iron_mass_g=("iron_mass_g", "sum"),
        first_year=("year_landed", "min"),
        last_year=("year_landed", "max"),
    )

    centroids = [_centroid(token) for token in grouped["s2_cell"]]
    grouped["centroid_lat"] = [c[0] for c in centroids]
    grouped["centroid_lon"] = [c[1] for c in centroids]

    boundaries = [_boundary(token) for token in grouped["s2_cell"]]
    grouped["boundary_lats"] = [b[0] for b in boundaries]
    grouped["boundary_lons"] = [b[1] for b in boundaries]

    grouped["level"] = S2_LEVEL

    return grouped
