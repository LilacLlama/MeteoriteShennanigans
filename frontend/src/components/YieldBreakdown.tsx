import { useEffect, useState } from "react";
import { massLabel } from "../lib/format";
import type { MagneticTier, YieldClassRow } from "../types";

const TIER_CHIP: Record<MagneticTier, string> = {
  strong: "bg-pink-500/20 text-pink-300",
  medium: "bg-amber-500/20 text-amber-300",
  weak: "bg-sky-500/20 text-sky-300",
  none: "bg-gray-700/40 text-gray-500",
};

type YieldSort = "iron" | "count";
type YieldView = "caught" | "missed";

interface Props {
  byClass: YieldClassRow[];
}

export default function YieldBreakdown({ byClass }: Props) {
  const [view, setView] = useState<YieldView>("caught");
  const [sort, setSort] = useState<YieldSort>("iron");

  const caught = byClass.filter((r) => r.magnetic_tier !== "none");
  const missed = byClass.filter((r) => r.magnetic_tier === "none");

  // Snap back to 'caught' if the active view becomes empty (e.g. user
  // removed the only achondrite-containing magnet).
  useEffect(() => {
    if (view === "missed" && missed.length === 0) setView("caught");
  }, [view, missed.length]);

  const rows = view === "caught" ? caught : missed;
  const sorted = [...rows].sort((a, b) =>
    view === "missed"
      ? b.count - a.count || b.total_mass_g - a.total_mass_g
      : sort === "iron"
        ? b.iron_mass_g - a.iron_mass_g || b.count - a.count
        : b.count - a.count || b.iron_mass_g - a.iron_mass_g,
  );

  return (
    <>
      <div className="flex items-center justify-between mb-2 gap-2">
        <div className="flex gap-1 text-[10px]">
          <button
            onClick={() => setView("caught")}
            className={`px-2 py-0.5 rounded uppercase tracking-wider font-medium transition ${
              view === "caught"
                ? "bg-pink-500/20 text-pink-300"
                : "text-gray-500 hover:text-gray-300"
            }`}
          >
            Caught ({caught.length})
          </button>
          {missed.length > 0 && (
            <button
              onClick={() => setView("missed")}
              className={`px-2 py-0.5 rounded uppercase tracking-wider font-medium transition ${
                view === "missed"
                  ? "bg-gray-700/60 text-gray-300"
                  : "text-gray-500 hover:text-gray-300"
              }`}
            >
              Missed ({missed.length})
            </button>
          )}
        </div>
        {view === "caught" && (
          <div className="flex gap-1 text-[10px]">
            {(["iron", "count"] as YieldSort[]).map((s) => (
              <button
                key={s}
                onClick={() => setSort(s)}
                className={`px-2 py-0.5 rounded transition ${
                  sort === s
                    ? "bg-pink-500/20 text-pink-300"
                    : "text-gray-500 hover:text-gray-300"
                }`}
              >
                {s}
              </button>
            ))}
          </div>
        )}
      </div>

      {view === "missed" && (
        <p className="text-[10px] text-gray-500 mb-2 italic leading-relaxed">
          In range but not magnetically catchable — differentiated parent
          bodies (Moon, Mars, Vesta) have no free iron.
        </p>
      )}

      <ul className="space-y-1 text-xs">
        {sorted.map((row) => (
          <li
            key={row.class_group}
            className="flex items-center justify-between bg-gray-800/40 rounded px-2 py-1 gap-2"
          >
            <span className="flex items-center gap-2 min-w-0">
              <span className="font-mono text-gray-300 truncate">
                {row.class_group}
              </span>
              <span
                className={`text-[9px] px-1.5 py-0.5 rounded uppercase tracking-wider font-medium shrink-0 ${TIER_CHIP[row.magnetic_tier]}`}
              >
                {row.magnetic_tier}
              </span>
            </span>
            <span className="text-gray-400 text-right shrink-0">
              <span className="text-gray-500">{row.count.toLocaleString()}</span>{" "}
              ·{" "}
              {massLabel(
                view === "missed" ? row.total_mass_g : row.iron_mass_g,
              )}
            </span>
          </li>
        ))}
      </ul>
    </>
  );
}
