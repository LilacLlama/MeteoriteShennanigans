"""
FastAPI application — Meteorite Explorer backend.

Endpoints:
  GET  /api/config            — shared client/server constants (magnet radii)
  GET  /api/meteorites        — all map points (id, name, lat, lon, class, mass, year, fall)
  GET  /api/meteorites/{id}   — single meteorite detail
  GET  /api/heatmap           — S2 cell density grid for the heatmap layer
  POST /api/yield             — expected catch for a set of magnet placements
  GET  /health                — health check
"""

import logging
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from db import MAGNET_RADII_KM, get_all_points, get_conn, get_meteorite, get_s2_cells, get_yield

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Opening warehouse...")
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


@app.get("/api/config")
def config():
    """Constants the frontend needs that originate on the server."""
    return {"magnet_radii_km": MAGNET_RADII_KM}


@app.get("/api/meteorites")
def list_meteorites():
    """All meteorite landings for the map's marker layer."""
    return get_all_points()


@app.get("/api/meteorites/{meteorite_id}")
def meteorite_detail(meteorite_id: int):
    row = get_meteorite(meteorite_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Meteorite not found")
    return row


@app.get("/api/heatmap")
def heatmap():
    """S2 cell density grid — drives the supervillain's reconnaissance overlay."""
    return get_s2_cells()


class Magnet(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    size: Literal["S", "M", "L"]


class YieldRequest(BaseModel):
    magnets: list[Magnet] = Field(max_length=20)


@app.post("/api/yield")
def yield_for_magnets(req: YieldRequest):
    """Expected meteorite catch for a set of magnet placements."""
    placements = [(m.lat, m.lon, MAGNET_RADII_KM[m.size]) for m in req.magnets]
    return get_yield(placements)
