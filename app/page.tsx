"use client";

import mapboxgl from "mapbox-gl";
import "mapbox-gl/dist/mapbox-gl.css";
import { useEffect, useRef, useState } from "react";
import type { Coordinate, CurveSegment } from "../lib/curves";

type RouteResult = { id: string; coordinates: Coordinate[]; distanceMeters: number; durationSeconds: number; curves: CurveSegment[] };
const metres = (value: number) => value >= 1000 ? `${(value / 1000).toFixed(1)} km` : `${value} m`;
const duration = (value: number) => `${Math.floor(value / 60)} min`;

export default function Home() {
  const mapRef = useRef<mapboxgl.Map | null>(null);
  const mapNode = useRef<HTMLDivElement | null>(null);
  const curveMarkers = useRef<mapboxgl.Marker[]>([]);
  const stopMarkers = useRef<mapboxgl.Marker[]>([]);
  const stopsRef = useRef<Coordinate[]>([]);
  const [mapToken, setMapToken] = useState<string | null>(null);
  const [tokenLoaded, setTokenLoaded] = useState(false);
  const [stops, setStops] = useState<Coordinate[]>([]);
  const [routes, setRoutes] = useState<RouteResult[]>([]);
  const [routeIndex, setRouteIndex] = useState(0);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const route = routes[routeIndex];

  useEffect(() => {
    fetch("/api/config/mapbox").then((response) => response.json()).then((data: { token?: string | null }) => setMapToken(data.token || null)).catch(() => setMapToken(null)).finally(() => setTokenLoaded(true));
  }, []);

  function renderStopMarkers(nextStops: Coordinate[]) {
    const map = mapRef.current;
    if (!map) return;
    stopMarkers.current.forEach((marker) => marker.remove());
    stopMarkers.current = nextStops.map((stop, index) => {
      const element = document.createElement("span");
      element.className = `route-stop ${index === 0 ? "start" : index === nextStops.length - 1 ? "end" : "via"}`;
      element.setAttribute("aria-label", index === 0 ? "Route start" : index === nextStops.length - 1 ? "Route end" : `Waypoint ${index}`);
      return new mapboxgl.Marker({ element }).setLngLat(stop).addTo(map);
    });
  }

  async function routeStops(nextStops: Coordinate[]) {
    if (nextStops.length < 2) return;
    setError(""); setLoading(true); setSelectedId(null);
    try {
      const response = await fetch("/api/routes/analyze", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ stops: nextStops }) });
      const result = await response.json() as { routes?: RouteResult[]; error?: string };
      if (!response.ok || !result.routes) throw new Error(result.error || "Unable to snap this route to roads.");
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

  function resetRoute() {
    stopsRef.current = []; setStops([]); setRoutes([]); setRouteIndex(0); setSelectedId(null); setError("");
    stopMarkers.current.forEach((marker) => marker.remove()); stopMarkers.current = [];
    curveMarkers.current.forEach((marker) => marker.remove()); curveMarkers.current = [];
    const source = mapRef.current?.getSource("route") as mapboxgl.GeoJSONSource | undefined;
    source?.setData({ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: [] } });
  }

  useEffect(() => {
    if (!mapNode.current || !mapToken || mapRef.current) return;
    mapboxgl.accessToken = mapToken;
    const map = new mapboxgl.Map({ container: mapNode.current, style: "mapbox://styles/mapbox/navigation-night-v1", center: [-122.4194, 37.7749], zoom: 10, attributionControl: false });
    map.addControl(new mapboxgl.NavigationControl({ showCompass: false }), "bottom-right");
    map.on("load", () => {
      map.addSource("route", { type: "geojson", data: { type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: [] } } });
      map.addLayer({ id: "route-line", type: "line", source: "route", paint: { "line-color": "#101b1e", "line-width": 5, "line-opacity": .94 } });
      map.on("click", (event) => addStop([event.lngLat.lng, event.lngLat.lat]));
    });
    mapRef.current = map;
    return () => { map.remove(); mapRef.current = null; };
  // addStop uses refs and state setters; recreating the map would be incorrect.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mapToken]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !route || !map.isStyleLoaded()) return;
    const source = map.getSource("route") as mapboxgl.GeoJSONSource | undefined;
    source?.setData({ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: route.coordinates } });
    curveMarkers.current.forEach((marker) => marker.remove());
    curveMarkers.current = route.curves.map((curve, index) => {
      const element = document.createElement("button"); element.className = "curve-marker"; element.innerText = String(index + 1);
      element.onclick = () => selectCurve(curve);
      return new mapboxgl.Marker({ element }).setLngLat(curve.start).addTo(map);
    });
  }, [route]);

  function selectCurve(curve: CurveSegment) {
    setSelectedId(curve.id);
    mapRef.current?.fitBounds(new mapboxgl.LngLatBounds(curve.start, curve.end), { padding: 120, maxZoom: 15, duration: 450 });
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
      {loading && <p className="setup-note">Snapping to the road…</p>}
      {error && <p className="error" role="alert">{error}</p>}
      {!mapToken && tokenLoaded && <p className="error">Mapbox is not configured.</p>}
    </section>
    <section className="map-area">
      <div ref={mapNode} className="map" aria-label="Route map. Click to place route points." />
      {tokenLoaded && !mapToken && <div className="map-placeholder"><span>MAPBOX REQUIRED</span><p>Add the project’s Mapbox environment variables to enable map clicks and route planning.</p></div>}
      {route && <div className="route-summary"><span>FASTEST ROUTE</span><strong>{metres(route.distanceMeters)} <i>·</i> {duration(route.durationSeconds)}</strong><small>{route.curves.length} detected curves</small>{routes.length > 1 && <select value={routeIndex} onChange={(event) => { setRouteIndex(Number(event.target.value)); setSelectedId(null); }} aria-label="Choose route alternative">{routes.map((option, index) => <option value={index} key={option.id}>Option {index + 1} · {duration(option.durationSeconds)}</option>)}</select>}</div>}
      {selected && <article className="curve-card"><span>CURVE {route!.curves.findIndex((curve) => curve.id === selected.id) + 1}</span><h2>{selected.label}</h2><dl><div><dt>Length</dt><dd>{metres(selected.lengthMeters)}</dd></div><div><dt>Heading</dt><dd>{selected.headingChangeDegrees}°</dd></div><div><dt>Modifier</dt><dd>None</dd></div></dl></article>}
    </section>
    <aside className="curve-list" aria-label="Detected curves">
      <div className="list-heading"><span>PACE NOTES</span><strong>{route ? `${route.curves.length} calls` : "Awaiting route"}</strong></div>
      <div className="scrolling-notes">{route ? route.curves.map((curve, index) => <button key={curve.id} className={selectedId === curve.id ? "curve-row active" : "curve-row"} onClick={() => selectCurve(curve)}><b>{String(index + 1).padStart(2, "0")}</b><span><strong>{curve.label}</strong><small>{metres(curve.lengthMeters)} · {curve.headingChangeDegrees}°</small></span><i>{curve.direction === "left" ? "↙" : "↘"}</i></button>) : <div className="empty-list">Your route’s curve calls will appear here in driving order.</div>}</div>
    </aside>
  </main>;
}
