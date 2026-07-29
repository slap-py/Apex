export type Coordinate = [number, number];
export type CurveDirection = "left" | "right";
export type CurveRating = 1 | 2 | 3 | 4 | 5 | 6;

export interface CurveAnalysisOptions {
  sampleDistanceMeters: number;
  minimumCurveLengthMeters: number;
  minimumHeadingChangeDegrees: number;
  ratingThresholds: readonly number[];
}

export interface CurveSegment {
  id: string;
  direction: CurveDirection;
  rating: CurveRating;
  label: string;
  start: Coordinate;
  end: Coordinate;
  coordinates: Coordinate[];
  lengthMeters: number;
  routeStartMeters: number;
  routeEndMeters: number;
  headingChangeDegrees: number;
  averageCurvature: number;
  modifier: null;
}

export interface RouteDisplaySegment {
  coordinates: Coordinate[];
  color: "black" | "blue" | "red";
  curveId?: string;
}

export const defaultCurveAnalysisOptions: CurveAnalysisOptions = {
  sampleDistanceMeters: 14,
  minimumCurveLengthMeters: 32,
  minimumHeadingChangeDegrees: 9,
  // Minimum total heading change by rating: sharp curves earn lower numbers.
  ratingThresholds: [115, 80, 50, 30, 16],
};

const radians = (degrees: number) => (degrees * Math.PI) / 180;
const degrees = (radiansValue: number) => (radiansValue * 180) / Math.PI;

export function distanceMeters(a: Coordinate, b: Coordinate) {
  const earthRadius = 6_371_000;
  const dLat = radians(b[1] - a[1]);
  const dLon = radians(b[0] - a[0]);
  const lat1 = radians(a[1]);
  const lat2 = radians(b[1]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * earthRadius * Math.asin(Math.sqrt(h));
}

function bearing(a: Coordinate, b: Coordinate) {
  const lonDelta = radians(b[0] - a[0]);
  const lat1 = radians(a[1]);
  const lat2 = radians(b[1]);
  return degrees(Math.atan2(Math.sin(lonDelta) * Math.cos(lat2), Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(lonDelta)));
}

function signedAngle(from: number, to: number) {
  return ((to - from + 540) % 360) - 180;
}

function interpolate(a: Coordinate, b: Coordinate, ratio: number): Coordinate {
  return [a[0] + (b[0] - a[0]) * ratio, a[1] + (b[1] - a[1]) * ratio];
}

function resampleLine(coordinates: Coordinate[], spacing: number) {
  if (coordinates.length < 2) return coordinates;
  const sampled: Coordinate[] = [coordinates[0]];
  let carry = 0;
  for (let index = 1; index < coordinates.length; index += 1) {
    const start = coordinates[index - 1];
    const end = coordinates[index];
    const length = distanceMeters(start, end);
    if (length === 0) continue;
    let traversed = spacing - carry;
    while (traversed < length) {
      sampled.push(interpolate(start, end, traversed / length));
      traversed += spacing;
    }
    carry = length - (traversed - spacing);
  }
  const last = coordinates[coordinates.length - 1];
  if (distanceMeters(sampled[sampled.length - 1], last) > 1) sampled.push(last);
  return sampled;
}

function ratingFor(change: number, thresholds: readonly number[]): CurveRating {
  if (change >= thresholds[0]) return 1;
  if (change >= thresholds[1]) return 2;
  if (change >= thresholds[2]) return 3;
  if (change >= thresholds[3]) return 4;
  if (change >= thresholds[4]) return 5;
  return 6;
}

/** Derive rally-style, route-ordered curves from a GeoJSON line. */
export function analyzeCurves(input: Coordinate[], options: Partial<CurveAnalysisOptions> = {}): CurveSegment[] {
  const config = { ...defaultCurveAnalysisOptions, ...options };
  const points = resampleLine(input, config.sampleDistanceMeters);
  if (points.length < 4) return [];
  const headings = points.slice(1).map((point, index) => bearing(points[index], point));
  const segments: Array<{ startIndex: number; endIndex: number; direction: CurveDirection; change: number }> = [];
  let active: (typeof segments)[number] | null = null;
  let pendingChange = 0;
  for (let index = 1; index < headings.length; index += 1) {
    const change = signedAngle(headings[index - 1], headings[index]);
    if (Math.abs(change) < 1.15) continue;
    const direction: CurveDirection = change < 0 ? "left" : "right";
    if (active && active.direction === direction) {
      active.endIndex = index + 1;
      active.change += change;
    } else if (!active || Math.abs(pendingChange + change) > 6) {
      if (active) segments.push(active);
      active = { startIndex: Math.max(0, index - 1), endIndex: index + 1, direction, change };
      pendingChange = change;
    } else {
      pendingChange += change;
    }
  }
  if (active) segments.push(active);

  let routeDistance = 0;
  const distanceAtPoint = points.map((point, index) => {
    if (index > 0) routeDistance += distanceMeters(points[index - 1], point);
    return routeDistance;
  });
  return segments.flatMap((segment, index) => {
    const curvePoints = points.slice(segment.startIndex, segment.endIndex + 1);
    const length = distanceAtPoint[segment.endIndex] - distanceAtPoint[segment.startIndex];
    const headingChange = Math.abs(segment.change);
    if (length < config.minimumCurveLengthMeters || headingChange < config.minimumHeadingChangeDegrees) return [];
    const rating = ratingFor(headingChange, config.ratingThresholds);
    return [{
      id: `curve-${index + 1}-${segment.startIndex}`,
      direction: segment.direction,
      rating,
      label: `${segment.direction === "left" ? "Left" : "Right"} ${rating}`,
      start: curvePoints[0],
      end: curvePoints[curvePoints.length - 1],
      coordinates: curvePoints,
      lengthMeters: Math.round(length),
      routeStartMeters: Math.round(distanceAtPoint[segment.startIndex]),
      routeEndMeters: Math.round(distanceAtPoint[segment.endIndex]),
      headingChangeDegrees: Math.round(headingChange * 10) / 10,
      averageCurvature: Math.round((headingChange / Math.max(length, 1)) * 1000) / 1000,
      modifier: null,
    }];
  });
}

/**
 * Splits the original provider geometry into non-overlapping display segments.
 * This intentionally never draws the resampled analysis geometry on the map.
 */
export function colorizeRoute(coordinates: Coordinate[], curves: CurveSegment[]): RouteDisplaySegment[] {
  if (coordinates.length < 2) return [];
  let total = 0;
  const distances = coordinates.map((point, index) => {
    if (index > 0) total += distanceMeters(coordinates[index - 1], point);
    return total;
  });
  const colorAt = (distance: number) => {
    const curve = curves.find((item) => distance >= item.routeStartMeters && distance <= item.routeEndMeters);
    return curve ? { color: curve.direction === "left" ? "blue" as const : "red" as const, curveId: curve.id } : { color: "black" as const };
  };
  const segments: RouteDisplaySegment[] = [];
  let active = { ...colorAt((distances[0] + distances[1]) / 2), coordinates: [coordinates[0], coordinates[1]] };
  for (let index = 2; index < coordinates.length; index += 1) {
    const next = colorAt((distances[index - 1] + distances[index]) / 2);
    if (next.color === active.color && next.curveId === active.curveId) active.coordinates.push(coordinates[index]);
    else {
      segments.push(active);
      active = { ...next, coordinates: [coordinates[index - 1], coordinates[index]] };
    }
  }
  segments.push(active);
  return segments;
}

export function curveMidpoint(curve: CurveSegment): Coordinate {
  return curve.coordinates[Math.floor(curve.coordinates.length / 2)] || curve.start;
}

export function routeCurveMidpoint(route: Coordinate[], curve: CurveSegment): Coordinate {
  const target = (curve.routeStartMeters + curve.routeEndMeters) / 2;
  let travelled = 0;
  for (let index = 1; index < route.length; index += 1) {
    const segment = distanceMeters(route[index - 1], route[index]);
    if (travelled + segment >= target) {
      const ratio = segment ? (target - travelled) / segment : 0;
      return [route[index - 1][0] + (route[index][0] - route[index - 1][0]) * ratio, route[index - 1][1] + (route[index][1] - route[index - 1][1]) * ratio];
    }
    travelled += segment;
  }
  return route[route.length - 1] || curve.start;
}
