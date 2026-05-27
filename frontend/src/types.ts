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

export type MagneticTier = "strong" | "medium" | "weak" | "none";

export interface YieldClassRow {
  class_group: string;
  magnetic_tier: MagneticTier;
  count: number;
  total_mass_g: number;
  iron_mass_g: number;
}

export interface YieldResult {
  summary: {
    count: number;
    catchable_count: number;
    total_mass_g: number;
    iron_mass_g: number;
    year_range: [number | null, number | null];
  };
  by_class: YieldClassRow[];
}

export type ViewMode = "markers" | "heatmap";

// One row of /api/heatmap — an S2 cell with its precomputed geometry.
// `boundary_lats` and `boundary_lons` are parallel 4-element arrays (the
// cell's four vertices). The backend pre-computes them so the frontend
// doesn't need an S2 library client-side.
export interface S2HeatCell {
  s2_cell: string;
  count: number;
  total_mass_g: number;
  iron_mass_g: number;
  centroid_lat: number;
  centroid_lon: number;
  boundary_lats: number[];
  boundary_lons: number[];
  level: number;
}
