export interface MeteoritePoint {
  id: number;
  name: string;
  reclat: number;
  reclong: number;
  recclass: string | null;
  mass_g: number | null;
  year: number | null;
  fall: string | null;
}

export interface MeteoriteDetail extends MeteoritePoint {
  nametype: string | null;
}

export type MagnetSize = "S" | "M" | "L";

export interface Magnet {
  id: string;
  lat: number;
  lon: number;
  size: MagnetSize;
}

// Must match MAGNET_RADII_KM in backend/db.py.
export const MAGNET_RADIUS_KM: Record<MagnetSize, number> = {
  S: 100,
  M: 500,
  L: 1500,
};

export interface YieldClassRow {
  recclass: string;
  count: number;
  total_mass_g: number;
}

export interface YieldResult {
  summary: {
    count: number;
    total_mass_g: number;
    year_range: [number | null, number | null];
  };
  by_class: YieldClassRow[];
}
