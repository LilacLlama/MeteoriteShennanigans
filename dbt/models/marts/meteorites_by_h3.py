"""
Meteorites bucketed into H3 hexagonal cells.

Resolution 3 (~1,400 km² per cell, ~12k cells globally) is coarse enough
to be legible at world-zoom and fine enough that Antarctica, the Sahara,
and Oman clearly stand out from the surrounding regions.

Drives the density heatmap and the magnet-yield aggregate.
"""

import h3
import pandas as pd

H3_RESOLUTION = 3


def model(dbt, session):
    dbt.config(materialized="table")

    df: pd.DataFrame = dbt.ref("stg_meteorites").df()

    df["h3_cell"] = [
        h3.latlng_to_cell(lat, lon, H3_RESOLUTION)
        for lat, lon in zip(df["latitude"], df["longitude"], strict=True)
    ]

    grouped = (
        df.groupby("h3_cell", as_index=False)
        .agg(
            count=("id", "count"),
            total_mass_g=("mass_g", "sum"),
            first_year=("year_landed", "min"),
            last_year=("year_landed", "max"),
        )
    )

    centroids = [h3.cell_to_latlng(cell) for cell in grouped["h3_cell"]]
    grouped["centroid_lat"] = [c[0] for c in centroids]
    grouped["centroid_lon"] = [c[1] for c in centroids]
    grouped["resolution"] = H3_RESOLUTION

    return grouped
