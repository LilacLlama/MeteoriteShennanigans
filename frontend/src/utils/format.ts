// Shared display formatters. Keep formatting consistent across the map
// popup, sidebar yield, heatmap tooltip — one definition, one rounding rule.

export function massLabel(g: number | null): string {
  if (g == null) return "Unknown";
  if (g >= 1_000_000) return `${(g / 1_000_000).toFixed(1)} t`;
  if (g >= 1_000) return `${(g / 1_000).toFixed(1)} kg`;
  return `${Math.round(g)} g`;
}
