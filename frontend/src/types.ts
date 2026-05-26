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

export type MagnetRadiiKm = Record<MagnetSize, number>;

export interface Magnet {
  id: string;
  lat: number;
  lon: number;
  size: MagnetSize;
}

export interface AppConfig {
  magnet_radii_km: MagnetRadiiKm;
}

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
