# ============================================================
# Meteorite Explorer — Lambda-compatible Docker image
#
# Multi-stage build:
#   1. adapter        — pulls in the AWS Lambda Web Adapter binary
#   2. dbt-builder    — runs `dbt build` to produce data/meteorites.duckdb
#                       from the raw CSV. dbt itself is NOT in the runtime
#                       image — the warehouse file is the only artifact
#                       that crosses the stage boundary.
#   3. runtime        — slim Python image with FastAPI + the prebuilt
#                       DuckDB file. Lambda Web Adapter proxies invocations
#                       to uvicorn on PORT 8000.
# ============================================================

FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.0.0 AS adapter

# ── Stage 2: dbt builder ─────────────────────────────────────
FROM python:3.12-slim AS dbt-builder

WORKDIR /build

COPY dbt/requirements.txt ./dbt-requirements.txt
RUN pip install --no-cache-dir -r dbt-requirements.txt

COPY dbt/ ./dbt/
COPY data/Meteorite_Landings.csv ./data/Meteorite_Landings.csv

WORKDIR /build/dbt
RUN dbt deps && dbt build

# ── Stage 3: runtime ─────────────────────────────────────────
FROM python:3.12-slim

COPY --from=adapter /lambda-adapter /opt/extensions/lambda-adapter

ENV PORT=8000
ENV AWS_LWA_INVOKE_MODE=response_stream
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ ./

# Bake the pre-built warehouse in at /data/ — same relative location as
# the local dev tree, so db.py's default path resolves identically here.
COPY --from=dbt-builder /build/data/meteorites.duckdb /data/meteorites.duckdb

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
