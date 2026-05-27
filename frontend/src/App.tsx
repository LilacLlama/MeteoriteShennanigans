import { useCallback, useEffect, useState } from "react";
import Map from "./components/Map";
import { HEATMAP_BUCKETS } from "./components/HeatmapLayer";
import YieldBreakdown from "./components/YieldBreakdown";
import { massLabel } from "./utils/format";
import type {
  AppConfig,
  Magnet,
  MagnetRadiiKm,
  MagnetSize,
  MeteoritePoint,
  S2HeatCell,
  ViewMode,
  YieldResult,
} from "./types";
import { FALLBACK_MAGNET_RADII_KM } from "./constants";

const API_BASE = import.meta.env.VITE_API_URL ?? "";
const YIELD_DEBOUNCE_MS = 100;

const S2_LEVELS = [3, 4, 5, 6, 7] as const;
const LEVEL_DESCRIPTIONS: Record<number, string> = {
  3: "continent-scale cells",
  4: "large-country cells",
  5: "small-country / region cells",
  6: "state-sized cells",
  7: "metro / county cells",
};

function nextMagnetId(): string {
  return `m-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
}

export default function App() {
  const [points, setPoints] = useState<MeteoritePoint[]>([]);
  // `loading` now tracks the lazy markers fetch (fires on first switch to
  // markers view). Initial mount shows the heatmap, so no blocking load.
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<MeteoritePoint | null>(null);

  const [magnets, setMagnets] = useState<Magnet[]>([]);
  const [activeSize, setActiveSize] = useState<MagnetSize>("M");
  const [yieldResult, setYieldResult] = useState<YieldResult | null>(null);
  const [yieldLoading, setYieldLoading] = useState(false);
  const [radii, setRadii] = useState<MagnetRadiiKm>(FALLBACK_MAGNET_RADII_KM);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [viewMode, setViewMode] = useState<ViewMode>("heatmap");
  const [heatLevel, setHeatLevel] = useState<number>(5);
  const [heatCellsByLevel, setHeatCellsByLevel] = useState<
    Record<number, S2HeatCell[]>
  >({});
  const [heatLoading, setHeatLoading] = useState(false);

  useEffect(() => {
    // Lazy fetch — only when user switches to markers view, and only once.
    // Heatmap is the default view, so most visitors never pay this ~3MB cost.
    if (viewMode !== "markers" || points.length > 0 || loading) return;
    setLoading(true);
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
  }, [viewMode, points.length, loading]);

  useEffect(() => {
    fetch(`${API_BASE}/api/config`)
      .then((r) => r.json())
      .then((c: AppConfig) => setRadii(c.magnet_radii_km))
      .catch(() => {
        // Stay on FALLBACK_MAGNET_RADII_KM — values match the backend defaults
        // so the UI keeps working even if the config endpoint is unreachable.
      });
  }, []);

  useEffect(() => {
    // Eager-prefetch all 5 S2 levels on mount. Heatmap is the default view
    // (and the demo's main visual), so this is the initial blocking fetch.
    // Total ~1.8MB across all levels; once loaded, switching between L3-L7
    // is instant from the cache.
    //
    // Using `Promise.allSettled` so one failed level doesn't nuke the other
    // four — the user still sees a partial heatmap. If ALL levels fail, we
    // surface the existing error overlay.
    setHeatLoading(true);
    const levels = [3, 4, 5, 6, 7];
    Promise.allSettled(
      levels.map((level) =>
        fetch(`${API_BASE}/api/heatmap?level=${level}`)
          .then((r) => {
            if (!r.ok) throw new Error(`L${level}: HTTP ${r.status}`);
            return r.json();
          })
          .then((cells: S2HeatCell[]) => [level, cells] as const),
      ),
    ).then((results) => {
      const successes = results
        .filter(
          (r): r is PromiseFulfilledResult<readonly [number, S2HeatCell[]]> =>
            r.status === "fulfilled",
        )
        .map((r) => r.value);
      const failureCount = results.length - successes.length;

      setHeatCellsByLevel(Object.fromEntries(successes));
      setHeatLoading(false);

      if (failureCount === results.length) {
        setError("Heatmap data unavailable — try refreshing in a moment.");
      } else if (failureCount > 0) {
        console.warn(
          `Heatmap: ${failureCount}/${results.length} level fetches failed; rendering partial data`,
        );
      }
    });
  }, []);

  useEffect(() => {
    if (!sidebarOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setSidebarOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [sidebarOpen]);

  useEffect(() => {
    if (magnets.length === 0) {
      setYieldResult(null);
      setYieldLoading(false);
      return;
    }
    setYieldLoading(true);
    const ctrl = new AbortController();
    const timer = setTimeout(() => {
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
    }, YIELD_DEBOUNCE_MS);
    return () => {
      clearTimeout(timer);
      ctrl.abort();
    };
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
        {heatLoading && Object.keys(heatCellsByLevel).length === 0 && (
          <div className="absolute inset-0 z-50 flex items-center justify-center bg-gray-950">
            <div className="text-center space-y-3">
              <div className="text-4xl animate-spin">☄️</div>
              <p className="text-gray-400 text-sm">Loading heatmap…</p>
            </div>
          </div>
        )}

        {error && (
          <div className="absolute inset-0 z-50 flex items-center justify-center bg-gray-950">
            <div className="text-center space-y-2">
              <p className="text-red-400 font-medium">Could not load data</p>
              <p className="text-gray-500 text-sm">{error}</p>
              <p className="text-gray-600 text-xs">
                Your reconnaissance feed appears severed. Check the data conduit.
              </p>
            </div>
          </div>
        )}

        {!error && (
          <Map
            points={points}
            selectedId={selected?.id ?? null}
            onSelect={handleSelect}
            magnets={magnets}
            radii={radii}
            onPlaceMagnet={handlePlaceMagnet}
            onRemoveMagnet={handleRemoveMagnet}
            viewMode={viewMode}
            heatCells={heatCellsByLevel[heatLevel] ?? []}
          />
        )}

        {!loading && !error && viewMode === "heatmap" && (
          <div className="absolute bottom-6 right-4 z-overlay bg-gray-900/90 backdrop-blur rounded-xl p-3 border border-gray-700 text-[10px] text-gray-300 space-y-1.5">
            <p className="font-medium text-gray-400 uppercase tracking-wider mb-1">
              Meteorites per cell
            </p>
            {heatLoading && Object.keys(heatCellsByLevel).length === 0 ? (
              <p className="text-gray-500 italic">Loading…</p>
            ) : (
              HEATMAP_BUCKETS.map((b) => (
                <div key={b.label} className="flex items-center gap-2">
                  <span
                    style={{ background: b.color }}
                    className="w-3 h-3 rounded-sm inline-block"
                  />
                  {b.label}
                </div>
              ))
            )}
          </div>
        )}

        {selected && (
          <div className="absolute bottom-6 left-4 z-overlay bg-gray-900/95 backdrop-blur rounded-2xl shadow-2xl p-4 w-72 border border-gray-700">
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

        {/* Mobile-only: arsenal toggle button. Desktop has the sidebar pinned. */}
        <button
          onClick={() => setSidebarOpen((o) => !o)}
          className="lg:hidden absolute top-4 right-4 z-toggle bg-gray-900/95 backdrop-blur text-white px-4 py-3 min-h-[44px] min-w-[44px] rounded-lg shadow-lg border border-gray-700 text-base font-medium"
          aria-label="Toggle magnet arsenal"
        >
          {sidebarOpen ? "✕" : `☄️ Magnets${magnets.length ? ` (${magnets.length})` : ""}`}
        </button>
      </div>

      {/* Mobile-only: tap-outside backdrop to close the sidebar. */}
      {sidebarOpen && (
        <div
          onClick={() => setSidebarOpen(false)}
          className="lg:hidden fixed inset-0 bg-black/40 z-backdrop"
          aria-hidden="true"
        />
      )}

      <aside
        className={`
          fixed lg:relative inset-y-0 right-0 z-sidebar
          w-80 max-w-[85vw]
          bg-gray-900 border-l border-gray-800 flex flex-col text-gray-200
          transition-transform duration-200 ease-out
          ${sidebarOpen ? "translate-x-0" : "translate-x-full lg:translate-x-0"}
        `}
      >
        <header className="p-5 border-b border-gray-800">
          <h1 className="font-semibold text-lg flex items-center gap-2">
            <span>☄️</span> Magnet Arsenal
          </h1>
          <p className="text-xs text-gray-500 mt-1 leading-relaxed">
            Click the map to deploy a magnet. Your would-be haul updates below.
          </p>
        </header>

        <section className="p-5 border-b border-gray-800 space-y-2">
          <p className="text-[10px] uppercase tracking-wider text-gray-500 font-medium">
            View
          </p>
          <div className="grid grid-cols-2 gap-1 bg-gray-800 rounded-lg p-1">
            {(["markers", "heatmap"] as ViewMode[]).map((mode) => (
              <button
                key={mode}
                onClick={() => setViewMode(mode)}
                className={`rounded-md py-1.5 text-xs font-medium capitalize transition ${
                  viewMode === mode
                    ? "bg-gray-700 text-white"
                    : "text-gray-400 hover:text-gray-200"
                }`}
              >
                {mode}
              </button>
            ))}
          </div>
        </section>

        {viewMode === "heatmap" && (
          <section className="p-5 border-b border-gray-800 space-y-2">
            <p className="text-[10px] uppercase tracking-wider text-gray-500 font-medium">
              Granularity (S2 level)
            </p>
            <div className="grid grid-cols-5 gap-1 bg-gray-800 rounded-lg p-1">
              {S2_LEVELS.map((level) => (
                <button
                  key={level}
                  onClick={() => setHeatLevel(level)}
                  className={`rounded-md py-1.5 text-xs font-medium transition ${
                    heatLevel === level
                      ? "bg-gray-700 text-white"
                      : "text-gray-400 hover:text-gray-200"
                  }`}
                >
                  L{level}
                </button>
              ))}
            </div>
            <p className="text-[10px] text-gray-500 italic leading-relaxed">
              {LEVEL_DESCRIPTIONS[heatLevel]} · exact rollup at every level
            </p>
          </section>
        )}

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
                  {radii[size]} km
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
                {/* Iron yield is the physically meaningful headline — bulk
                    mass × per-class metal fraction. A villain who lifts
                    rocks with a magnet only gets the iron part. */}
                <div className="bg-gray-800 rounded-lg p-3 col-span-2">
                  <p className="text-[10px] text-gray-500 uppercase">
                    Iron yield
                  </p>
                  <p className="text-3xl font-semibold text-pink-400">
                    {massLabel(yieldResult.summary.iron_mass_g)}
                  </p>
                  <p className="text-[10px] text-gray-500 mt-1">
                    of {massLabel(yieldResult.summary.total_mass_g)} bulk mass
                  </p>
                </div>
                <div className="bg-gray-800 rounded-lg p-3">
                  <p className="text-[10px] text-gray-500 uppercase">Catches</p>
                  <p className="text-xl font-semibold text-gray-100">
                    {yieldResult.summary.count.toLocaleString()}
                  </p>
                </div>
                <div className="bg-gray-800 rounded-lg p-3">
                  <p className="text-[10px] text-gray-500 uppercase">
                    Catchable
                  </p>
                  <p className="text-xl font-semibold text-gray-100">
                    {yieldResult.summary.catchable_count.toLocaleString()}
                  </p>
                  <p className="text-[10px] text-gray-500 mt-0.5">
                    achondrites excluded
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
                <YieldBreakdown byClass={yieldResult.by_class} />
              )}
            </>
          )}
        </section>

        <footer className="p-3 border-t border-gray-800 text-[10px] text-gray-600 text-center">
          historical data only · 32,186 meteorites · NASA Open Data ·{" "}
          <a
            href={`${API_BASE}/docs`}
            target="_blank"
            rel="noreferrer"
            className="underline hover:text-gray-400"
          >
            API docs
          </a>
        </footer>
      </aside>
    </div>
  );
}
