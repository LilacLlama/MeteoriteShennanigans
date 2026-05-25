import { useEffect, useRef } from "react";
import { MapContainer, TileLayer, CircleMarker, Popup, useMap } from "react-leaflet";
import MarkerClusterGroup from "react-leaflet-cluster";
import type { MeteoritePoint } from "../types";

interface Props {
  points: MeteoritePoint[];
  selectedId: number | null;
  onSelect: (m: MeteoritePoint) => void;
}

// Fly to selected meteorite when selectedId changes
function FlyTo({ points, selectedId }: { points: MeteoritePoint[]; selectedId: number | null }) {
  const map = useMap();
  useEffect(() => {
    if (selectedId == null) return;
    const point = points.find((p) => p.id === selectedId);
    if (point) {
      map.flyTo([point.reclat, point.reclong], 6, { duration: 1.2 });
    }
  }, [selectedId, points, map]);
  return null;
}

function massLabel(g: number | null): string {
  if (g == null) return "Unknown mass";
  if (g >= 1_000_000) return `${(g / 1_000_000).toFixed(1)} t`;
  if (g >= 1_000) return `${(g / 1_000).toFixed(1)} kg`;
  return `${g} g`;
}

function markerColor(fall: string | null): string {
  return fall === "Fell" ? "#f97316" : "#60a5fa"; // orange = witnessed, blue = found
}

export default function Map({ points, selectedId, onSelect }: Props) {
  return (
    <MapContainer
      center={[20, 0]}
      zoom={2}
      minZoom={2}
      maxZoom={14}
      className="h-full w-full"
    >
      <TileLayer
        url="https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
        attribution='&copy; <a href="https://carto.com/">CARTO</a>'
      />

      <FlyTo points={points} selectedId={selectedId} />

      <MarkerClusterGroup
        chunkedLoading
        maxClusterRadius={40}
      >
        {points.map((m) => (
          <CircleMarker
            key={m.id}
            center={[m.reclat, m.reclong]}
            radius={selectedId === m.id ? 8 : 4}
            pathOptions={{
              color: markerColor(m.fall),
              fillColor: markerColor(m.fall),
              fillOpacity: selectedId === m.id ? 1 : 0.7,
              weight: selectedId === m.id ? 2 : 0,
            }}
            eventHandlers={{ click: () => onSelect(m) }}
          >
            <Popup>
              <div className="text-sm font-sans">
                <p className="font-bold text-gray-900">{m.name}</p>
                <p className="text-gray-600">{m.recclass ?? "Unknown class"}</p>
                <p className="text-gray-600">{massLabel(m.mass_g)}</p>
                <p className="text-gray-600">{m.year ?? "Year unknown"} · {m.fall}</p>
              </div>
            </Popup>
          </CircleMarker>
        ))}
      </MarkerClusterGroup>
    </MapContainer>
  );
}
