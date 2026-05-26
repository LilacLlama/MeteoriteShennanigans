import { useCallback, useEffect, useState } from "react";
import Map from "./components/Map";
import type {
  Magnet,
  MagnetSize,
  MeteoritePoint,
  YieldResult,
} from "./types";
import { MAGNET_RADIUS_KM } from "./types";

const API_BASE = import.meta.env.VITE_API_URL ?? "";

function massLabel(g: number | null): string {
  if (g == null) return "Unknown";
  if (g >= 1_000_000) return `${(g / 1_000_000).toFixed(1)} t`;
  if (g >= 1_000) return `${(g / 1_000).toFixed(1)} kg`;
  return `${g} g`;
}

function nextMagnetId(): string {
  return `m-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
}

export default function App() {
  const [points, setPoints] = useState<MeteoritePoint[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<MeteoritePoint | null>(null);

  const [magnets, setMagnets] = useState<Magnet[]>([]);
  const [activeSize, setActiveSize] = useState<MagnetSize>("M");
  const [yieldResult, setYieldResult] = useState<YieldResult | null>(null);
  const [yieldLoading, setYieldLoading] = useState(false);

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

  useEffect(() => {
    if (magnets.length === 0) {
      setYieldResult(null);
      return;
    }
    setYieldLoading(true);
    const ctrl = new AbortController();
    fetch(`${API_BASE}/api/yield`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        magnets: magnets.map((m) => ({ lat: m.lat, lon: m.lon, size: m.size })),
      }),
      signal: ctrl.signal,
    })
      .then((r) => r.json())
      .then((data: YieldResult) => {
        setYieldResult(data);
        setYieldLoading(false);
      })
      .catch((e) => {
        if (e.name !== "AbortError") setYieldLoading(false);
      });
    return () => ctrl.abort();
  }, [magnets]);

  const handleSelect = useCallback((m: MeteoritePoint) => {
    setSelected(m);
  }, []);

  const handlePlaceMagnet = useCallback(
    (lat: number, lon: number) => {
      setMagnets((prev) => [
        ...prev,
        { id: nextMagnetId(), lat, lon, size: activeSize },
      ]);
    },
    [activeSize],
  );

  const handleRemoveMagnet = useCallback((id: string) => {
    setMagnets((prev) => prev.filter((m) => m.id !== id));
  }, []);

  const clearMagnets = useCallback(() => {
    setMagnets([]);
  }, []);

  return (
    <div className="flex h-screen bg-gray-950 overflow-hidden">
      <div className="flex-1 relative">
        {loading && (
          <div className="absolute inset-0 z-50 flex items-center justify-center bg-gray-950">
            <div className="text-center space-y-3">
              <div className="text-4xl animate-spin">☄️</div>
              <p className="text-gray-400 text-sm">Loading 38,399 meteorites…</p>
            </div>
          </div>
        )}

        {error && (
          <div className="absolute inset-0 z-50 flex items-center justify-center bg-gray-950">
            <div className="text-center space-y-2">
              <p className="text-red-400 font-medium">Could not load data</p>
              <p className="text-gray-500 text-sm">{error}</p>
              <p className="text-gray-600 text-xs">
                Is the backend running on :8000?
              </p>
            </div>
          </div>
        )}

        {!loading && !error && (
          <Map
            points={points}
            selectedId={selected?.id ?? null}
            onSelect={handleSelect}
            magnets={magnets}
            onPlaceMagnet={handlePlaceMagnet}
            onRemoveMagnet={handleRemoveMagnet}
          />
        )}

        {selected && (
          <div className="absolute bottom-6 left-4 z-[1000] bg-gray-900/95 backdrop-blur rounded-2xl shadow-2xl p-4 w-72 border border-gray-700">
            <div className="flex items-start justify-between">
              <div className="flex-1 min-w-0">
                <h3 className="font-semibold text-white truncate">
                  {selected.name}
                </h3>
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
                <p className="text-white font-medium">
                  {massLabel(selected.mass_g)}
                </p>
              </div>
              <div className="bg-gray-800 rounded-lg p-2">
                <p className="text-gray-500">Year</p>
                <p className="text-white font-medium">
                  {selected.year ?? "Unknown"}
                </p>
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
      </div>

      <aside className="w-80 bg-gray-900 border-l border-gray-800 flex flex-col text-gray-200">
        <header className="p-5 border-b border-gray-800">
          <h1 className="font-semibold text-lg flex items-center gap-2">
            <span>☄️</span> Magnet Arsenal
          </h1>
          <p className="text-xs text-gray-500 mt-1 leading-relaxed">
            Click the map to deploy a magnet. Your would-be haul updates below.
          </p>
        </header>

        <section className="p-5 border-b border-gray-800 space-y-3">
          <p className="text-[10px] uppercase tracking-wider text-gray-500 font-medium">
            Magnet size
          </p>
          <div className="grid grid-cols-3 gap-2">
            {(["S", "M", "L"] as MagnetSize[]).map((size) => (
              <button
                key={size}
                onClick={() => setActiveSize(size)}
                className={`rounded-lg py-2 text-sm font-medium transition ${
                  activeSize === size
                    ? "bg-pink-500 text-white shadow-lg shadow-pink-500/30"
                    : "bg-gray-800 text-gray-400 hover:bg-gray-700"
                }`}
              >
                <div>{size}</div>
                <div className="text-[10px] opacity-70 font-normal">
                  {MAGNET_RADIUS_KM[size]} km
                </div>
              </button>
            ))}
          </div>
        </section>

        <section className="p-5 border-b border-gray-800">
          <div className="flex items-baseline justify-between mb-2">
            <p className="text-[10px] uppercase tracking-wider text-gray-500 font-medium">
              Deployed
            </p>
            {magnets.length > 0 && (
              <button
                onClick={clearMagnets}
                className="text-[10px] text-gray-500 hover:text-pink-400 transition"
              >
                Clear all
              </button>
            )}
          </div>
          {magnets.length === 0 ? (
            <p className="text-sm text-gray-600 italic">
              No magnets yet. The data won't catch itself.
            </p>
          ) : (
            <ul className="space-y-1 text-xs font-mono text-gray-400 max-h-32 overflow-y-auto">
              {magnets.map((m, i) => (
                <li
                  key={m.id}
                  className="flex items-center justify-between bg-gray-800/50 rounded px-2 py-1"
                >
                  <span>
                    #{i + 1} {m.size} · {m.lat.toFixed(2)}, {m.lon.toFixed(2)}
                  </span>
                  <button
                    onClick={() => handleRemoveMagnet(m.id)}
                    className="text-gray-600 hover:text-pink-400 ml-2"
                  >
                    ×
                  </button>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="p-5 flex-1 overflow-y-auto">
          <p className="text-[10px] uppercase tracking-wider text-gray-500 font-medium mb-3">
            Expected yield
          </p>
          {magnets.length === 0 ? (
            <p className="text-sm text-gray-600 italic">
              Deploy a magnet to see your would-be haul.
            </p>
          ) : yieldResult == null ? (
            <p className="text-sm text-gray-500">
              {yieldLoading ? "Calculating…" : "—"}
            </p>
          ) : (
            <>
              <div className="grid grid-cols-2 gap-2 mb-4">
                <div className="bg-gray-800 rounded-lg p-3">
                  <p className="text-[10px] text-gray-500 uppercase">Catches</p>
                  <p className="text-2xl font-semibold text-pink-400">
                    {yieldResult.summary.count.toLocaleString()}
                  </p>
                </div>
                <div className="bg-gray-800 rounded-lg p-3">
                  <p className="text-[10px] text-gray-500 uppercase">
                    Total mass
                  </p>
                  <p className="text-2xl font-semibold text-pink-400">
                    {massLabel(yieldResult.summary.total_mass_g)}
                  </p>
                </div>
                {yieldResult.summary.year_range[0] != null && (
                  <div className="bg-gray-800 rounded-lg p-3 col-span-2">
                    <p className="text-[10px] text-gray-500 uppercase">
                      Historical range
                    </p>
                    <p className="text-sm text-gray-200 font-mono">
                      {yieldResult.summary.year_range[0]} –{" "}
                      {yieldResult.summary.year_range[1]}
                    </p>
                  </div>
                )}
              </div>

              {yieldResult.by_class.length > 0 && (
                <>
                  <p className="text-[10px] uppercase tracking-wider text-gray-500 font-medium mb-2">
                    By classification
                  </p>
                  <ul className="space-y-1 text-xs">
                    {yieldResult.by_class.map((row) => (
                      <li
                        key={row.recclass}
                        className="flex items-center justify-between bg-gray-800/40 rounded px-2 py-1"
                      >
                        <span className="font-mono text-gray-300">
                          {row.recclass}
                        </span>
                        <span className="text-gray-400">
                          {row.count.toLocaleString()} ·{" "}
                          {massLabel(row.total_mass_g)}
                        </span>
                      </li>
                    ))}
                  </ul>
                </>
              )}
            </>
          )}
        </section>

        <footer className="p-3 border-t border-gray-800 text-[10px] text-gray-600 text-center">
          historical data only · 38,399 meteorites · NASA Open Data
        </footer>
      </aside>
    </div>
  );
}
