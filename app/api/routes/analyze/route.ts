import { NextResponse } from "next/server";
import { analyzeCurves, type Coordinate } from "../../../../lib/curves";

type RouteRequest = { start?: string; end?: string; waypoints?: string[]; coordinates?: Coordinate[]; stops?: Coordinate[] };

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
    const url = `https://api.mapbox.com/directions/v5/mapbox/driving-traffic/${stops.map((point) => point.join(",")).join(";")}?alternatives=true&geometries=geojson&overview=full&steps=false&access_token=${token}`;
    const response = await fetch(url);
    if (!response.ok) throw new Error("Mapbox could not calculate a driving route for those locations.");
    const data = await response.json() as { routes?: Array<{ distance: number; duration: number; geometry: { coordinates: Coordinate[] } }>; waypoints?: Array<{ location?: Coordinate }> };
    if (!data.routes?.length) throw new Error("No driving route was found.");
    const snappedStops = data.waypoints?.map((waypoint) => waypoint.location).filter((location): location is Coordinate => Boolean(location)) || stops;
    return NextResponse.json({ snappedStops, routes: data.routes.map((route, index) => ({ id: `route-${index + 1}`, coordinates: route.geometry.coordinates, distanceMeters: Math.round(route.distance), durationSeconds: Math.round(route.duration), curves: analyzeCurves(route.geometry.coordinates) })) });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Unable to analyze route." }, { status: 500 });
  }
}
