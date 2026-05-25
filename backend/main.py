"""
FastAPI application — Meteorite Explorer backend.

Endpoints:
  GET  /api/meteorites        — all map points (id, name, lat, lon, class, mass, year, fall)
  GET  /api/meteorites/{id}   — single meteorite detail
  GET  /health                — health check
"""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from db import get_conn, get_all_points, query

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Warming up DuckDB...")
    get_conn()
    yield


app = FastAPI(title="Meteorite Explorer API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/api/meteorites")
def get_meteorites():
    """Return all meteorite locations for the map."""
    return get_all_points()


@app.get("/api/meteorites/{meteorite_id}")
def get_meteorite(meteorite_id: int):
    """Return a single meteorite by its NASA id."""
    rows = query(f"SELECT * FROM meteorites WHERE id = {meteorite_id}")
    if not rows:
        raise HTTPException(status_code=404, detail="Meteorite not found")
    return rows[0]
