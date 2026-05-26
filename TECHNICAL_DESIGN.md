# Technical Design — Meteorite Explorer

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  GitHub Actions                                                      │
│  terraform/** → terraform plan (PR) / apply (main)                  │
│  backend/**   → docker build → ECR push → lambda update-function    │
│  frontend/**  → npm build → vercel deploy                           │
└────────────────────────────┬─────────────────────────────────────────┘
                             │
         ┌───────────────────┴─────────────────────┐
         │                                         │
┌────────▼─────────────────────────┐   ┌───────────▼────────────────┐
│  AWS Lambda (container image)    │   │  Vercel (static site)      │
│  FastAPI + DuckDB (in-process)   │   │  React + Vite + Leaflet    │
│  Function URL (streaming mode)   │   │  → calls Lambda URL        │
└──────────────────────────────────┘   └────────────────────────────┘

Infrastructure state is local — run `make tf-apply` from your machine.
Upgrade to S3 backend + DynamoDB locks when CI or multiple people need to apply.
```

---

## Technology choices

### Backend: FastAPI

**Why:** FastAPI is the right default for a Python HTTP server — async-first,
auto-generated docs, excellent Pydantic integration, and `StreamingResponse`
makes SSE trivial when we re-add the agent. The alternatives were Flask (no
async) and Django (too heavy).

### Data layer: DuckDB (in-process)

**Why:** The dataset is a single ~4MB CSV with 45k rows. DuckDB loads it into
memory in ~100ms at startup and then handles analytical SQL (aggregations,
filters, window functions) faster than any hosted database would for this data
size — without any infrastructure.

**What was evaluated and rejected:**
- *PostgreSQL/RDS* — overkill for a read-only dataset this small; adds a managed database to the bill.
- *SQLite* — good, but DuckDB's analytical performance and direct CSV ingestion (`read_csv_auto`) are meaningfully better.
- *DuckDB + Quack protocol* — evaluated seriously. Quack is a new (May 2026) client-server protocol that allows multiple processes to share a DuckDB database. For this app (single writer, single reader, read-only after startup) the added complexity of a server process provides no benefit. Worth revisiting if the product grows to support user annotations or concurrent writes.
- *S3 file mounting on Lambda* — also evaluated. AWS's new S3 filesystem mount for Lambda would let the `.duckdb` file live on S3 and be mounted at a local path. Elegant in theory, but requires Lambda inside a VPC (adds latency and cost via NAT gateway) and the data is small enough to bundle in the Docker image.

**Decision:** bundle `Meteorite_Landings.csv` in the Docker image, load into an
in-memory DuckDB instance at Lambda warm-up. Zero infrastructure dependencies
for data.

**Planned extensions:**
- *DuckDB spatial* — `INSTALL spatial; LOAD spatial;` adds `ST_Distance_Sphere`
  and related functions. Enables a `/api/meteorites/near?lat=&lon=&km=` endpoint
  with no new infrastructure.
- *S2 geometry heatmap* — group points by S2 cell ID at a configurable level,
  return cell polygons + counts to render a density heatmap layer on the map.

### Infrastructure as Code: Terraform

All AWS resources are managed by Terraform (`terraform/`):

| Resource | Purpose |
|---|---|
| `aws_ecr_repository` | Container registry for the Lambda image |
| `aws_iam_role` + policies | Lambda execution role; Bedrock invoke permissions |
| `aws_lambda_function` | Container Lambda, 512MB, 30s timeout |
| `aws_lambda_function_url` | Public HTTPS endpoint, `RESPONSE_STREAM` mode for SSE |

**State backend:** Local (`terraform.tfstate`, gitignored). Run `make tf-apply`
from your machine when infrastructure changes. Upgrade to S3 + DynamoDB
when multiple people or CI need to apply.

**Deploy pattern:** `image_uri` on the Lambda is set to `:latest` by Terraform
on first apply, then ignored (`lifecycle.ignore_changes`). Subsequent app
deploys push a new image tagged with `$GITHUB_SHA` via `deploy-backend.yml` and
call `aws lambda update-function-code` directly — Terraform is not involved in
routine deploys, only in infrastructure changes.

### AI: Claude via AWS Bedrock *(planned — currently disabled)*

The agent has been scaffolded but is temporarily removed while the core map
and data layer are stabilised.

**Design:** Claude (`claude-sonnet-4-5` via cross-region inference profile) runs
an agentic loop with two tools:
- `query_meteorites(sql)` — executes a SQL SELECT against DuckDB, returns JSON
- `get_schema()` — returns column names and types

Claude decides what to query, checks results, and can issue follow-up queries
before producing a final answer. This is meaningfully different from
prompt-stuffing (embedding 45k rows in context) — the model writes the SQL
itself.

**Why Bedrock instead of the Anthropic API directly:** Lambda execution role
gets `bedrock:InvokeModel*` via IAM — no API key to rotate or store in secrets.
Locally, boto3 picks up `~/.aws` credentials. One auth system for everything.

**SDK:** `anthropic[bedrock]` — `AnthropicBedrock()` is a drop-in replacement
for `Anthropic()`; same tool use and streaming APIs.

### Streaming: Server-Sent Events (SSE) *(ready for agent re-integration)*

FastAPI's `StreamingResponse` is already wired. Lambda Function URL is already
configured with `InvokeMode: RESPONSE_STREAM`. AWS Lambda Web Adapter handles
the bridge between Lambda's invocation model and uvicorn.

When the agent is re-added, text tokens will stream to the client in real time;
tool calls will emit `tool_start` / `tool_result` events the UI can render as
activity indicators.

### Frontend: React + Vite + Tailwind

**Why:** React for shared state between map and detail panel. Vite for fast
local dev. Tailwind for rapid, consistent styling without a component library
dependency.

**Map:** `react-leaflet` with `react-leaflet-cluster`. 45k markers need
clustering — `MarkerClusterGroup` groups nearby points at low zoom and expands
them as you zoom in. Dark CartoDB tiles (`dark_all`) make the orange/blue
meteorite markers pop.

**Considered:** `deck.gl` for WebGL-accelerated rendering of all 45k points
without clustering. Rejected — adds bundle size and complexity; clustering gives
better UX anyway (individual points aren't meaningfully clickable at world zoom).

### Deploy: Lambda + ECR + Vercel

| Concern | Decision |
|---|---|
| Backend hosting | AWS Lambda (container image) — free tier covers a demo app |
| Container registry | Amazon ECR — natural fit in AWS |
| Frontend hosting | Vercel — free, instant deploys, excellent React support |
| CI/CD | GitHub Actions — three path-filtered pipelines (infra / backend / frontend) |

**Why not App Runner?** Persistent process, no cold starts, streaming works —
but starts at ~$14/month minimum. Lambda's free tier wins for a demo.

**Why not Railway/Render/Fly.io?** Simpler setup, but AWS is already configured.
Staying in AWS keeps the infrastructure story coherent.

---

## CI/CD pipeline overview

```
PR opened
  └── lint.yml        ruff (Python) + tsc (TypeScript) — must pass to merge

terraform/** changed
  └── PR:   terraform plan posted as PR comment (apply locally with make tf-apply)

backend/** or Dockerfile changed
  └── main: docker build → ECR push ($GITHUB_SHA + latest) → lambda update-function-code

frontend/** changed
  └── main: npm build (VITE_API_URL injected) → vercel deploy --prod
```

---

## Local dev

```bash
make install       # pip install + npm install
make dev-backend   # FastAPI on :8000 (hot reload)
make dev-frontend  # Vite on :5173  (proxies /api → :8000)
make lint          # ruff + tsc
make format        # ruff format + prettier
```

No Docker needed locally. DuckDB loads the CSV from `./data/` at startup.

---

## What I'd do differently with more time

1. **Dev container** — getting started locally currently requires manually installing Python, Node, Docker, Terraform, and Python dependencies. A `.devcontainer/devcontainer.json` (VS Code) or `docker-compose.yml` for local dev would bundle all of that, so `git clone` + one command is all a new contributor needs.
2. **OIDC for GitHub Actions auth** — currently uses long-lived AWS access keys in GitHub secrets. Replacing with OIDC (`aws-actions/configure-aws-credentials` with role ARN) eliminates static credentials entirely.
2. **Map filters** — filter the 45k points by class, year range, mass, fell vs found directly in the UI rather than only via the agent.
3. **DuckDB Quack for multi-user writes** — if the product grew to support user annotations, Quack becomes the right choice: a persistent DuckDB server handling concurrent writes, Lambda functions as stateless readers.
4. **Streaming SQL display** — when the agent re-runs, show the SQL being written token-by-token rather than just "Querying database…". More transparent and a better demo of how the agent works.
