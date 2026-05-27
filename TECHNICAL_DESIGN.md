# Technical Design — Lodestone

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  GitHub Actions (8 workflows, path-filtered)                         │
│  PR    → lint · pytest · dbt build · terraform plan (PR comment)     │
│  main  → docker build → ECR push → lambda update-function-code       │
│        → npm build → S3 sync → CloudFront invalidation               │
│        → dbt docs → GitHub Pages · terraform-docs → README inject    │
└────────────────────────────┬─────────────────────────────────────────┘
                             │
         ┌───────────────────┴─────────────────────┐
         │                                         │
┌────────▼─────────────────────────┐   ┌───────────▼────────────────┐
│  AWS Lambda (container image)    │   │  S3 + CloudFront           │
│  FastAPI + Lambda Web Adapter    │   │  React + Vite + Leaflet    │
│  Pre-built DuckDB warehouse      │◄──┤  → calls Lambda URL        │
│  Function URL (RESPONSE_STREAM)  │   │  OAC-signed private bucket │
└──────────────────────────────────┘   └────────────────────────────┘
         ▲
         │ baked at image-build time (multi-stage Dockerfile)
         │
┌────────┴───────────────────────────────────────────────────────────┐
│  dbt project (build-time only)                                     │
│  CSV → staging (view) → intermediate (view) → marts (table)        │
│  50+ data tests block the build on failure                         │
│  Python model (s2sphere) materialises 5-level S2 density grid      │
└────────────────────────────────────────────────────────────────────┘

Infrastructure state is local — run `make tf-apply` from your machine.
Upgrade to S3 backend + DynamoDB locks when CI or multiple people need to apply.
```

---

## Technology choices

### Data pipeline: dbt + DuckDB

**Why:** The NASA CSV is dirty in mundane, predictable ways — null
placeholders, the (0, 0) "null-island" coordinate convention, free-text
classifications, a typo with year 2101. Without a pipeline, that cleanup
either lives in the API code (and rots) or doesn't happen (and the heatmap
shows a hot spot in the Gulf of Guinea). With dbt, every filter is a SQL
model with a docstring and a test; the build fails if any assumption breaks.

**Structure:**

| Layer | Materialization | Purpose |
|---|---|---|
| `stg_meteorites` | view | NULL filter, range checks, (0,0) drop, year typo guard |
| `int_meteorites_classified` | view | NASA's 400+ `recclass` → ~35 canonical `class_group` via CASE ladder |
| `int_meteorites_with_iron` | view | Fact + dim join; adds per-row `iron_mass_g` (single source of truth) |
| `meteorites` (mart) | table | Final fact, one row per landing — served by the API |
| `dim_meteorite_class` (mart) | table | One row per `class_group`; derived `magnetic_tier` lives here |
| `meteorites_by_s2` (mart) | table | Python model — S2 density grid at levels 3–7, one row per `(level, s2_cell)` |
| `meteorite_class_composition` (seed) | CSV | Per-class metal_fraction_pct + parent body, with citations |

**Survives staging: 32,186 rows / 45,716 raw.** The most consequential
filter is the `(0, 0)` drop — it removes 6,213 NASA null-placeholder rows
that would otherwise all bucket into one S2 cell.

**Tests as guardrails:** ~50 generic tests (not_null, unique, accepted_values,
accepted_range, relationships) plus two singular SQL tests
(`no_null_island.sql`, `class_group_one_per_meteorite.sql`). The
`relationships` test on `meteorites.class_group → dim_meteorite_class`
catches new recclass values that the classifier doesn't bucket.

### Data layer at runtime: DuckDB (read-only, embedded)

**Why:** The pipeline output is a single 5 MB `meteorites.duckdb` file
baked into the container image. The runtime opens it `read_only=True` at
lifespan startup and serves all queries from it. There's **no CSV parsing
at runtime**, no DB server, no network round-trip — just an mmap and
analytical SQL.

**What was evaluated and rejected:**
- *PostgreSQL/RDS* — overkill for a read-only dataset this small; adds a managed database to the bill.
- *SQLite* — fine, but DuckDB's analytical performance on aggregations / joins / window functions is meaningfully better.
- *DuckDB + Quack protocol* — Quack is a new (May 2026) client-server protocol that lets multiple processes share a DuckDB database. For this app (single reader, read-only after startup) the added complexity of a server process buys nothing. Worth revisiting if the product grows to support user annotations.
- *S3 file-mount on Lambda* — AWS's S3 filesystem mount would let the `.duckdb` file live on S3. Elegant in theory, but requires Lambda inside a VPC (NAT gateway latency + cost) and the warehouse is small enough to bundle.

**Concurrency note:** FastAPI runs sync `def` handlers in a threadpool, so
multiple requests share the singleton connection. The query helper uses
`get_conn().cursor()` per call — without that, two threads racing
`.execute()`/`.fetchall()` on the same connection produced intermittent
empty responses when the frontend started fetching all 5 heatmap levels in
parallel.

### Spatial model: S2 over H3

The heatmap and yield calculator both bucket meteorites into spatial cells.
The two mainstream choices are **H3** (Uber's hexagonal grid) and **S2**
(Google's spherical quadtree). Picked S2.

**Why:** S2 is a perfect quadtree. Every cell has exactly 4 children at the
next level, the children tile the parent precisely, and `sum(4 children) ==
parent` exactly — no overlap, no fudge. So pre-computing all 5 levels
(L3–L7) is genuinely "the same dataset rebucketed at five granularities,"
not five independent estimates. H3 has hierarchy too, but the children of
a hex parent don't tile cleanly (they overlap into neighbouring parents'
children), plus there are 12 pentagons at every resolution that need
special handling.

**Build-time proof:**
```
top L3 cell `afc` count = 7,026
its two non-empty L4 children:
  `af9` count = 6,826
  `aff` count =   200
                ─────
                7,026 ✓
```

**Frontend:** eager-fetches all 5 levels on mount (~1.8 MB total). Once
cached, level switching is instant. Cell IDs are stored as hex tokens
(strings) because S2's int64 IDs lose precision in JavaScript `Number`
(>2^53). Cells crossing the antimeridian or the poles are split / clipped
client-side in `utils/cellPolygons.ts`.

### Backend: FastAPI

**Why:** FastAPI is the right default for a Python HTTP server — async-first,
auto-generated docs at `/docs`, excellent Pydantic integration, and
`StreamingResponse` makes SSE trivial when the agent comes back. Alternatives
were Flask (no async) and Django (too heavy).

**Shape:** Two files — `main.py` (routes + Pydantic models) and `db.py`
(connection + queries). Six endpoints: `/health`, `/api/config`,
`/api/meteorites`, `/api/meteorites/{id}`, `/api/heatmap?level=`,
`/api/yield`. Pydantic `Field` validators enforce lat/lon bounds, enum
`size`, and a 20-magnet max.

**The yield query** does a haversine sweep over
`int_meteorites_with_iron`, joins to `dim_meteorite_class` for per-class
metal fractions, **deduplicates** meteorites caught by overlapping magnets
(`SELECT DISTINCT m.id`), and returns summary + per-class breakdown.
`LEAST(1.0, …)` clamps the acos argument to avoid float-rounding domain
errors.

### Lambda packaging: container image + Lambda Web Adapter

**Why container, not zip:** Lambda Web Adapter (LWA) runs as a Lambda
extension inside the image, intercepts invocations, and forwards them as
real HTTP to uvicorn on `$PORT`. The app code is unchanged from local — no
Mangum, no `handler(event, context)` shim. The same `uvicorn main:app`
command runs in both places.

**Multi-stage Dockerfile:**

```
1. adapter        FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.0.0
2. dbt-builder    FROM python:3.12-slim
                  pip install dbt-duckdb + s2sphere, copy CSV, `dbt build`
3. runtime        FROM python:3.12-slim
                  Install backend deps, copy backend/, copy meteorites.duckdb
                  from stage 2, CMD ["uvicorn", "main:app", …]
```

dbt is **build-time only** — never present in the runtime image. Only the
resulting `.duckdb` file crosses the stage boundary.

**Two env vars must match or the response body is silently empty:**

| Dockerfile env | Function URL invoke mode |
|---|---|
| `AWS_LWA_INVOKE_MODE=response_stream` | `RESPONSE_STREAM` |
| *(unset or buffered)* | `BUFFERED` |

### Infrastructure as Code: Terraform

State is **local** (`terraform.tfstate`, gitignored). `make tf-apply` from
your machine; CI only runs `terraform plan` on PRs and posts the output as
a comment.

| Resource | Purpose |
|---|---|
| `aws_ecr_repository` + lifecycle policy | Container registry; keep last 10 images |
| `aws_iam_role.lambda` + `AWSLambdaBasicExecutionRole` | Lambda execution role (Bedrock policy removed with the agent — re-add when it returns) |
| `aws_lambda_function` (container, 512 MB, 30 s) | The API. `lifecycle.ignore_changes = [image_uri]` so CI deploys aren't reverted |
| `aws_lambda_permission` × 2 | Required since Oct 2025: both `InvokeFunctionUrl` *and* `InvokeFunction` — granting only the first returns 403 |
| `aws_lambda_function_url` (`NONE`, `RESPONSE_STREAM`) | Public HTTPS endpoint, SSE-capable |
| `aws_s3_bucket` (frontend) + public-access block | Static site bucket, fully private |
| `aws_cloudfront_origin_access_control` | SigV4-signed CloudFront → S3 reads |
| `aws_cloudfront_distribution` | CDN, SPA-friendly 403/404 → `/index.html`, `*.cloudfront.net` cert |
| `aws_s3_bucket_policy` | Only this distribution's OAC can read the bucket |
| `aws_iam_user` (CI) + inline policy | Least-privilege user for GitHub Actions (5 statements). Access key created out-of-band by `bootstrap.sh` so the secret never enters Terraform state |

**Deploy pattern:** `image_uri` is set to `:latest` on first apply, then
ignored. Subsequent app deploys push a new image tagged with `$GITHUB_SHA`
via `deploy-backend.yml` and call `aws lambda update-function-code`
directly — Terraform is not involved in routine deploys, only in
infrastructure changes.

### Frontend: React + Vite + Tailwind + Leaflet

**Why:** React for shared state between map / sidebar / detail card. Vite
for fast local dev. Tailwind for rapid, consistent styling without a
component library dep. Strict TypeScript throughout (`strict: true`,
`noUnusedLocals`, `noUnusedParameters`).

**State model:** All `useState` in `App.tsx` — no Redux, no Zustand, no
React Query. Five effects, one per concern (lazy markers fetch on first
switch to markers view, config fetch, eager S2 prefetch of all 5 levels
via `Promise.allSettled`, yield recompute with 100 ms debounce +
`AbortController`, escape-closes-mobile-sidebar).

**Map:** `react-leaflet` + `react-leaflet-cluster` (32,186 markers cluster
at world zoom, expand on zoom-in). Canvas renderer (`preferCanvas`) for
performance. Cluster layer is `useMemo`-ed so magnet placements don't
re-cluster the entire dataset. The view toggle switches between markers
and the S2 heatmap.

**Heatmap polygon math** (`utils/cellPolygons.ts`) handles two cases that
break web-Mercator naively:
- **Polar caps** — vertices at lat ±90° get replaced with two synthetic
  vertices at ±85° (Mercator's clip latitude).
- **Antimeridian crossings** — unwrap longitudes so consecutive vertices
  differ by ≤180°, then split the polygon at the meridian and shift the
  "outside" half by ∓360°.

**Considered and rejected:** `deck.gl` for WebGL-accelerated rendering of
all 32k points without clustering. Adds bundle size and complexity;
clustering gives better UX anyway (individual points aren't meaningfully
clickable at world zoom).

### Frontend deploy: S3 + CloudFront with OAC

**Why this stack instead of Vercel** (the original choice): keeps the
entire architecture story inside AWS. Vercel would have been faster to set
up but a less complete demo of cloud plumbing.

- **Bucket is fully private.** No public S3 website hosting. CloudFront OAC
  signs each read with SigV4; the bucket policy only admits that signature.
- **SPA routing.** Two `custom_error_response` blocks rewrite 403 *and*
  404 to `200 /index.html` so deep-link refreshes don't 404.
- **Cache strategy** set per-file at upload time, not in CloudFront:
  - `assets/**` → `Cache-Control: max-age=31536000, immutable` (Vite
    content-hashes filenames)
  - `index.html` → `Cache-Control: no-cache`
- `aws cloudfront create-invalidation --paths "/*"` on every deploy. First
  1,000 invalidation paths/month are free.

### AI: Claude via AWS Bedrock *(scaffolded, currently disabled)*

The agent was built and removed temporarily to stabilise the core map and
data layer (see DEVLOG 2026-05-25). When it returns:

**Design:** Claude Sonnet 4.6 via Bedrock cross-region inference profile,
running an agentic loop with two tools:
- `query_meteorites(sql)` — executes a SQL SELECT against DuckDB, returns JSON
- `get_schema()` — returns column names and types

The model writes the SQL itself — meaningfully different from
prompt-stuffing 32k rows into context.

**Why Bedrock, not the Anthropic API directly:** Lambda's execution role
gets `bedrock:InvokeModel*` via IAM — no API key to rotate or store. The
IAM policy for that statement is staged in `terraform/lambda.tf` and gets
re-added with the agent.

**SDK:** `anthropic[bedrock]` — `AnthropicBedrock()` is a drop-in
replacement for `Anthropic()`; same tool-use and streaming APIs.

### Streaming: Server-Sent Events *(wired, idle until the agent returns)*

FastAPI `StreamingResponse` is already in place. Lambda Function URL is
already `RESPONSE_STREAM`. LWA bridges Lambda's invocation model and
uvicorn streams. When the agent re-lands, text tokens stream to the client
in real time; tool calls emit `tool_start` / `tool_result` events the UI
can render as activity indicators.

### Hosting summary

| Concern | Decision |
|---|---|
| Backend hosting | AWS Lambda (container image) — free tier covers a demo |
| Container registry | Amazon ECR — required for Lambda (no Docker Hub allowed) |
| Frontend hosting | S3 + CloudFront with OAC — fully AWS, private bucket, free TLS |
| CI/CD | GitHub Actions — 8 path-filtered workflows |

**Why not App Runner?** Persistent process, no cold starts, streaming
works — but starts at ~$14/month minimum. Lambda's free tier wins for a
demo.

**Why not Railway/Render/Fly.io?** Simpler setup, but AWS is already
configured. Staying in AWS keeps the infrastructure story coherent.

---

## CI/CD pipeline overview

Eight workflows, all with `permissions: contents: read` and
`concurrency.cancel-in-progress: true` (except `dbt-docs.yml`, which uses
`group: pages` with `cancel-in-progress: false` because GitHub Pages
deployments are serialised).

```
PR opened
  ├── lint.yml             ruff (backend) + tsc (frontend)
  ├── pytest.yml           dbt build (warehouse) → pytest backend tests
  ├── dbt.yml              dbt deps + dbt build (50+ data tests)
  └── terraform-plan.yml   (only if terraform/** changed) — plan posted as PR comment

push to main
  ├── deploy-backend.yml   docker build → ECR push ($SHA + :latest) → lambda update + wait
  │                        (path-filtered: backend/**, data/**, Dockerfile)
  ├── deploy-frontend.yml  npm run build → two-pass S3 sync → CloudFront invalidate
  │                        (path-filtered: frontend/**)
  ├── dbt-docs.yml         dbt build + docs generate → GitHub Pages
  └── terraform-docs.yml   terraform-docs → inject into terraform/README.md → commit back
```

**CI never runs `terraform apply`.** Local state means only the maintainer
can apply. PRs that touch `terraform/**` get a plan comment for review;
the actual apply is `make tf-apply` locally.

**Secrets / variables:**
- *Secrets* — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (CI IAM user,
  created by `bootstrap.sh`).
- *Variables* — `AWS_REGION`, `ECR_REGISTRY`, `LAMBDA_FUNCTION`,
  `VITE_API_URL`, `FRONTEND_BUCKET`, `CF_DISTRIBUTION_ID`. All printed by
  `make bootstrap` and copied in by hand.

---

## Local dev

```bash
make install       # pip install + npm install
make dbt-build     # one-time (and on data changes) — builds data/meteorites.duckdb
make dev-backend   # FastAPI on :8000 (hot reload)
make dev-frontend  # Vite on :5173  (proxies /api → :8000)
make lint          # ruff + tsc
make test          # pytest (requires data/meteorites.duckdb)
```

No Docker needed locally. The backend opens the pre-built warehouse
read-only at startup; if `data/meteorites.duckdb` doesn't exist, run
`make dbt-build` first.

---

## What I'd do differently with more time

1. **Dev container** — getting started currently requires manually
   installing Python, Node, Docker, Terraform, and project dependencies. A
   `.devcontainer/devcontainer.json` would bundle everything so `git
   clone` + one command is all a new contributor needs.
2. **OIDC for GitHub Actions auth** — currently uses long-lived IAM access
   keys in GitHub secrets. Replacing with OIDC
   (`aws-actions/configure-aws-credentials` with role ARN) eliminates
   static credentials.
3. **Remote Terraform state** — S3 backend + DynamoDB lock. Required for
   CI to apply, and for scheduled rebuilds (base-image patching) that
   today would need either remote state or hardcoded GitHub vars.
4. **Map filters** — filter the 32k points by class, year range, mass,
   `Fell` vs `Found` directly in the UI rather than only via the agent.
5. **`MagnetDeployment` resource** — `POST /api/deployments` returns an
   id; `GET /api/deployments/{id}/yield` is then cacheable. Earns its
   weight once users want shareable links or saved layouts.
6. **DuckDB Quack for multi-user writes** — if the product grew to
   support user annotations, Quack becomes the right choice: a persistent
   DuckDB server handling concurrent writes, Lambda functions as
   stateless readers.
7. **Streaming SQL display** — when the agent re-lands, show the SQL
   being written token-by-token rather than just "Querying database…".
   More transparent and a better demo of how the agent works.
8. **Image vulnerability scanning in CI** — ECR has `scan_on_push = true`
   but the findings don't surface as a PR check today. Trivy in the
   build pipeline is trivial to add.
