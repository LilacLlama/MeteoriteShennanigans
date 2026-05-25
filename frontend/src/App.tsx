import { useEffect, useState, useCallback } from "react";
import Map from "./components/Map";
import type { MeteoritePoint } from "./types";

const API_BASE = import.meta.env.VITE_API_URL ?? "";

function massLabel(g: number | null): string {
  if (g == null) return "Unknown";
  if (g >= 1_000_000) return `${(g / 1_000_000).toFixed(1)} t`;
  if (g >= 1_000) return `${(g / 1_000).toFixed(1)} kg`;
  return `${g} g`;
}

export default function App() {
  const [points, setPoints] = useState<MeteoritePoint[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<MeteoritePoint | null>(null);

  useEffect(() => {
    fetch(`${API_BASE}/api/meteorites`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then((data: MeteoritePoint[]) => {
        setPoints(data);
        setLoading(false);
      })
      .catch((e) => {
        setError(e.message);
        setLoading(false);
      });
  }, []);

  const handleSelect = useCallback((m: MeteoritePoint) => {
    setSelected(m);
  }, []);

  return (
    <div className="flex h-screen bg-gray-950 overflow-hidden">
      {/* Map */}
      <div className="flex-1 relative">
        {loading && (
          <div className="absolute inset-0 z-50 flex items-center justify-center bg-gray-950">
            <div className="text-center space-y-3">
              <div className="text-4xl animate-spin">☄️</div>
              <p className="text-gray-400 text-sm">Loading 45,716 meteorites…</p>
            </div>
          </div>
        )}

        {error && (
          <div className="absolute inset-0 z-50 flex items-center justify-center bg-gray-950">
            <div className="text-center space-y-2">
              <p className="text-red-400 font-medium">Could not load data</p>
              <p className="text-gray-500 text-sm">{error}</p>
              <p className="text-gray-600 text-xs">Is the backend running on :8000?</p>
            </div>
          </div>
        )}

        {!loading && !error && (
          <Map points={points} selectedId={selected?.id ?? null} onSelect={handleSelect} />
        )}

        {/* Selected meteorite detail card */}
        {selected && (
          <div className="absolute bottom-6 left-4 z-[1000] bg-gray-900/95 backdrop-blur rounded-2xl shadow-2xl p-4 w-72 border border-gray-700">
            <div className="flex items-start justify-between">
              <div className="flex-1 min-w-0">
                <h3 className="font-semibold text-white truncate">{selected.name}</h3>
                <p className="text-xs text-gray-400 mt-0.5">
                  {selected.recclass ?? "Unknown class"} ·{" "}
                  {selected.fall === "Fell" ? "Witnessed fall" : "Found"}
                </p>
              </div>
              <button
                onClick={() => setSelected(null)}
                className="text-gray-500 hover:text-gray-300 ml-2 text-lg leading-none"
              >
                ×
              </button>
            </div>

            <div className="mt-3 grid grid-cols-2 gap-2 text-xs">
              <div className="bg-gray-800 rounded-lg p-2">
                <p className="text-gray-500">Mass</p>
                <p className="text-white font-medium">{massLabel(selected.mass_g)}</p>
              </div>
              <div className="bg-gray-800 rounded-lg p-2">
                <p className="text-gray-500">Year</p>
                <p className="text-white font-medium">{selected.year ?? "Unknown"}</p>
              </div>
              <div className="bg-gray-800 rounded-lg p-2 col-span-2">
                <p className="text-gray-500">Coordinates</p>
                <p className="text-white font-medium font-mono">
                  {selected.reclat.toFixed(4)}, {selected.reclong.toFixed(4)}
                </p>
              </div>
            </div>
          </div>
        )}

        {/* Legend */}
        <div className="absolute bottom-6 right-4 z-[1000] bg-gray-900/90 backdrop-blur rounded-xl p-3 border border-gray-700 space-y-1.5 text-xs text-gray-300">
          <p className="font-medium text-gray-400 uppercase tracking-wide text-[10px]">Legend</p>
          <div className="flex items-center gap-2">
            <span className="w-3 h-3 rounded-full bg-orange-400 inline-block" />
            Witnessed fall
          </div>
          <div className="flex items-center gap-2">
            <span className="w-3 h-3 rounded-full bg-blue-400 inline-block" />
            Discovered later
          </div>
        </div>
      </div>
    </div>
  );
}
