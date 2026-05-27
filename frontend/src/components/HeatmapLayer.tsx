import { Polygon, Tooltip } from "react-leaflet";
import type { S2HeatCell } from "../types";
import { massLabel } from "../lib/format";

// Log-bucketed count → heat palette. Buckets chosen so each row of the
// legend is meaningfully different at a glance: Antarctica's top cells
// (~6,000) land in the deep-red bucket, while single-meteorite cells
// stay pale yellow.
export const HEATMAP_BUCKETS: Array<{ max: number; color: string; label: string }> = [
  { max: 2, color: "#fef3c7", label: "1–2" },
  { max: 10, color: "#fde68a", label: "3–10" },
  { max: 50, color: "#fcd34d", label: "11–50" },
  { max: 200, color: "#fb923c", label: "51–200" },
  { max: 1000, color: "#ef4444", label: "201–1000" },
  { max: Infinity, color: "#b91c1c", label: "1000+" },
];

function colorForCount(count: number): string {
  for (const b of HEATMAP_BUCKETS) {
    if (count <= b.max) return b.color;
  }
  return HEATMAP_BUCKETS[HEATMAP_BUCKETS.length - 1].color;
}

interface Props {
  cells: S2HeatCell[];
}

export default function HeatmapLayer({ cells }: Props) {
  return (
    <>
      {cells.map((cell) => {
        const positions: [number, number][] = cell.boundary_lats.map(
          (lat, i) => [lat, cell.boundary_lons[i]],
        );
        const color = colorForCount(cell.count);
        return (
          <Polygon
            key={cell.s2_cell}
            positions={positions}
            pathOptions={{
              color,
              fillColor: color,
              fillOpacity: 0.55,
              weight: 0.5,
            }}
          >
            <Tooltip>
              <div className="text-xs font-sans">
                <div>
                  <b>{cell.count.toLocaleString()}</b> meteorites
                </div>
                <div>{massLabel(cell.total_mass_g)} total mass</div>
                <div>{massLabel(cell.iron_mass_g)} iron mass</div>
                <div className="text-gray-400 mt-1">cell {cell.s2_cell}</div>
              </div>
            </Tooltip>
          </Polygon>
        );
      })}
    </>
  );
}
