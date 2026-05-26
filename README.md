# ☄️ Meteorite Explorer

Place your magnets. Catch the most space rocks. Become the world's most data-driven supervillain — using NASA's complete 45,716-row meteorite landings dataset as your guide.

---

## Product

### What it is

Meteorite Explorer is a planning tool for the discerning supervillain. You have a small armoury of meteorite magnets (a few sizes, limited number). Place them on a world map. The app tells you how many meteorites — and how much total mass — your magnets *would have* caught if they'd been deployed across the full span of recorded history.

Under the hood it's a thin shell around a dbt-built DuckDB warehouse: every magnet placement triggers a spatial aggregation against pre-computed H3 cell densities derived from NASA's open dataset.

### The user

You're a supervillain-in-training. You want maximum dramatic impact for minimum magnet deployment. The product tells you, with cheerful honesty, where the data says space rocks actually fall — Antarctica, the Sahara, and (surprisingly) Oman.

### Core features

1. **Map of every recorded landing** — all 38,399 meteorites with valid coordinates, clustered for legibility at world zoom and broken out as individual points when you zoom in. Orange = witnessed fall, blue = found later.
2. **Magnet placement** — click anywhere to drop a magnet. Choose a size (S = 100 km, M = 500 km, L = 1500 km radius). Coverage circles show your reach; clicking an existing magnet removes it.
3. **Expected yield** — live tally of total catches, total mass, and classification breakdown ("~430 ordinary chondrites, 12 iron meteorites, 1 lunar specimen"), with the historical year range covered. Computed server-side via a haversine query over the dbt-built `marts.meteorites` table, deduping landings caught by overlapping magnets.

The `marts.meteorites_by_h3` density grid is also exposed via `GET /api/heatmap`. A choropleth render of it on the map is next on the list.

### Why this dataset, this framing

The dataset has a lot to say about *where* and *what*, and almost nothing useful about *when in the future* — which is the right shape for a "what would have happened" simulator rather than a real prediction tool. The supervillain framing turns that limitation into a feature: nobody expects rigorous forecasting from someone holding a giant magnet to the sky.

The technical guts are a real data engineering pipeline (dbt + DuckDB + H3 spatial aggregations) rather than ad-hoc Python. **The product is the demo; the pipeline is the point.**

---

## Running locally

### Prerequisites
- Python 3.12 (the dbt build step is pinned to 3.12)
- Node 20+
- AWS credentials configured (`aws configure`) — only needed if you intend to deploy via Terraform

### One-time setup

```bash
make install        # backend + frontend deps
make dbt-install    # dbt-duckdb + h3 (build-time only)
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
cp .env.example .env   # fill in APP_NAME, AWS_REGION
make bootstrap         # ECR → Docker image → terraform apply → prints GitHub secrets
```

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
│           ├── meteorites_by_h3.py      # Python model — H3 density grid
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
    ├── deploy-backend.yml       # ECR → Lambda on push to main
    ├── deploy-frontend.yml      # Vercel on push to main
    └── deploy-infra.yml         # terraform plan on PR (apply locally)
```
