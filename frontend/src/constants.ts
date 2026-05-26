import type { MagnetRadiiKm } from "./types";

// Used only if `GET /api/config` is unreachable. The runtime values come from
// the backend (see `MAGNET_RADII_KM` in backend/db.py) so these two don't drift.
export const FALLBACK_MAGNET_RADII_KM: MagnetRadiiKm = {
  S: 100,
  M: 500,
  L: 1500,
};
