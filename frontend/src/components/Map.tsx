import { useEffect, useMemo } from "react";
import {
  MapContainer,
  TileLayer,
  CircleMarker,
  Circle,
  Popup,
  useMap,
  useMapEvents,
} from "react-leaflet";
import MarkerClusterGroup from "react-leaflet-cluster";
import type { Magnet, MagnetRadiiKm, MeteoritePoint, S2HeatCell, ViewMode } from "../types";
import { massLabel } from "../lib/format";
import HeatmapLayer from "./HeatmapLayer";

interface Props {
  points: MeteoritePoint[];
  selectedId: number | null;
  onSelect: (m: MeteoritePoint) => void;
  magnets: Magnet[];
  radii: MagnetRadiiKm;
  onPlaceMagnet: (lat: number, lon: number) => void;
  onRemoveMagnet: (id: string) => void;
  viewMode: ViewMode;
  heatCells: S2HeatCell[];
}

function FlyTo({
  points,
  selectedId,
}: {
  points: MeteoritePoint[];
  selectedId: number | null;
}) {
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

function ClickHandler({ onPlace }: { onPlace: (lat: number, lon: number) => void }) {
  useMapEvents({
    click(e) {
      onPlace(e.latlng.lat, e.latlng.lng);
    },
  });
  return null;
}

function markerColor(fall: string | null): string {
  return fall === "Fell" ? "#f97316" : "#60a5fa";
}

export default function Map({
  points,
  selectedId,
  onSelect,
  magnets,
  radii,
  onPlaceMagnet,
  onRemoveMagnet,
  viewMode,
  heatCells,
}: Props) {
  // Memoised so adding/removing magnets doesn't re-cluster the 38k meteorites.
  // `onSelect` is assumed stable (useCallback in App.tsx) — if upstream drops
  // that, every magnet placement will re-cluster again.
  const clusterLayer = useMemo(
    () => (
      <MarkerClusterGroup chunkedLoading maxClusterRadius={40}>
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
                <p className="text-gray-600">
                  {m.year ?? "Year unknown"} · {m.fall}
                </p>
              </div>
            </Popup>
          </CircleMarker>
        ))}
      </MarkerClusterGroup>
    ),
    [points, selectedId, onSelect],
  );

  return (
    <MapContainer
      center={[20, 0]}
      zoom={2}
      minZoom={2}
      maxZoom={14}
      preferCanvas={true}
      className="h-full w-full"
    >
      <TileLayer
        url="https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
        attribution='&copy; <a href="https://carto.com/">CARTO</a>'
      />

      <FlyTo points={points} selectedId={selectedId} />
      <ClickHandler onPlace={onPlaceMagnet} />

      {viewMode === "markers" ? clusterLayer : <HeatmapLayer cells={heatCells} />}

      {magnets.map((mag) => (
        <Circle
          key={mag.id}
          center={[mag.lat, mag.lon]}
          radius={radii[mag.size] * 1000}
          pathOptions={{
            color: "#ec4899",
            fillColor: "#ec4899",
            fillOpacity: 0.18,
            weight: 2,
          }}
          eventHandlers={{ click: () => onRemoveMagnet(mag.id) }}
        >
          <Popup>
            <div className="text-sm font-sans">
              <p className="font-bold text-gray-900">Magnet ({mag.size})</p>
              <p className="text-gray-600">Radius: {radii[mag.size]} km</p>
              <p className="text-gray-500 italic text-xs mt-1">
                Click again to remove
              </p>
            </div>
          </Popup>
        </Circle>
      ))}
    </MapContainer>
  );
}
