import { NextResponse } from "next/server";
import { analyzeCurves, type Coordinate, distanceMeters } from "../../../../lib/curves";

type RouteRequest = { start?: string; end?: string; waypoints?: string[]; coordinates?: Coordinate[]; stops?: Coordinate[] };

type RoadEvent = { id: string; type: "stop" | "signal" | "arterial"; coordinate: Coordinate; name?: string };

async function fetchRoadEvents(coordinates: Coordinate[]): Promise<RoadEvent[]> {
  if (coordinates.length < 2) return [];
  const stride = Math.max(1, Math.floor(coordinates.length / 24));
  const samples = coordinates.filter((_, index) => index % stride === 0).slice(0, 24);
  const around = samples.map(([lon, lat]) => `node(around:35,${lat},${lon})[highway~"^(stop|traffic_signals)$"];way(around:50,${lat},${lon})[highway~"^(primary|secondary|tertiary)$"][name];`).join("");
  const query = `[out:json][timeout:12];(${around});out center tags;`;
  try {
    const response = await fetch("https://overpass-api.de/api/interpreter", { method: "POST", body: query, headers: { "Content-Type": "text/plain" } });
    if (!response.ok) return [];
    const data = await response.json() as { elements?: Array<{ id: number; type: string; lat?: number; lon?: number; center?: { lat: number; lon: number }; tags?: { highway?: string; name?: string } }> };
    const events: RoadEvent[] = [];
    for (const element of data.elements || []) {
      const point = element.lat !== undefined && element.lon !== undefined ? [element.lon, element.lat] as Coordinate : element.center ? [element.center.lon, element.center.lat] as Coordinate : null;
      if (!point || !element.tags?.highway) continue;
      const type = element.tags.highway === "stop" ? "stop" : element.tags.highway === "traffic_signals" ? "signal" : "arterial";
      const key = `${type}-${point.map((value) => value.toFixed(4)).join(",")}`;
      if (!events.some((event) => event.id === key)) events.push({ id: key, type, coordinate: point, name: element.tags.name });
    }
    return events.slice(0, 80);
  } catch { return []; }
}

async function geocode(query: string, token: string): Promise<Coordinate> {
  const url = `https://api.mapbox.com/search/geocode/v6/forward?q=${encodeURIComponent(query)}&limit=1&access_token=${token}`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Unable to find ${query}`);
  const data = await response.json() as { features?: Array<{ geometry?: { coordinates?: Coordinate } }> };
  const coordinate = data.features?.[0]?.geometry?.coordinates;
  if (!coordinate) throw new Error(`No location found for ${query}`);
  return coordinate;
}

export async function POST(request: Request) {
  try {
    const body = await request.json() as RouteRequest;
    if (body.coordinates?.length && body.coordinates.length > 1) {
      return NextResponse.json({ route: { coordinates: body.coordinates, distanceMeters: null, durationSeconds: null }, curves: analyzeCurves(body.coordinates) });
    }
    if ((!body.stops || body.stops.length < 2) && (!body.start?.trim() || !body.end?.trim())) return NextResponse.json({ error: "Place a start and end point on the map." }, { status: 400 });
    const token = process.env.MAPBOX_ACCESS_TOKEN || process.env.NEXT_PUBLIC_MAPBOX_ACCESS_TOKEN;
    if (!token) return NextResponse.json({ error: "Mapbox is not configured yet. Add MAPBOX_ACCESS_TOKEN to the site environment." }, { status: 503 });
    const stops = body.stops?.length ? body.stops : await Promise.all([body.start!, ...(body.waypoints || []).filter(Boolean), body.end!].map((place) => geocode(place, token)));
    const url = `https://api.mapbox.com/directions/v5/mapbox/driving-traffic/${stops.map((point) => point.join(",")).join(";")}?alternatives=true&geometries=geojson&overview=full&steps=true&annotations=maxspeed&access_token=${token}`;
    const response = await fetch(url);
    if (!response.ok) throw new Error("Mapbox could not calculate a driving route for those locations.");
    const data = await response.json() as { routes?: Array<{ distance: number; duration: number; geometry: { coordinates: Coordinate[] }; legs?: Array<{ annotation?: { maxspeed?: Array<{ speed?: number; unit?: string }> } }> }>; waypoints?: Array<{ location?: Coordinate }> };
    if (!data.routes?.length) throw new Error("No driving route was found.");
    const snappedStops = data.waypoints?.map((waypoint) => waypoint.location).filter((location): location is Coordinate => Boolean(location)) || stops;
    const events = await fetchRoadEvents(data.routes[0].geometry.coordinates);
    return NextResponse.json({ snappedStops, roadEvents: events, routes: data.routes.map((route, index) => {
      const rawLimits = route.legs?.flatMap((leg) => leg.annotation?.maxspeed || []) || [];
      const speedChanges: Array<{ coordinate: Coordinate; mph: number; routeDistanceMeters: number }> = [];
      let previousMph: number | null = null;
      rawLimits.forEach((limit, limitIndex) => {
        if (limit.speed === undefined || limit.speed === null) return;
        const mph = Math.round((limit.unit || "km/h").toLowerCase().includes("mph") ? limit.speed : limit.speed * 0.621371);
        if (mph === previousMph) return;
        previousMph = mph;
        const geometryIndex = Math.min(route.geometry.coordinates.length - 1, Math.round((limitIndex / Math.max(1, rawLimits.length - 1)) * (route.geometry.coordinates.length - 1)));
        const coordinate = route.geometry.coordinates[geometryIndex];
        const routeDistanceMeters = route.geometry.coordinates.slice(1, geometryIndex + 1).reduce((total, point, pointIndex) => total + distanceMeters(route.geometry.coordinates[pointIndex], point), 0);
        speedChanges.push({ coordinate, mph, routeDistanceMeters: Math.round(routeDistanceMeters) });
      });
      return { id: `route-${index + 1}`, coordinates: route.geometry.coordinates, distanceMeters: Math.round(route.distance), durationSeconds: Math.round(route.duration), curves: analyzeCurves(route.geometry.coordinates), speedChanges };
    }) });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Unable to analyze route." }, { status: 500 });
  }
}
