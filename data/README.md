# `data/`

The CSV source-of-truth + the dbt-built DuckDB warehouse. **Read-only at
runtime** — the warehouse is rebuilt from the CSV by `make dbt-build`.

## Files

- `Meteorite_Landings.csv` — NASA Open Data Portal raw dump (45,716 rows, checked in)
- `Meteorite_Landings.json` — same data in JSON form, kept for reference; not used at runtime
- `meteorites.duckdb` — built by `dbt build`. **Gitignored.** Run `make dbt-build` to (re)produce it

---

## Connecting

### Option A: Python REPL (works out of the box — `duckdb` is in `backend/requirements.txt`)

```bash
cd /path/to/mete
source .venv/bin/activate
python
```

```python
import duckdb
con = duckdb.connect("data/meteorites.duckdb", read_only=True)
con.sql("SELECT * FROM main_marts.meteorites LIMIT 5").show()
```

Two patterns:
- **For demo / display** — `con.sql(query).show()` returns a `DuckDBPyRelation` and pretty-prints an ASCII table. Best for screen-sharing.
- **For results in code** — `con.execute(query, params).fetchall()` (list of tuples) or `.fetchdf()` (pandas DataFrame) or `.fetchone()`. Use `.execute()` when you need to bind parameters.

### Option B: DuckDB CLI (nicer for ad-hoc — `brew install duckdb`)

```bash
duckdb -readonly data/meteorites.duckdb
```

```sql
.tables                                      -- list everything
.schema main_marts.meteorites_by_s2          -- inspect a table
SELECT * FROM main_marts.meteorites LIMIT 5;
```

---

## Schema overview

dbt builds into three schemas (configured in `dbt/dbt_project.yml`):

| Schema | What's in it |
|---|---|
| `main_staging` | `stg_meteorites` (view) — cleaned & typed; drops null/out-of-range coords |
| `main_intermediate` | `int_meteorites_classified` — normalises NASA's free-text `recclass` into a canonical `class_group` |
| | `int_meteorites_with_iron` — joins fact + dim, adds `iron_mass_g` per row |
| `main_marts` | `meteorites` — fact table, one row per landing |
| | `dim_meteorite_class` — dimension, one row per `class_group` |
| | `meteorites_by_s2` — density grid at 5 S2 levels (3-7) |

Inspect any table's columns:
```python
con.sql("DESCRIBE main_marts.meteorites").show()
```

---

## Demo queries

### 1. The S2 hierarchical rollup — exact at every level

The whole reason we chose S2 over H3. Same dataset rebucketed at 5 different
granularities; total count is conserved exactly:

```python
con.sql("""
    SELECT level, COUNT(*) AS cells, SUM(count) AS meteorites
    FROM main_marts.meteorites_by_s2
    GROUP BY level
    ORDER BY level
""").show()
```

Expected — `meteorites` column should be 32,186 at every level:

```
┌───────┬───────┬────────────┐
│ level │ cells │ meteorites │
├───────┼───────┼────────────┤
│   3   │  165  │   32,186   │
│   4   │  400  │   32,186   │
│   5   │  882  │   32,186   │
│   6   │ 1,612 │   32,186   │
│   7   │ 2,422 │   32,186   │
└───────┴───────┴────────────┘
```

### 2. Parent-child exactness (the actual quadtree proof)

Pick the top L3 cell, compute its 4 L4 children via `s2sphere`, sum them, and
compare to the parent. They match exactly — no overlap, no fudge:

```python
import s2sphere

top_l3 = con.execute("""
    SELECT s2_cell, count FROM main_marts.meteorites_by_s2
    WHERE level = 3 ORDER BY count DESC LIMIT 1
""").fetchone()
print(f"L3 parent: {top_l3[0]}  count = {top_l3[1]:,}")

children_tokens = [c.to_token() for c in s2sphere.CellId.from_token(top_l3[0]).children()]
sum_children = con.execute(
    "SELECT COALESCE(SUM(count), 0) FROM main_marts.meteorites_by_s2 "
    "WHERE level = 4 AND s2_cell IN ?",
    [children_tokens],
).fetchone()[0]
print(f"L4 children sum: {sum_children:,}")
print(f"match: {sum_children == top_l3[1]}")
```

### 3. Class composition + magnetic tier — iron yield by class

`int_meteorites_with_iron` carries the per-row `iron_mass_g` and
`magnetic_tier`; rolling it up by `class_group` shows that Iron meteorites
dominate per-row metal content even though they're a tiny fraction of total
finds:

```python
con.sql("""
    SELECT
        class_group,
        magnetic_tier,
        COUNT(*)                     AS count,
        ROUND(SUM(mass_g)      / 1000, 1) AS total_mass_kg,
        ROUND(SUM(iron_mass_g) / 1000, 1) AS iron_mass_kg
    FROM main_intermediate.int_meteorites_with_iron
    WHERE magnetic_tier IS NOT NULL
    GROUP BY class_group, magnetic_tier
    ORDER BY SUM(iron_mass_g) DESC
    LIMIT 10
""").show()
```

### 4. Magnet yield in raw SQL — what `POST /api/yield` actually runs

A 500 km magnet over Allan Hills, Antarctica. Same haversine + dedup logic
as the API endpoint (see `backend/db.py:get_yield`):

```python
con.sql("""
    WITH magnets(mlat, mlon, radius_km) AS (
        VALUES (-76.7, 157.5, 500.0)
    ),
    caught AS (
        SELECT DISTINCT m.id, m.class_group, m.mass_g, m.iron_mass_g
        FROM main_intermediate.int_meteorites_with_iron m
        CROSS JOIN magnets mag
        WHERE m.magnetic_tier IS NOT NULL
          AND 6371.0 * acos(LEAST(1.0,
              sin(radians(m.latitude)) * sin(radians(mag.mlat))
            + cos(radians(m.latitude)) * cos(radians(mag.mlat))
            * cos(radians(mag.mlon - m.longitude))
          )) <= mag.radius_km
    )
    SELECT
        COUNT(*)                        AS catches,
        ROUND(SUM(mass_g)    / 1000, 1) AS bulk_mass_kg,
        ROUND(SUM(iron_mass_g) / 1000, 1) AS iron_yield_kg
    FROM caught
""").show()
```

### 5. The post-1980 Antarctic discovery boom (ANSMET)

`falls_witnessed` (in-flight observations) stays flat across decades; `finds_recovered`
explodes after 1980. That's not "more meteorites are landing" — that's systematic
Antarctic survey programs finding decades of accumulated falls in blue ice:

```python
con.sql("""
    SELECT
        (year_landed // 10) * 10 AS decade,
        COUNT(*)                                AS count,
        COUNT(*) FILTER (WHERE fall = 'Fell')   AS falls_witnessed,
        COUNT(*) FILTER (WHERE fall = 'Found')  AS finds_recovered
    FROM main_marts.meteorites
    WHERE year_landed >= 1900
    GROUP BY decade
    ORDER BY decade
""").show()
```

### 6. Data quality story — the (0, 0) artifact

NASA's CSV uses `(0, 0)` as a placeholder for "we don't know the coordinates."
Those rows survive staging (coords are technically valid) and all bucket
into the same S2 cell in the Gulf of Guinea:

```python
con.sql("""
    SELECT
        s2_cell,
        count,
        ROUND(centroid_lat, 2) AS lat,
        ROUND(centroid_lon, 2) AS lon
    FROM main_marts.meteorites_by_s2
    WHERE level = 5
      AND centroid_lat BETWEEN -10 AND 10
      AND centroid_lon BETWEEN -10 AND 10
    ORDER BY count DESC
""").show()
```

Tracked in TODO — single-line WHERE clause in `stg_meteorites` would fix it.
