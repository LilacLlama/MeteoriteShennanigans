# ☄️ Meteorite Explorer

[![Lint & Type Check](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/lint.yml/badge.svg)](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/lint.yml)
[![dbt Build & Tests](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/dbt.yml/badge.svg)](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/dbt.yml)
[![Backend Tests](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/pytest.yml/badge.svg)](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/pytest.yml)
[![dbt Docs](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/dbt-docs.yml/badge.svg)](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/dbt-docs.yml)
[![Terraform Docs](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/terraform-docs.yml/badge.svg)](https://github.com/LilacLlama/MeteoriteShennanigans/actions/workflows/terraform-docs.yml)

Place your magnets. Catch the most space rocks. Become the world's most data-driven supervillain — using NASA's complete 45,716-row meteorite landings dataset as your guide.

---

## Product

### What it is

Meteorite Explorer is a planning tool for the discerning supervillain. You have a small armoury of meteorite magnets (a few sizes, limited number). Place them on a world map. The app tells you how many meteorites — and how much total mass — your magnets *would have* caught if they'd been deployed across the full span of recorded history.

Under the hood it's a thin shell around a dbt-built DuckDB warehouse: every magnet placement triggers a spatial aggregation against pre-computed S2 cell densities derived from NASA's open dataset.

### The user

You're a supervillain-in-training. You want maximum dramatic impact for minimum magnet deployment. The product tells you, with cheerful honesty, where the data says space rocks actually fall — Antarctica, the Sahara, and (surprisingly) Oman.

### Core features

1. **Map of every recorded landing** — all 32,186 meteorites with valid coordinates (out of 45,716 raw; see "Data quality" below), clustered for legibility at world zoom and broken out as individual points when you zoom in. Orange = witnessed fall, blue = found later.
2. **S2 density heatmap** — toggle to the heatmap view and the same dataset renders as coloured S2 cells. Pick a granularity (L3 → L7) and the cells **subdivide exactly into 4** at each level, because S2 is a perfect quadtree. See ["Spatial model: why S2"](#spatial-model-why-s2-over-h3) below.
3. **Magnet placement** — click anywhere to drop a magnet. Choose a size (S = 100 km, M = 500 km, L = 1500 km radius). Coverage circles show your reach; clicking an existing magnet removes it.
4. **Expected yield** — live tally of total catches, total mass, classification breakdown (by class_group with magnetic_tier chips), and the physically meaningful **iron yield** (mass × per-class metal fraction). Computed server-side via a haversine query over `marts.meteorites`, deduping landings caught by overlapping magnets.

### Why this dataset, this framing

The dataset has a lot to say about *where* and *what*, and almost nothing useful about *when in the future* — which is the right shape for a "what would have happened" simulator rather than a real prediction tool. The supervillain framing turns that limitation into a feature: nobody expects rigorous forecasting from someone holding a giant magnet to the sky.

The technical guts are a real data engineering pipeline (dbt + DuckDB + S2 spatial aggregations + classification-via-seed) rather than ad-hoc Python. **The product is the demo; the pipeline is the point.**

---

## Data quality: what the pipeline catches

The raw NASA CSV is dirty in mundane ways — null placeholders, typos, free-text classifications. The staging + intermediate layers drop or normalize each of these explicitly, and dbt tests fail the build if any of the assumptions break.

| Filter / transformation | Where | Rows affected | Why |
|---|---|---|---|
| NULL latitude / longitude | `stg_meteorites` | ~7,300 dropped | A placement tool can't render unmappable rows |
| Out-of-range coords (lat\|lon outside [-90,90]/[-180,180]) | `stg_meteorites` | 0 today | Defensive — catches a future bad export |
| `(0, 0)` null-placeholder | `stg_meteorites` | **6,213 dropped** | NASA uses null-island as a stand-in for unknown coords; if left in, they all bucket into one S2 cell in the Gulf of Guinea and dominate the heatmap |
| Year outside [860, 2025] | `stg_meteorites` | **1 dropped** | Caught the "Northwest Africa 7701 → year 2101" typo. The `dbt_utils.accepted_range` test on this column blocks any new bad row |
| 400+ `recclass` values → ~35 canonical `class_group` | `int_meteorites_classified` | 0 dropped, recoded | NASA's free-text classifications need normalizing to join with the seed |
| `Relict X` prefix stripping | `int_meteorites_classified` | 0 dropped, recoded | Weathered samples bucket like their underlying class (`Relict OC` → `OC_unspecified`) |
| **Survives staging** | | **32,186 / 45,716 raw** | |

### What's enforced as tests, not comments

Every filter above is backed by a dbt test that fails the build if violated. A few highlights:

- `not_null` + `dbt_utils.accepted_range` on `latitude` / `longitude` — out-of-range or null coords break the build
- `dbt_utils.accepted_range` on `year_landed` (860–2025) — catches future bad-year exports
- `relationships` on `meteorites.class_group → dim_meteorite_class` — if NASA adds a new `recclass` we haven't classified, the FK fails
- Singular test `no_null_island.sql` — explicit assertion that the `(0, 0)` filter actually worked
- Singular test `class_group_one_per_meteorite.sql` — guard against join-fanout bugs in the classification step
- 50+ tests total; run via `make dbt-test` or `cd dbt && dbt test`

---

## Spatial model: why S2 over H3

The heatmap and yield calculator both bucket meteorites into spatial cells. Two mainstream choices for that: **H3** (Uber's hexagonal grid) and **S2** (Google's spherical quadtree). We picked S2.

### The case for S2

S2 is a **perfect quadtree**: every cell has exactly 4 children at the next level, the children tile the parent precisely, and `sum(4 children) == parent` *exactly* — no overlap, no fudge. The cell ID encodes the full path through the tree, so computing a parent is a bit-shift. H3 has hierarchy too (`cellToParent`, `cellToChildren`) but the children of a hex parent don't tile cleanly — they overlap into neighbouring parents' children, plus there are 12 pentagons at every resolution that need special handling. For aggregation, that's the difference between "exact rollup" and "approximation."

For this project, the win is concrete: the heatmap supports **explicit level switching** via a 5-button picker in the sidebar (L3 → L7). The numbers at every level are the **same data** rebucketed — verified at build time:

```
top L3 cell `afc` count = 7,026
its two non-empty L4 children:
  `af9` count = 6,826
  `aff` count =   200
                ─────
                7,026 ✓
```

### The mart

`marts.meteorites_by_s2` is a single table with one row per `(level, s2_cell)`, materialised by a dbt Python model. Each row carries the count, total mass, iron mass, cell centroid, and the 4-vertex polygon boundary (so the frontend renders Leaflet polygons without an S2 library client-side). Cell IDs are stored as **hex tokens** (strings) — the underlying int64 loses precision in JavaScript's `Number`.

### What the frontend does

Eager-fetches all 5 levels on first switch to heatmap mode (~1 MB total, parallel, ~1 sec). The user picks the active level explicitly from the sidebar; switching levels is instant because every level is already cached client-side. Responses are also `Cache-Control: max-age=60`, so browser-level cache survives page reloads too.

The original design used a `zoomend` listener to pick level automatically from zoom — dropped after testing because L3/L4 polygons rendering near the poles and across the antimeridian break under web-mercator, and silent auto-switching made those failures invisible. Explicit user control surfaces "L3 is coarse, look at the rollup" as a deliberate demo beat rather than a hidden side-effect of panning.

### What we'd do differently in a real product

- **Computed rollup levels** rather than materialised. Stored level 7, computed 3-6 on demand via S2's `cell.parent(N)`. Cheaper storage, slower queries — fine tradeoff at our scale, but materialising all 5 levels is simpler.
- **Bring `s2-geometry` client-side** to support arbitrary zoom levels without backend round-trips, once the JS-precision int64 problem is solved properly (BigInt + hex round-trip).

---

## Running locally

### Prerequisites
- Python 3.12 (the dbt build step is pinned to 3.12)
- Node 20+
- AWS credentials configured (`aws configure`) — only needed if you intend to deploy via Terraform

### One-time setup

```bash
make install        # backend + frontend deps
make dbt-install    # dbt-duckdb + s2sphere (build-time only)
make dbt-build      # builds data/meteorites.duckdb from the CSV — runs 26 tests
```

The dbt build is the data pipeline: it reads `data/Meteorite_Landings.csv`, runs the staging view + four marts, executes data-quality tests, and produces `data/meteorites.duckdb`. The backend reads this file read-only at startup — there is no CSV parsing at runtime.

### Run

```bash
make dev-backend    # FastAPI at http://localhost:8000
make dev-frontend   # Vite at  http://localhost:5173
```

The Vite dev server proxies `/api/*` to `localhost:8000` automatically — no CORS config needed locally.

---

## Infrastructure

AWS resources are managed with Terraform (local state). The one-time setup is handled by `bootstrap.sh`:

```bash
cp .env.example .env                                                # fill in APP_NAME, AWS_REGION
cp terraform/terraform.tfvars.example terraform/terraform.tfvars    # same values, separately reviewed
make bootstrap                                                      # ECR → Docker image → terraform apply → prints GitHub secrets
```

(The two files duplicate `aws_region` / `app_name` deliberately — `.env` drives the bootstrap shell script, `tfvars` is Terraform's input. Bootstrap won't run without both.)

After bootstrap, day-to-day infra changes use:

```bash
make tf-plan   # preview
make tf-apply  # apply
```

### ⚠️ terraform destroy + re-apply requires a Docker image push

`terraform destroy` deletes the ECR repository (and all images in it). A bare `terraform apply` after that will **fail** — Lambda requires a container image to exist in ECR at creation time. The correct sequence to tear down and rebuild:

```bash
terraform -chdir=terraform destroy

# Recreate ECR first, push an image, then provision everything else
terraform -chdir=terraform apply -target=aws_ecr_repository.api
docker build --platform linux/amd64 --provenance=false -t <ECR_URL>:latest .
docker push <ECR_URL>:latest
terraform -chdir=terraform apply
```

Or just re-run `make bootstrap`, which handles all of this automatically.

---

## Project structure

```
mete/
├── backend/
│   ├── main.py                  # FastAPI app — routes, CORS, lifespan
│   ├── db.py                    # Reads the dbt-built warehouse (read-only)
│   └── requirements.txt
├── dbt/                         # The data pipeline.
│   ├── dbt_project.yml
│   ├── profiles.yml             # DuckDB target → data/meteorites.duckdb
│   ├── packages.yml             # dbt_utils
│   └── models/
│       ├── staging/             # 1:1 with source. `stg_meteorites` (view).
│       ├── intermediate/        # Empty — kept for future joins.
│       └── marts/               # Business-ready tables consumed by the API.
│           ├── meteorites.sql           # Fact table (one row per landing)
│           ├── meteorites_by_s2.py      # Python model — S2 density grid
│           ├── meteorites_by_class.sql  # Aggregate by classification
│           └── meteorites_by_decade.sql # Aggregate by decade
├── frontend/
│   └── src/
│       ├── App.tsx              # Layout, state, map + detail card
│       └── components/
│           └── Map.tsx          # react-leaflet map + clusters
├── data/
│   ├── Meteorite_Landings.csv   # NASA dataset (45,716 rows; checked in)
│   └── meteorites.duckdb        # Built by `dbt build` (gitignored)
├── terraform/                   # AWS infra — ECR, Lambda, IAM, Function URL
├── scripts/
│   └── bootstrap.sh             # One-time AWS + infra setup
├── Makefile                     # Dev, lint, build, terraform, dbt targets
├── Dockerfile                   # Multi-stage: dbt build → slim runtime
└── .github/workflows/
    ├── lint.yml                 # ruff + tsc on every PR
    ├── pytest.yml               # backend pytest on every PR
    ├── dbt.yml                  # dbt build + 50+ data tests on every PR
    ├── dbt-docs.yml             # publish dbt docs to GitHub Pages on push to main
    ├── terraform-docs.yml       # auto-update terraform/README.md on push to main
    ├── terraform-plan.yml       # terraform plan on PR (apply is `make tf-apply` locally)
    ├── deploy-backend.yml       # ECR → Lambda on push to main
    └── deploy-frontend.yml      # S3 + CloudFront invalidation on push to main
```
