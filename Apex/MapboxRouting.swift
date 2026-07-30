import Foundation

public struct RouteControl: Identifiable, Sendable {
    public let id: String
    public let kind: RouteControlKind
    public let coordinate: Coordinate
    public let routeDistanceMeters: Double
}

public struct ElevationSample: Identifiable, Sendable {
    public let id: Int
    public let routeDistanceMeters: Double
    public let elevationMeters: Double
    public let coordinate: Coordinate
}

public enum GradeEventKind: String, Sendable { case bump, dip }
public struct GradeEvent: Identifiable, Sendable {
    public let id: String
    public let kind: GradeEventKind
    public let coordinate: Coordinate
    public let routeDistanceMeters: Double
    public let elevationChangeMeters: Double
    public let roadName: String?
}

public struct RouteResult: Identifiable, Sendable {
    public let id: String
    public let coordinates: [Coordinate]
    public let distanceMeters: Double
    public let durationSeconds: Double
    public let curves: [CurveSegment]
    public let snappedStops: [Coordinate]
    public let roadName: String?
    public let roadNames: [String]
    public let controls: [RouteControl]
    public let elevationProfile: [ElevationSample]
    public let gradeEvents: [GradeEvent]
    public let driveTitle: String?

    public init(id: String, coordinates: [Coordinate], distanceMeters: Double, durationSeconds: Double, curves: [CurveSegment], snappedStops: [Coordinate] = [], roadName: String? = nil, roadNames: [String] = [], controls: [RouteControl] = [], elevationProfile: [ElevationSample] = [], gradeEvents: [GradeEvent] = [], driveTitle: String? = nil) {
        self.id = id; self.coordinates = coordinates; self.distanceMeters = distanceMeters; self.durationSeconds = durationSeconds; self.curves = curves; self.snappedStops = snappedStops; self.roadName = roadName; self.roadNames = roadNames; self.controls = controls; self.elevationProfile = elevationProfile; self.gradeEvents = gradeEvents; self.driveTitle = driveTitle
    }
}

public extension RouteResult {
    var paceNoteCount: Int {
        let standaloneControls = controls.filter { control in
            !curves.contains { control.routeDistanceMeters >= $0.routeStartMeters - 14 && control.routeDistanceMeters <= $0.routeEndMeters + 14 }
        }.count
        return curves.count + standaloneControls + gradeEvents.count
    }
}

public enum MapboxRoutingError: LocalizedError {
    case missingToken, invalidResponse, noRoute, requestFailed(String)
    public var errorDescription: String? {
        switch self { case .missingToken: return "Mapbox is not configured. Add MAPBOX_ACCESS_TOKEN to Secrets.xcconfig."; case .invalidResponse: return "Mapbox returned an unexpected response."; case .noRoute: return "Mapbox could not find a drivable route."; case let .requestFailed(message): return message }
    }
}

public actor MapboxRoutingService {
    public init() {}

    public func routes(for stops: [Coordinate]) async throws -> [RouteResult] {
        guard stops.count >= 2 else { return [] }
        guard let token = Bundle.main.object(forInfoDictionaryKey: "MAPBOX_ACCESS_TOKEN") as? String, !token.isEmpty, !token.hasPrefix("$(") else { throw MapboxRoutingError.missingToken }
        let coordinates = stops.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
        var components = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/driving/\(coordinates)")!
        components.queryItems = [URLQueryItem(name: "access_token", value: token), URLQueryItem(name: "alternatives", value: "true"), URLQueryItem(name: "geometries", value: "geojson"), URLQueryItem(name: "overview", value: "full"), URLQueryItem(name: "steps", value: "true"), URLQueryItem(name: "annotations", value: "distance,duration,maxspeed")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw MapboxRoutingError.requestFailed("Mapbox request failed. Check the token and network connection.") }
        let decoded: DirectionsResponse
        do { decoded = try JSONDecoder().decode(DirectionsResponse.self, from: data) } catch { throw MapboxRoutingError.invalidResponse }
        guard decoded.code == "Ok", !decoded.routes.isEmpty else { throw MapboxRoutingError.noRoute }
        let snappedStops = decoded.waypoints?.compactMap { waypoint -> Coordinate? in
            guard waypoint.location.count >= 2 else { return nil }
            return Coordinate(waypoint.location[0], waypoint.location[1])
        } ?? stops
        return await Array(decoded.routes.enumerated()).asyncCompactMap { index, route in
            guard let line = route.geometry?.coordinates, line.count > 1 else { return nil }
            let points = line.map { Coordinate($0[0], $0[1]) }
            let roadNames = orderedRoadNames(from: route.legs)
            let spans = roadSpans(from: route.legs)
            let controls = routeControls(from: route.legs, route: points)
            var curves = PaceNotesCore.analyzeCurves(points).map { curve in
                var curve = curve
                let center = (curve.routeStartMeters + curve.routeEndMeters) / 2
                curve.roadName = spans.first(where: { center >= $0.startMeters && center <= $0.endMeters }).map { PaceNotesCore.shortRoadName($0.name) }
                curve.control = controls.first(where: { $0.routeDistanceMeters >= curve.routeStartMeters - 14 && $0.routeDistanceMeters <= curve.routeEndMeters + 14 })?.kind
                return curve
            }
            // Assign each road transition to one nearest curve only. This avoids
            // duplicate intersection calls when the destination road immediately bends.
            for index in 1..<spans.count where spans[index - 1].name != spans[index].name {
                let boundary = spans[index - 1].endMeters
                guard let direction = spans[index].turnDirection else { continue }
                let nearestCurveIndex = curves.indices.min(by: {
                    abs((curves[$0].routeStartMeters + curves[$0].routeEndMeters) / 2 - boundary) < abs((curves[$1].routeStartMeters + curves[$1].routeEndMeters) / 2 - boundary)
                })
                let approach = PaceNotesCore.shortRoadName(spans[index - 1].name)
                let destination = PaceNotesCore.shortRoadName(spans[index].name)

                // A road maneuver may be followed immediately by an opposite
                // bend. Do not turn that physical bend into the intersection
                // call: it must remain its own warning (for example IL, R3).
                if let curveIndex = nearestCurveIndex,
                   abs((curves[curveIndex].routeStartMeters + curves[curveIndex].routeEndMeters) / 2 - boundary) < 42,
                   curves[curveIndex].direction == direction {
                    curves[curveIndex].approachRoadName = approach
                    curves[curveIndex].roadName = destination
                    curves[curveIndex].intersectionDirection = direction
                } else {
                    // Directions geometry often rounds an intersection with a
                    // tiny opposite-direction kink on the approach. It is not
                    // a useful separate turn call; preserve only the actual
                    // curve that starts after the maneuver.
                    curves.removeAll { curve in
                        curve.approachRoadName == nil &&
                        curve.direction != direction &&
                        curve.routeEndMeters >= boundary - 55 &&
                        curve.routeEndMeters <= boundary + 10
                    }
                    curves.append(intersectionNote(route: points, distance: boundary, index: index, direction: direction, approach: approach, destination: destination))
                }
            }
            curves.sort { $0.routeStartMeters < $1.routeStartMeters }
            return RouteResult(id: "route-\(index + 1)-\(UUID().uuidString)", coordinates: points, distanceMeters: route.distance, durationSeconds: route.duration, curves: curves, snappedStops: snappedStops, roadName: roadNames.first, roadNames: roadNames, controls: controls)
        }
    }

    /// Elevation is intentionally deferred so an optional public-data request
    /// can never hold up route drawing. The caller swaps this enriched result
    /// in only when it still belongs to the active route.
    public func applyingRouteEnhancements(to route: RouteResult) async -> RouteResult {
        async let profile = RouteElevationService.shared.profile(for: route.coordinates)
        async let locality = RouteLocationService.shared.driveTitle(for: route.coordinates)
        async let osmControls = RouteControlService.shared.controls(for: route.coordinates)
        let elevationProfile = await profile
        let driveTitle = await locality
        let supplementalControls = await osmControls
        let elevations = elevationProfile.map(\.elevationMeters)
        let allControls = route.controls + supplementalControls.filter { candidate in
            !route.controls.contains { PaceNotesCore.distanceMeters($0.coordinate, candidate.coordinate) < 12 }
        }
        guard !elevations.isEmpty || driveTitle != nil || allControls.count != route.controls.count else { return route }
        var curves = elevations.isEmpty ? route.curves : annotateElevationModifiers(route.curves, elevations: elevations, totalDistance: route.distanceMeters)
        curves = curves.map { curve in
            var curve = curve
            curve.control = allControls.first(where: { $0.routeDistanceMeters >= curve.routeStartMeters - 14 && $0.routeDistanceMeters <= curve.routeEndMeters + 14 })?.kind
            return curve
        }
        return RouteResult(
            id: "\(route.id)-enhanced",
            coordinates: route.coordinates,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
            curves: curves,
            snappedStops: route.snappedStops,
            roadName: route.roadName,
            roadNames: route.roadNames,
            controls: allControls,
            elevationProfile: elevationProfile,
            gradeEvents: gradeEvents(from: elevationProfile, excluding: curves, fallbackRoadName: route.roadName.map(PaceNotesCore.shortRoadName)),
            driveTitle: driveTitle
        )
    }

    private func orderedRoadNames(from legs: [DirectionsLeg]?) -> [String] {
        var names: [String] = []
        for name in legs?.flatMap({ $0.steps }).compactMap(\.name) ?? [] {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, names.last != trimmed { names.append(trimmed) }
        }
        return names
    }

    private func roadSpans(from legs: [DirectionsLeg]?) -> [RoadSpan] {
        var spans: [RoadSpan] = []
        var distance = 0.0
        for step in legs?.flatMap(\.steps) ?? [] {
            let start = distance
            distance += step.distance
            let name = step.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let direction: CurveDirection? = step.maneuver?.modifier?.contains("left") == true ? .left : step.maneuver?.modifier?.contains("right") == true ? .right : nil
            if !name.isEmpty { spans.append(RoadSpan(startMeters: start, endMeters: distance, name: name, turnDirection: direction)) }
        }
        return spans
    }

    private func intersectionNote(route: [Coordinate], distance: Double, index: Int, direction: CurveDirection, approach: String, destination: String) -> CurveSegment {
        let total = route.dropFirst().indices.reduce(0.0) { partial, pointIndex in partial + PaceNotesCore.distanceMeters(route[pointIndex - 1], route[pointIndex]) }
        let startDistance = max(0, distance - 7)
        let endDistance = min(total, distance + 7)
        let start = coordinate(on: route, at: startDistance)
        let midpoint = coordinate(on: route, at: distance)
        let end = coordinate(on: route, at: endDistance)
        return CurveSegment(
            id: "intersection-\(index)-\(Int(distance.rounded()))",
            direction: direction,
            rating: 1,
            start: start,
            end: end,
            coordinates: [start, midpoint, end],
            lengthMeters: endDistance - startDistance,
            routeStartMeters: startDistance,
            routeEndMeters: endDistance,
            headingChangeDegrees: 0,
            averageCurvature: 0,
            roadName: destination,
            approachRoadName: approach,
            intersectionDirection: direction
        )
    }

    private func coordinate(on route: [Coordinate], at targetDistance: Double) -> Coordinate {
        guard let first = route.first else { return Coordinate(0, 0) }
        var traveled = 0.0
        for index in 1..<route.count {
            let a = route[index - 1], b = route[index]
            let length = PaceNotesCore.distanceMeters(a, b)
            if traveled + length >= targetDistance {
                let ratio = length == 0 ? 0 : (targetDistance - traveled) / length
                return Coordinate(a.longitude + (b.longitude - a.longitude) * ratio, a.latitude + (b.latitude - a.latitude) * ratio)
            }
            traveled += length
        }
        return route.last ?? first
    }

    private func routeControls(from legs: [DirectionsLeg]?, route: [Coordinate]) -> [RouteControl] {
        var controls: [RouteControl] = []
        for (stepIndex, step) in (legs?.flatMap(\.steps) ?? []).enumerated() {
            for (intersectionIndex, intersection) in (step.intersections ?? []).enumerated() {
                guard intersection.location.count >= 2 else { continue }
                let kind: RouteControlKind?
                if intersection.stopSign == true { kind = .stopSign }
                else if intersection.trafficSignal == true { kind = .trafficLight }
                else { kind = nil }
                guard let kind else { continue }
                let coordinate = Coordinate(intersection.location[0], intersection.location[1])
                controls.append(RouteControl(id: "control-\(stepIndex)-\(intersectionIndex)-\(kind.rawValue)", kind: kind, coordinate: coordinate, routeDistanceMeters: PaceNotesCore.routeDistance(of: coordinate, on: route)))
            }
        }
        return controls
    }

    private func annotateElevationModifiers(_ curves: [CurveSegment], elevations: [Double], totalDistance: Double) -> [CurveSegment] {
        guard elevations.count > 1, totalDistance > 0 else { return curves }
        return curves.map { curve in
            var curve = curve
            let startIndex = min(elevations.count - 1, max(0, Int((curve.routeStartMeters / totalDistance * Double(elevations.count - 1)).rounded())))
            let endIndex = min(elevations.count - 1, max(0, Int((curve.routeEndMeters / totalDistance * Double(elevations.count - 1)).rounded())))
            let delta = elevations[endIndex] - elevations[startIndex]
            curve.elevationChangeMeters = delta
            if delta <= -8 { curve.modifier = "D" }
            if delta >= 8 { curve.modifier = "B" }
            return curve
        }
    }

    private func gradeEvents(from profile: [ElevationSample], excluding curves: [CurveSegment], fallbackRoadName: String?) -> [GradeEvent] {
        guard profile.count >= 5 else { return [] }
        var events: [GradeEvent] = []
        var index = 2
        while index < profile.count - 2 {
            let delta = profile[index + 2].elevationMeters - profile[index - 2].elevationMeters
            let distance = profile[index].routeDistanceMeters
            let overlapsCurve = curves.contains { distance >= $0.routeStartMeters - 28 && distance <= $0.routeEndMeters + 28 }
            if !overlapsCurve, abs(delta) >= 12 {
                let nearbyRoad = curves.min(by: { abs($0.routeStartMeters - distance) < abs($1.routeStartMeters - distance) })?.roadName ?? fallbackRoadName
                events.append(GradeEvent(id: "grade-\(index)", kind: delta > 0 ? .bump : .dip, coordinate: profile[index].coordinate, routeDistanceMeters: distance, elevationChangeMeters: delta, roadName: nearbyRoad))
                index += 4
            } else {
                index += 1
            }
        }
        return events
    }
}

private struct RoadSpan {
    let startMeters: Double
    let endMeters: Double
    let name: String
    let turnDirection: CurveDirection?
}

private struct DirectionsResponse: Decodable {
    let code: String
    let routes: [DirectionsRoute]
    let waypoints: [DirectionsWaypoint]?
}

private struct DirectionsWaypoint: Decodable {
    let location: [Double]
}

private struct DirectionsRoute: Decodable {
    let distance: Double
    let duration: Double
    let geometry: Geometry?
    let legs: [DirectionsLeg]?
}

private struct DirectionsLeg: Decodable {
    let steps: [DirectionsStep]
}

private struct DirectionsStep: Decodable {
    let name: String?
    let distance: Double
    let intersections: [DirectionsIntersection]?
    let maneuver: DirectionsManeuver?
}

private struct DirectionsManeuver: Decodable { let modifier: String? }

private struct DirectionsIntersection: Decodable {
    let location: [Double]
    let trafficSignal: Bool?
    let stopSign: Bool?

    enum CodingKeys: String, CodingKey {
        case location
        case trafficSignal = "traffic_signal"
        case stopSign = "stop_sign"
    }
}

private struct Geometry: Decodable {
    let coordinates: [[Double]]
}

/// Mirrors the web app's open elevation lookup. It is deliberately best-effort:
/// pace-note routing still succeeds when either community service is unavailable.
private actor RouteElevationService {
    static let shared = RouteElevationService()

    func profile(for route: [Coordinate]) async -> [ElevationSample] {
        let samples = sampled(route, maximum: 90)
        guard samples.count > 1 else { return [] }
        let elevations: [Double]
        if let result = try? await topodata(samples), result.count == samples.count { elevations = result }
        else if let result = try? await openElevation(samples), result.count == samples.count { elevations = result }
        else { return [] }
        return samples.enumerated().map { index, point in
            ElevationSample(id: index, routeDistanceMeters: PaceNotesCore.routeDistance(of: point, on: route), elevationMeters: elevations[index], coordinate: point)
        }
    }

    private func sampled(_ route: [Coordinate], maximum: Int) -> [Coordinate] {
        guard route.count > maximum else { return route }
        return (0..<maximum).map { position in
            route[Int((Double(position) / Double(maximum - 1) * Double(route.count - 1)).rounded())]
        }
    }

    private func topodata(_ points: [Coordinate]) async throws -> [Double] {
        var components = URLComponents(string: "https://api.opentopodata.org/v1/aster30m")!
        components.queryItems = [URLQueryItem(name: "locations", value: points.map { "\($0.latitude),\($0.longitude)" }.joined(separator: "|"))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(TopodataResponse.self, from: data).results.map(\.elevation)
    }

    private func openElevation(_ points: [Coordinate]) async throws -> [Double] {
        var request = URLRequest(url: URL(string: "https://api.open-elevation.com/api/v1/lookup")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ElevationRequest(locations: points.map { .init(latitude: $0.latitude, longitude: $0.longitude) }))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(OpenElevationResponse.self, from: data).results.map(\.elevation)
    }
}

private struct TopodataResponse: Decodable { let results: [ElevationResult] }
private struct OpenElevationResponse: Decodable { let results: [ElevationResult] }
private struct ElevationResult: Decodable { let elevation: Double }
private struct ElevationRequest: Encodable { let locations: [ElevationLocation] }
private struct ElevationLocation: Encodable { let latitude: Double; let longitude: Double }

private actor RouteLocationService {
    static let shared = RouteLocationService()

    func driveTitle(for route: [Coordinate]) async -> String? {
        guard let first = route.first, let last = route.last,
              let token = Bundle.main.object(forInfoDictionaryKey: "MAPBOX_ACCESS_TOKEN") as? String,
              !token.isEmpty, !token.hasPrefix("$(") else { return nil }
        async let start = reverseGeocode(first, token: token)
        async let end = reverseGeocode(last, token: token)
        let startPlace = await start
        let endPlace = await end
        if let startPlace, let endPlace, startPlace.place == endPlace.place, let place = startPlace.place { return "\(place) Drive" }
        if let startPlace, let endPlace, startPlace.district == endPlace.district, let district = startPlace.district { return "\(district) Drive" }
        if let startPlace, let endPlace, startPlace.region == endPlace.region, let region = startPlace.region { return "\(region) Drive" }
        if let district = startPlace?.district ?? endPlace?.district { return "\(district) Drive" }
        if let place = startPlace?.place ?? endPlace?.place { return "\(place) Drive" }
        if let region = startPlace?.region ?? endPlace?.region { return "\(region) Drive" }
        return "Multi-region Drive"
    }

    private func reverseGeocode(_ coordinate: Coordinate, token: String) async -> Locality? {
        var components = URLComponents(string: "https://api.mapbox.com/geocoding/v5/mapbox.places/\(coordinate.longitude),\(coordinate.latitude).json")!
        components.queryItems = [URLQueryItem(name: "access_token", value: token), URLQueryItem(name: "limit", value: "1")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let result = try? JSONDecoder().decode(GeocodingResponse.self, from: data) else { return nil }
        let features = result.features
        func name(for type: String) -> String? {
            features.first(where: { $0.placeType.contains(type) })?.text
                ?? features.flatMap { $0.context ?? [] }.first(where: {
                    $0.placeType?.contains(type) == true || $0.id?.hasPrefix("\(type).") == true
                })?.text
        }
        return Locality(place: name(for: "place"), district: name(for: "district"), region: name(for: "region"))
    }
}

private struct Locality { let place: String?; let district: String?; let region: String? }
private struct GeocodingResponse: Decodable { let features: [GeocodingFeature] }
private struct GeocodingFeature: Decodable {
    let text: String
    let placeType: [String]
    let context: [GeocodingContext]?
    enum CodingKeys: String, CodingKey { case text; case placeType = "place_type"; case context }
}
private struct GeocodingContext: Decodable {
    let id: String?
    let text: String
    let placeType: [String]?
    enum CodingKeys: String, CodingKey { case id; case text; case placeType = "place_type" }
}

/// Supplements Directions' intersection flags with nearby OpenStreetMap stop
/// controls. OSM coverage is uneven, so Mapbox remains the primary source.
private actor RouteControlService {
    static let shared = RouteControlService()

    func controls(for route: [Coordinate]) async -> [RouteControl] {
        guard let minLat = route.map(\.latitude).min(), let maxLat = route.map(\.latitude).max(),
              let minLon = route.map(\.longitude).min(), let maxLon = route.map(\.longitude).max(),
              maxLat - minLat < 0.18, maxLon - minLon < 0.18 else { return [] }
        let query = "[out:json][timeout:4];node[highway~\"^(stop|traffic_signals)$\"](\(minLat),\(minLon),\(maxLat),\(maxLon));out tags;"
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)".data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let result = try? JSONDecoder().decode(OverpassControlResponse.self, from: data) else { return [] }
        return result.elements.compactMap { node in
            let coordinate = Coordinate(node.lon, node.lat)
            guard PaceNotesCore.routeDistance(of: coordinate, on: route) >= 0,
                  route.contains(where: { PaceNotesCore.distanceMeters(coordinate, $0) < 35 }) else { return nil }
            let kind: RouteControlKind = node.tags?["highway"] == "traffic_signals" ? .trafficLight : .stopSign
            return RouteControl(id: "osm-\(node.id)", kind: kind, coordinate: coordinate, routeDistanceMeters: PaceNotesCore.routeDistance(of: coordinate, on: route))
        }
    }
}

private struct OverpassControlResponse: Decodable { let elements: [OverpassControlNode] }
private struct OverpassControlNode: Decodable { let id: Int; let lat: Double; let lon: Double; let tags: [String: String]? }

private extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async -> T?) async -> [T] {
        var result: [T] = []
        for element in self { if let value = await transform(element) { result.append(value) } }
        return result
    }
}
