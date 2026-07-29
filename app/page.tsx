"use client";

import mapboxgl from "mapbox-gl";
import "mapbox-gl/dist/mapbox-gl.css";
import { useEffect, useRef, useState } from "react";
import { colorizeRoute, routeCurveMidpoint, type Coordinate, type CurveSegment } from "../lib/curves";

type RoadEvent = { id: string; type: "stop" | "signal" | "arterial"; coordinate: Coordinate; name?: string };
type RouteResult = { id: string; coordinates: Coordinate[]; distanceMeters: number; durationSeconds: number; curves: CurveSegment[]; roadEvents?: RoadEvent[]; elevations?: number[] };
const metres = (value: number) => `${Math.round(value)} m`;
const miles = (value: number) => `${(value / 1609.344).toFixed(1)} mi`;
const duration = (value: number) => `${Math.floor(value / 60)} min`;

export default function Home() {
  const mapRef = useRef<mapboxgl.Map | null>(null);
  const mapNode = useRef<HTMLDivElement | null>(null);
  const curveMarkers = useRef<mapboxgl.Marker[]>([]);
  const stopMarkers = useRef<mapboxgl.Marker[]>([]);
  const eventMarkers = useRef<mapboxgl.Marker[]>([]);
  const elevationMarker = useRef<mapboxgl.Marker | null>(null);
  const stopsRef = useRef<Coordinate[]>([]);
  const undoRef = useRef<() => void>(() => {});
  const [mapToken, setMapToken] = useState<string | null>(null);
  const [tokenLoaded, setTokenLoaded] = useState(false);
  const [stops, setStops] = useState<Coordinate[]>([]);
  const [routes, setRoutes] = useState<RouteResult[]>([]);
  const [routeIndex, setRouteIndex] = useState(0);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [showWaypoints, setShowWaypoints] = useState(true);
  const [showCurveMarkers, setShowCurveMarkers] = useState(true);
  const [elevationIndex, setElevationIndex] = useState(0);
  const route = routes[routeIndex];

  useEffect(() => {
    fetch("/api/config/mapbox").then((response) => response.json()).then((data: { token?: string | null }) => setMapToken(data.token || null)).catch(() => setMapToken(null)).finally(() => setTokenLoaded(true));
  }, []);

  function renderStopMarkers(nextStops: Coordinate[]) {
    const map = mapRef.current;
    if (!map) return;
    stopMarkers.current.forEach((marker) => marker.remove());
    stopMarkers.current = nextStops.flatMap((stop, index) => {
      if (index > 0 && index < nextStops.length - 1 && !showWaypoints) return [];
      const element = document.createElement("button");
      element.type = "button";
      element.className = `route-stop ${index === 0 ? "start" : index === nextStops.length - 1 ? "end" : "via"}`;
      element.setAttribute("aria-label", index === 0 ? "Route start" : index === nextStops.length - 1 ? "Route end" : `Waypoint ${index}`);
      element.onclick = (event) => { event.stopPropagation(); removeStop(index); };
      return [new mapboxgl.Marker({ element }).setLngLat(stop).addTo(map)];
    });
  }

  // Marker visibility is a presentation-only toggle; the current points live in a ref.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { renderStopMarkers(stopsRef.current); }, [showWaypoints]);

  async function routeStops(nextStops: Coordinate[]) {
    if (nextStops.length < 2) return;
    setError(""); setLoading(true); setSelectedId(null);
    try {
      const response = await fetch("/api/routes/analyze", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ stops: nextStops }) });
      const result = await response.json() as { routes?: RouteResult[]; snappedStops?: Coordinate[]; error?: string };
      if (!response.ok || !result.routes) throw new Error(result.error || "Unable to snap this route to roads.");
      if (result.snappedStops?.length === nextStops.length) {
        stopsRef.current = result.snappedStops;
        setStops(result.snappedStops);
        renderStopMarkers(result.snappedStops);
      }
      setRoutes(result.routes); setRouteIndex(0);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to snap this route to roads."); }
    finally { setLoading(false); }
  }

  function addStop(coordinate: Coordinate) {
    const nextStops = [...stopsRef.current, coordinate];
    stopsRef.current = nextStops;
    setStops(nextStops);
    renderStopMarkers(nextStops);
    void routeStops(nextStops);
  }

  function removeStop(index: number) {
    if (index < 0 || index >= stopsRef.current.length) return;
    const nextStops = stopsRef.current.filter((_, stopIndex) => stopIndex !== index);
    stopsRef.current = nextStops; setStops(nextStops); setSelectedId(null); renderStopMarkers(nextStops);
    if (nextStops.length < 2) {
      setRoutes([]); setRouteIndex(0);
      const source = mapRef.current?.getSource("route-segments") as mapboxgl.GeoJSONSource | undefined;
      source?.setData({ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: [] } });
    } else void routeStops(nextStops);
  }

  undoRef.current = () => removeStop(stopsRef.current.length - 1);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z") { event.preventDefault(); undoRef.current(); }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  function resetRoute() {
    stopsRef.current = []; setStops([]); setRoutes([]); setRouteIndex(0); setSelectedId(null); setError("");
    stopMarkers.current.forEach((marker) => marker.remove()); stopMarkers.current = [];
    curveMarkers.current.forEach((marker) => marker.remove()); curveMarkers.current = [];
    const source = mapRef.current?.getSource("route-segments") as mapboxgl.GeoJSONSource | undefined;
    source?.setData({ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: [] } });
    const routeSegmentsSource = mapRef.current?.getSource("route-segments") as mapboxgl.GeoJSONSource | undefined;
    routeSegmentsSource?.setData({ type: "FeatureCollection", features: [] });
    eventMarkers.current.forEach((marker) => marker.remove()); eventMarkers.current = [];
    elevationMarker.current?.remove(); elevationMarker.current = null;
  }

  useEffect(() => {
    if (!mapNode.current || !mapToken || mapRef.current) return;
    mapboxgl.accessToken = mapToken;
    // Use the core Streets style: the navigation style requests optional live
    // traffic/incident tiles that can fail independently and leave an empty canvas.
    const map = new mapboxgl.Map({ container: mapNode.current, style: "mapbox://styles/mapbox/streets-v12", center: [-122.4194, 37.7749], zoom: 10, attributionControl: false, preserveDrawingBuffer: true });
    map.addControl(new mapboxgl.NavigationControl({ showCompass: false }), "bottom-right");
    map.on("load", () => {
      map.addSource("route-segments", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
      map.addLayer({ id: "route-line", type: "line", source: "route-segments", paint: { "line-color": ["match", ["get", "color"], "blue", "#2878ee", "red", "#e34242", "#101b1e"], "line-width": 6, "line-opacity": .98 } });
      map.on("click", (event) => {
        const curveFeature = map.queryRenderedFeatures(event.point, { layers: ["route-line"] })[0];
        const curveId = curveFeature?.properties?.curveId as string | undefined;
        const curve = routeRef.current?.curves.find((item) => item.id === curveId);
        if (curve) selectCurve(curve); else addStop([event.lngLat.lng, event.lngLat.lat]);
      });
    });
    mapRef.current = map;
    return () => { map.remove(); mapRef.current = null; };
  // addStop uses refs and state setters; recreating the map would be incorrect.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mapToken]);

  const routeRef = useRef<RouteResult | undefined>(undefined);
  routeRef.current = route;

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !route || !map.isStyleLoaded()) return;
    const source = map.getSource("route-segments") as mapboxgl.GeoJSONSource | undefined;
    source?.setData({ type: "FeatureCollection", features: colorizeRoute(route.coordinates, route.curves).map((segment) => ({ type: "Feature", properties: { curveId: segment.curveId, color: segment.color }, geometry: { type: "LineString", coordinates: segment.coordinates } })) });
    eventMarkers.current.forEach((marker) => marker.remove());
    eventMarkers.current = (route.roadEvents || []).map((event) => {
      const element = document.createElement("span"); element.className = `road-event-marker ${event.type}`; element.textContent = event.type === "stop" ? "STOP" : event.type === "signal" ? "●" : "＋"; element.title = event.name || (event.type === "stop" ? "Stop sign" : event.type === "signal" ? "Traffic signal" : "Major arterial");
      return new mapboxgl.Marker({ element }).setLngLat(event.coordinate).addTo(map);
    });
    const elevation = route.elevations || [];
    const elevationCoordinate = elevation.length ? route.coordinates[Math.min(route.coordinates.length - 1, Math.round((elevationIndex / Math.max(1, elevation.length - 1)) * (route.coordinates.length - 1)))] : null;
    elevationMarker.current?.remove();
    if (elevationCoordinate) {
      const element = document.createElement("span"); element.className = "elevation-marker";
      elevationMarker.current = new mapboxgl.Marker({ element }).setLngLat(elevationCoordinate).addTo(map);
    }
    curveMarkers.current.forEach((marker) => marker.remove());
    curveMarkers.current = showCurveMarkers ? route.curves.map((curve, index) => {
      const element = document.createElement("button"); element.className = "curve-marker"; element.innerText = String(index + 1);
      element.onclick = (event) => { event.stopPropagation(); selectCurve(curve); };
      return new mapboxgl.Marker({ element }).setLngLat(routeCurveMidpoint(route.coordinates, curve)).addTo(map);
    }) : [];
  }, [route, showCurveMarkers, elevationIndex]);

  function selectCurve(curve: CurveSegment) {
    setSelectedId(curve.id);
    mapRef.current?.fitBounds(new mapboxgl.LngLatBounds(curve.start, curve.end), { padding: 120, maxZoom: 15, duration: 450 });
  }

  function exportRoute() {
    const map = mapRef.current;
    if (!map || !route) return;
    const mapCanvas = map.getCanvas();
    const width = 1600;
    const mapHeight = Math.round((mapCanvas.height / mapCanvas.width) * width);
    const rows = route.curves.slice(0, 24);
    const canvas = document.createElement("canvas");
    const columns = 3; const rowHeight = 38;
    canvas.width = width; canvas.height = mapHeight + 170 + Math.ceil(rows.length / columns) * rowHeight;
    const context = canvas.getContext("2d");
    if (!context) return;
    context.fillStyle = "#f0f0e8"; context.fillRect(0, 0, width, canvas.height);
    context.drawImage(mapCanvas, 0, 0, width, mapHeight);
    context.fillStyle = "#102023"; context.fillRect(0, mapHeight, width, canvas.height - mapHeight);
    context.fillStyle = "#dbff52"; context.font = "700 28px sans-serif"; context.fillText("APEX PACE NOTES", 54, mapHeight + 54);
    context.fillStyle = "#eaf0e9"; context.font = "600 22px sans-serif"; context.fillText(`${miles(route.distanceMeters)} · ${duration(route.durationSeconds)} · ${route.curves.length} curves`, 54, mapHeight + 94);
    context.font = "500 20px sans-serif";
    const columnWidth = Math.floor((width - 108) / columns);
    rows.forEach((curve, index) => { const column = index % columns; const row = Math.floor(index / columns); context.fillText(`${String(index + 1).padStart(2, "0")} ${curve.label.toUpperCase()} · ${metres(curve.lengthMeters)} · ${Math.round(curve.headingChangeDegrees)}°`, 54 + column * columnWidth, mapHeight + 145 + row * rowHeight); });
    const link = document.createElement("a"); link.download = "apex-pace-notes.png"; link.href = canvas.toDataURL("image/png"); link.click();
  }

  const selected = route?.curves.find((curve) => curve.id === selectedId);
  return <main>
    <section className="control-panel">
      <div className="brand"><span className="brand-mark">↝</span><span>APEX<br /><strong>PACE NOTES</strong></span></div>
      <div className="eyebrow">Route intelligence / beta</div>
      <h1>Know the bend<br /><em>before</em> it arrives.</h1>
      <p className="intro">Click the map to place a start, then an end. Keep clicking to turn the previous end into a waypoint and extend the route.</p>
      <div className="click-status"><span>{stops.length === 0 ? "1" : stops.length + 1}</span><p>{stops.length === 0 ? "Click anywhere to set your start." : stops.length === 1 ? "Click again to set the end." : `${stops.length - 2} waypoint${stops.length === 3 ? "" : "s"} · click to extend`}</p></div>
      <button className="reset" onClick={resetRoute} disabled={stops.length === 0}>Clear route</button>
      <p className="shortcut">Ctrl / ⌘ + Z removes the last point. Click any point to remove it.</p>
      {loading && <p className="setup-note">Snapping to the road…</p>}
      {error && <p className="error" role="alert">{error}</p>}
      {!mapToken && tokenLoaded && <p className="error">Mapbox is not configured.</p>}
    </section>
    <section className="map-area">
      <div ref={mapNode} className="map" aria-label="Route map. Click to place route points." />
      {tokenLoaded && !mapToken && <div className="map-placeholder"><span>MAPBOX REQUIRED</span><p>Add the project’s Mapbox environment variables to enable map clicks and route planning.</p></div>}
      {route && <div className="route-summary"><span>FASTEST ROUTE</span><strong>{miles(route.distanceMeters)} <i>·</i> {duration(route.durationSeconds)}</strong><small>{route.curves.length} detected curves</small>{routes.length > 1 && <select value={routeIndex} onChange={(event) => { setRouteIndex(Number(event.target.value)); setSelectedId(null); }} aria-label="Choose route alternative">{routes.map((option, index) => <option value={index} key={option.id}>Option {index + 1} · {duration(option.durationSeconds)}</option>)}</select>}</div>}
      <details className="layers"><summary>Layers</summary><label><input type="checkbox" checked={showWaypoints} onChange={(event) => setShowWaypoints(event.target.checked)} /> Waypoints</label><label><input type="checkbox" checked={showCurveMarkers} onChange={(event) => setShowCurveMarkers(event.target.checked)} /> Pace numbers</label></details>
      {route && <button className="export-route" onClick={exportRoute}>Export route PNG</button>}
      {route?.elevations?.length ? <div className="elevation-card"><span>ELEVATION PROFILE</span><svg viewBox="0 0 300 74" role="img" aria-label="Elevation profile"><polyline points={route.elevations.map((value, index) => `${(index / Math.max(1, route.elevations!.length - 1)) * 300},${70 - ((value - Math.min(...route.elevations!)) / Math.max(1, Math.max(...route.elevations!) - Math.min(...route.elevations!))) * 58}`).join(" ")} /><circle cx={(elevationIndex / Math.max(1, route.elevations.length - 1)) * 300} cy={70 - ((route.elevations[elevationIndex] - Math.min(...route.elevations)) / Math.max(1, Math.max(...route.elevations) - Math.min(...route.elevations))) * 58} r="5" /></svg><input type="range" min="0" max={Math.max(0, route.elevations.length - 1)} value={elevationIndex} onChange={(event) => setElevationIndex(Number(event.target.value))} aria-label="Scrub elevation profile" /><small>{route.elevations[elevationIndex] ?? route.elevations[0]} m</small></div> : null}
      {selected && <article className="curve-card"><span>CURVE {route!.curves.findIndex((curve) => curve.id === selected.id) + 1}</span><h2>{selected.label}</h2><dl><div><dt>Length</dt><dd>{metres(selected.lengthMeters)}</dd></div><div><dt>Heading</dt><dd>{Math.round(selected.headingChangeDegrees)}°</dd></div><div><dt>Modifier</dt><dd>None</dd></div></dl></article>}
    </section>
    <aside className="curve-list" aria-label="Detected curves">
      <div className="list-heading"><span>PACE NOTES</span><strong>{route ? `${route.curves.length} calls` : "Awaiting route"}</strong></div>
      <div className="scrolling-notes">{route ? <>{(route.roadEvents || []).map((event) => <div className="context-row" key={event.id}><b>{event.type === "stop" ? "STOP" : event.type === "signal" ? "LIGHT" : "ROAD"}</b><span><strong>{event.name || (event.type === "stop" ? "Stop sign" : event.type === "signal" ? "Traffic signal" : "Major intersection")}</strong><small>Road context</small></span></div>)}{route.curves.map((curve, index) => <button key={curve.id} className={selectedId === curve.id ? "curve-row active" : "curve-row"} onClick={() => selectCurve(curve)}><b>{String(index + 1).padStart(2, "0")}</b><span><strong>{curve.label}</strong><small>{metres(curve.lengthMeters)} · {Math.round(curve.headingChangeDegrees)}°</small></span><i>{curve.direction === "left" ? "↙" : "↘"}</i></button>)}</> : <div className="empty-list">Your route’s curve calls will appear here in driving order.</div>}</div>
    </aside>
  </main>;
}
