"use client";

import mapboxgl from "mapbox-gl";
import "mapbox-gl/dist/mapbox-gl.css";
import { FormEvent, useEffect, useRef, useState } from "react";
import type { Coordinate, CurveSegment } from "../lib/curves";

type RouteResult = { id: string; coordinates: Coordinate[]; distanceMeters: number; durationSeconds: number; curves: CurveSegment[] };

const metres = (value: number) => value >= 1000 ? `${(value / 1000).toFixed(1)} km` : `${value} m`;
const duration = (value: number) => `${Math.floor(value / 60)} min`;

export default function Home() {
  const mapRef = useRef<mapboxgl.Map | null>(null);
  const mapNode = useRef<HTMLDivElement | null>(null);
  const markers = useRef<mapboxgl.Marker[]>([]);
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [waypoints, setWaypoints] = useState<string[]>([]);
  const [routes, setRoutes] = useState<RouteResult[]>([]);
  const [routeIndex, setRouteIndex] = useState(0);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const token = process.env.NEXT_PUBLIC_MAPBOX_ACCESS_TOKEN;
  const route = routes[routeIndex];

  useEffect(() => {
    if (!mapNode.current || !token || mapRef.current) return;
    mapboxgl.accessToken = token;
    const map = new mapboxgl.Map({ container: mapNode.current, style: "mapbox://styles/mapbox/navigation-night-v1", center: [-122.4194, 37.7749], zoom: 10, attributionControl: false });
    map.addControl(new mapboxgl.NavigationControl({ showCompass: false }), "bottom-right");
    map.on("load", () => {
      map.addSource("route", { type: "geojson", data: { type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: [] } } });
      map.addLayer({ id: "route-shadow", type: "line", source: "route", paint: { "line-color": "#071419", "line-width": 11, "line-opacity": 0.8 } });
      map.addLayer({ id: "route-line", type: "line", source: "route", paint: { "line-color": "#e3ff68", "line-width": 5 } });
    });
    mapRef.current = map;
    return () => { map.remove(); mapRef.current = null; };
  }, [token]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !route || !map.isStyleLoaded()) return;
    const source = map.getSource("route") as mapboxgl.GeoJSONSource | undefined;
    source?.setData({ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: route.coordinates } });
    markers.current.forEach((marker) => marker.remove());
    markers.current = route.curves.map((curve, index) => {
      const element = document.createElement("button");
      element.className = `curve-marker${selectedId === curve.id ? " selected" : ""}`;
      element.innerText = String(index + 1);
      element.setAttribute("aria-label", `Select ${curve.label}`);
      element.onclick = () => selectCurve(curve);
      return new mapboxgl.Marker({ element }).setLngLat(curve.start).addTo(map);
    });
    const bounds = route.coordinates.reduce((box, coordinate) => box.extend(coordinate), new mapboxgl.LngLatBounds(route.coordinates[0], route.coordinates[0]));
    map.fitBounds(bounds, { padding: 80, duration: 650 });
  // selectedId is intentionally omitted: markers refresh only on a new route.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [route]);

  function selectCurve(curve: CurveSegment) {
    setSelectedId(curve.id);
    const map = mapRef.current;
    if (map) map.fitBounds(new mapboxgl.LngLatBounds(curve.start, curve.end), { padding: 120, maxZoom: 15, duration: 450 });
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    setError(""); setLoading(true); setSelectedId(null);
    try {
      const response = await fetch("/api/routes/analyze", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ start, end, waypoints }) });
      const result = await response.json() as { routes?: RouteResult[]; error?: string };
      if (!response.ok || !result.routes) throw new Error(result.error || "Unable to plan this route.");
      setRoutes(result.routes); setRouteIndex(0);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to plan this route."); }
    finally { setLoading(false); }
  }

  const selected = route?.curves.find((curve) => curve.id === selectedId);
  return <main>
    <section className="control-panel">
      <div className="brand"><span className="brand-mark">↝</span><span>APEX<br /><strong>PACE NOTES</strong></span></div>
      <div className="eyebrow">Route intelligence / v1</div>
      <h1>Know the bend<br /><em>before</em> it arrives.</h1>
      <p className="intro">Build an ETA-fastest driving route, then inspect its rally-style curve calls one corner at a time.</p>
      <form onSubmit={submit}>
        <label>Start<input value={start} onChange={(event) => setStart(event.target.value)} placeholder="e.g. Portland, OR" required /></label>
        {waypoints.map((waypoint, index) => <label key={index}>Via {index + 1}<span className="input-row"><input value={waypoint} onChange={(event) => setWaypoints(waypoints.map((point, pointIndex) => pointIndex === index ? event.target.value : point))} placeholder="Optional stop" /><button className="remove" type="button" onClick={() => setWaypoints(waypoints.filter((_, pointIndex) => pointIndex !== index))}>×</button></span></label>)}
        <button className="add-stop" type="button" onClick={() => setWaypoints([...waypoints, ""])}>+ Add waypoint</button>
        <label>Finish<input value={end} onChange={(event) => setEnd(event.target.value)} placeholder="e.g. Mount Hood, OR" required /></label>
        <button className="plan" disabled={loading}>{loading ? "Reading road geometry…" : "Generate pace notes"}</button>
      </form>
      {error && <p className="error" role="alert">{error}</p>}
      <p className="setup-note">{token ? "Map ready — routes are analyzed on demand." : "Add Mapbox tokens to enable the live map and routing."}</p>
    </section>
    <section className="map-area">
      <div ref={mapNode} className="map" aria-label="Route map" />
      {!token && <div className="map-placeholder"><span>MAPBOX REQUIRED</span><p>Set <code>NEXT_PUBLIC_MAPBOX_ACCESS_TOKEN</code> and <code>MAPBOX_ACCESS_TOKEN</code> to start planning.</p></div>}
      {route && <div className="route-summary"><span>FASTEST ROUTE</span><strong>{metres(route.distanceMeters)} <i>·</i> {duration(route.durationSeconds)}</strong><small>{route.curves.length} detected curves</small>{routes.length > 1 && <select value={routeIndex} onChange={(event) => { setRouteIndex(Number(event.target.value)); setSelectedId(null); }} aria-label="Choose route alternative">{routes.map((option, index) => <option value={index} key={option.id}>Option {index + 1} · {duration(option.durationSeconds)}</option>)}</select>}</div>}
      {selected && <article className="curve-card"><span>CURVE {route!.curves.findIndex((curve) => curve.id === selected.id) + 1}</span><h2>{selected.label}</h2><dl><div><dt>Length</dt><dd>{metres(selected.lengthMeters)}</dd></div><div><dt>Heading change</dt><dd>{selected.headingChangeDegrees}°</dd></div><div><dt>Modifier</dt><dd>None</dd></div></dl><p>Score {selected.rating} · curvature {selected.averageCurvature}°/m</p></article>}
    </section>
    <aside className="curve-list" aria-label="Detected curves">
      <div className="list-heading"><span>PACE NOTES</span><strong>{route ? `${route.curves.length} calls` : "Awaiting route"}</strong></div>
      {route ? route.curves.map((curve, index) => <button key={curve.id} className={selectedId === curve.id ? "curve-row active" : "curve-row"} onClick={() => selectCurve(curve)}><b>{String(index + 1).padStart(2, "0")}</b><span><strong>{curve.label}</strong><small>{metres(curve.lengthMeters)} · {curve.headingChangeDegrees}°</small></span><i>{curve.direction === "left" ? "↙" : "↘"}</i></button>) : <div className="empty-list">Your route’s curve calls will appear here in driving order.</div>}
    </aside>
  </main>;
}
