// Convert an S2 cell's 4-vertex boundary into render-ready Leaflet polygons,
// handling two edge cases the raw vertices don't render correctly:
//
//   1) Polar caps. Cells containing the north or south pole have a vertex
//      at lat = ±90°. The pole is a geometric singularity (all longitudes
//      meet there), and Mercator can't display it. We replace the pole
//      vertex with two synthetic vertices at lat = ±MERCATOR_LAT_LIMIT,
//      using the longitudes of the pole vertex's neighbors. The cell then
//      renders as a strip from the high-lat ring up to the Mercator clip.
//
//   2) Antimeridian crossings. Cells whose vertices straddle ±180° (e.g.
//      lons of [175, 178, -178, -175]) get rendered by Leaflet as a band
//      spanning the entire map width — because it connects (lat, 178) to
//      (lat, -178) by the *short* path in (lat, lon) space, which is the
//      long way around the globe. We unwrap longitudes so consecutive
//      vertices differ by ≤180°, then split the polygon at the meridian
//      it crosses into two pieces, each fully within [-180, 180].
//
// Both fixes are pre-applied so HeatmapLayer just maps cell → polygons.

export type LatLon = [number, number];

// Web Mercator can't display the poles (lat ±90 projects to ±∞). Standard
// practice is to clip at ~±85.05°; we round to 85 for the synthetic vertex.
const MERCATOR_LAT_LIMIT = 85;

function clipPolarCap(boundary: LatLon[]): LatLon[] {
  const poleIdx = boundary.findIndex(([lat]) => Math.abs(lat) === 90);
  if (poleIdx === -1) return boundary;

  const n = boundary.length;
  const clipLat = boundary[poleIdx][0] > 0 ? MERCATOR_LAT_LIMIT : -MERCATOR_LAT_LIMIT;
  const prevLon = boundary[(poleIdx - 1 + n) % n][1];
  const nextLon = boundary[(poleIdx + 1) % n][1];

  const out: LatLon[] = [];
  for (let i = 0; i < n; i++) {
    if (i === poleIdx) {
      out.push([clipLat, prevLon]);
      out.push([clipLat, nextLon]);
    } else {
      out.push(boundary[i]);
    }
  }
  return out;
}

function unwrapLongitudes(boundary: LatLon[]): LatLon[] {
  const out: LatLon[] = [boundary[0]];
  for (let i = 1; i < boundary.length; i++) {
    let lon = boundary[i][1];
    const prevLon = out[i - 1][1];
    while (lon - prevLon > 180) lon -= 360;
    while (lon - prevLon < -180) lon += 360;
    out.push([boundary[i][0], lon]);
  }
  return out;
}

function splitAtAntimeridian(unwrapped: LatLon[]): LatLon[][] {
  const lons = unwrapped.map(([, lon]) => lon);
  const minLon = Math.min(...lons);
  const maxLon = Math.max(...lons);

  // Polygon already fits — common case, no work to do.
  if (minLon >= -180 && maxLon <= 180) return [unwrapped];

  // Pick which meridian we're crossing. After unwrap a polygon extends past
  // at most one of ±180 (because the unwrap window is 360° wide).
  const splitMeridian = maxLon > 180 ? 180 : -180;

  // Walk edges. For each one that crosses, interpolate the lat at the
  // meridian and emit a synthetic vertex on both sides.
  const left: LatLon[] = [];
  const right: LatLon[] = [];
  for (let i = 0; i < unwrapped.length; i++) {
    const [lat, lon] = unwrapped[i];
    const [nLat, nLon] = unwrapped[(i + 1) % unwrapped.length];

    (lon < splitMeridian ? left : right).push([lat, lon]);

    if ((lon < splitMeridian) !== (nLon < splitMeridian)) {
      const t = (splitMeridian - lon) / (nLon - lon);
      const crossLat = lat + t * (nLat - lat);
      left.push([crossLat, splitMeridian]);
      right.push([crossLat, splitMeridian]);
    }
  }

  // One side has lons outside [-180, 180]; shift it by 360 to bring it
  // back in. Both pieces are then valid standalone polygons.
  const shift = splitMeridian === 180 ? -360 : 360;
  const shiftedSide = splitMeridian === 180 ? right : left;
  const inPlaceSide = splitMeridian === 180 ? left : right;
  const shifted: LatLon[] = shiftedSide.map(([lat, lon]) => [lat, lon + shift]);

  return [inPlaceSide, shifted].filter((p) => p.length >= 3);
}

export function cellToPolygons(lats: number[], lons: number[]): LatLon[][] {
  const boundary: LatLon[] = lats.map((lat, i) => [lat, lons[i]]);
  return splitAtAntimeridian(unwrapLongitudes(clipPolarCap(boundary)));
}
