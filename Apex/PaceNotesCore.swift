import Foundation

public struct Coordinate: Codable, Hashable, Sendable {
    public let longitude: Double
    public let latitude: Double
    public init(_ longitude: Double, _ latitude: Double) { self.longitude = longitude; self.latitude = latitude }
}
public enum CurveDirection: String, Codable, Sendable { case left, right }
public enum RouteControlKind: String, Codable, Sendable { case stopSign, trafficLight
    public var displayName: String { self == .stopSign ? "Stop sign" : "Stoplight" }
}
public enum RouteDisplayColor: String, Sendable { case straight, left, right }
public struct RouteDisplaySegment: Identifiable, Sendable {
    public let id = UUID()
    public let coordinates: [Coordinate]
    public let color: RouteDisplayColor
    public init(coordinates: [Coordinate], color: RouteDisplayColor) { self.coordinates = coordinates; self.color = color }
}

public struct CurveAnalysisOptions: Sendable {
    public var sampleDistanceMeters = 12.0
    public var minimumCurveLengthMeters = 28.0
    public var minimumHeadingChangeDegrees = 9.0
    public var ratingThresholds = [115.0, 80.0, 50.0, 30.0, 16.0]
    public init() {}
}

public struct CurveSegment: Identifiable, Codable, Sendable, Hashable {
    public let id: String; public let direction: CurveDirection; public let rating: Int; public let label: String
    public let start: Coordinate; public let end: Coordinate; public let coordinates: [Coordinate]
    public let lengthMeters: Double; public let routeStartMeters: Double; public let routeEndMeters: Double
    public let headingChangeDegrees: Double; public let averageCurvature: Double
    /// Context is attached after Mapbox returns its maneuver steps.
    public var modifier: String?
    public var roadName: String?
    public var approachRoadName: String?
    public var intersectionDirection: CurveDirection?
    public var control: RouteControlKind?
    public var elevationChangeMeters: Double?

    public init(id: String, direction: CurveDirection, rating: Int, start: Coordinate, end: Coordinate, coordinates: [Coordinate], lengthMeters: Double, routeStartMeters: Double, routeEndMeters: Double, headingChangeDegrees: Double, averageCurvature: Double, modifier: String? = nil, roadName: String? = nil, approachRoadName: String? = nil, intersectionDirection: CurveDirection? = nil, control: RouteControlKind? = nil, elevationChangeMeters: Double? = nil) {
        self.id = id; self.direction = direction; self.rating = rating; self.label = "\(direction == .left ? "Left" : "Right") \(rating)"; self.start = start; self.end = end; self.coordinates = coordinates; self.lengthMeters = lengthMeters; self.routeStartMeters = routeStartMeters; self.routeEndMeters = routeEndMeters; self.headingChangeDegrees = headingChangeDegrees; self.averageCurvature = averageCurvature; self.modifier = modifier; self.roadName = roadName; self.approachRoadName = approachRoadName; self.intersectionDirection = intersectionDirection; self.control = control; self.elevationChangeMeters = elevationChangeMeters
    }

    public var displayLabel: String { "\(label)\(modifier == "B" ? " Bump" : modifier == "D" ? " Dip" : "")" }
    public var presentationDirection: CurveDirection { intersectionDirection ?? direction }
}

public enum PaceNotesCore {
    public static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6_371_000.0, d = Double.pi / 180, dLat = (b.latitude - a.latitude) * d, dLon = (b.longitude - a.longitude) * d, lat1 = a.latitude * d, lat2 = b.latitude * d
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(sqrt(h))
    }

    public static func analyzeCurves(_ input: [Coordinate], options: CurveAnalysisOptions = .init()) -> [CurveSegment] {
        let points = resampleLine(input, spacing: options.sampleDistanceMeters); guard points.count >= 4 else { return [] }
        let headings = zip(points.dropFirst(), points).map { bearing($0.1, $0.0) }
        struct Active { var start: Int; var end: Int; var direction: CurveDirection; var change: Double }
        var segments: [Active] = []; var active: Active?; var quiet = 0
        for index in 1..<headings.count {
            let change = signedAngle(from: headings[index - 1], to: headings[index])
            // End a note at the first genuinely straight sample. This favours a
            // precise warning window over carrying a pace note down a long exit.
            if abs(change) < 1.5 { quiet += 1; if active != nil && quiet >= 1 { segments.append(active!); active = nil }; continue }
            quiet = 0; let direction: CurveDirection = change < 0 ? .left : .right
            if active?.direction == direction {
                active?.end = index + 1
                active?.change += change
            } else {
                // A reversal is a separate pace note, even when it begins immediately.
                // Keeping it separate is safer than folding a left entry into a right call.
                if let active { segments.append(active) }
                active = Active(start: max(0, index - 1), end: index + 1, direction: direction, change: change)
            }
        }
        if let active { segments.append(active) }
        // Rejoin a single straight sampling gap within the same directional bend.
        // This removes artificial double-calls without ever merging a reversal.
        var merged: [Active] = []
        for segment in segments {
            if var previous = merged.last, previous.direction == segment.direction, segment.start - previous.end <= 2 {
                previous.end = max(previous.end, segment.end)
                previous.change += segment.change
                merged[merged.count - 1] = previous
            } else {
                merged.append(segment)
            }
        }
        var travelled = 0.0; let distances = points.enumerated().map { index, point -> Double in if index > 0 { travelled += distanceMeters(points[index - 1], point) }; return travelled }
        return merged.enumerated().compactMap { index, segment in
            let end = min(segment.end, points.count - 1), curvePoints = Array(points[segment.start...end]), length = distances[end] - distances[segment.start], change = abs(segment.change)
            guard length >= options.minimumCurveLengthMeters, change >= options.minimumHeadingChangeDegrees else { return nil }
            let rating = ratingFor(change, thresholds: options.ratingThresholds)
            return CurveSegment(id: "curve-\(index + 1)-\(segment.start)", direction: segment.direction, rating: rating, start: curvePoints[0], end: curvePoints.last!, coordinates: curvePoints, lengthMeters: length.rounded(), routeStartMeters: distances[segment.start].rounded(), routeEndMeters: distances[end].rounded(), headingChangeDegrees: (change * 10).rounded() / 10, averageCurvature: (change / max(length, 1) * 1000).rounded() / 1000)
        }
    }

    public static func routeCurveMidpoint(route: [Coordinate], curve: CurveSegment) -> Coordinate {
        let target = (curve.routeStartMeters + curve.routeEndMeters) / 2; var travelled = 0.0; guard route.count > 1 else { return route.last ?? curve.start }
        for index in 1..<route.count { let length = distanceMeters(route[index - 1], route[index]); if travelled + length >= target { let ratio = length == 0 ? 0 : (target - travelled) / length; return Coordinate(route[index - 1].longitude + (route[index].longitude - route[index - 1].longitude) * ratio, route[index - 1].latitude + (route[index].latitude - route[index - 1].latitude) * ratio) }; travelled += length }
        return route.last!
    }

    /// Finds the actual tightest bend in the original Mapbox geometry instead of
    /// placing labels halfway through an analysed segment. This keeps a pace-note
    /// badge on the visual apex even when entry or exit straights are included.
    public static func routeCurveApex(route: [Coordinate], curve: CurveSegment) -> Coordinate {
        guard route.count >= 3 else { return routeCurveMidpoint(route: route, curve: curve) }
        var distances = [0.0]
        for index in 1..<route.count {
            distances.append(distances[index - 1] + distanceMeters(route[index - 1], route[index]))
        }
        let lower = max(0, curve.routeStartMeters - 8)
        let upper = curve.routeEndMeters + 8
        let expectedSign = curve.direction == .left ? -1.0 : 1.0
        var best: (point: Coordinate, score: Double)?
        var fallback: (point: Coordinate, score: Double)?

        for index in 1..<(route.count - 1) where distances[index] >= lower && distances[index] <= upper {
            let localChanges = (-1...1).compactMap { offset -> Double? in
                let headingIndex = index + offset
                guard headingIndex > 0, headingIndex < route.count - 1 else { return nil }
                return signedAngle(
                    from: bearing(route[headingIndex - 1], route[headingIndex]),
                    to: bearing(route[headingIndex], route[headingIndex + 1])
                )
            }
            let signedScore = localChanges.reduce(0, +)
            let score = abs(signedScore)
            if score > (fallback?.score ?? 0) { fallback = (route[index], score) }
            if signedScore.sign == expectedSign.sign, score > (best?.score ?? 0) {
                best = (route[index], score)
            }
        }
        return best?.point ?? fallback?.point ?? routeCurveMidpoint(route: route, curve: curve)
    }

    public static func routeDistance(of coordinate: Coordinate, on route: [Coordinate]) -> Double {
        guard route.count > 1 else { return 0 }
        var travelled = 0.0
        var bestDistance = Double.greatestFiniteMagnitude
        var bestRouteDistance = 0.0
        for index in 1..<route.count {
            let a = route[index - 1], b = route[index]
            let latitudeScale = 111_320.0
            let longitudeScale = latitudeScale * cos((a.latitude + b.latitude) / 2 * .pi / 180)
            let ax = a.longitude * longitudeScale, ay = a.latitude * latitudeScale
            let bx = b.longitude * longitudeScale, by = b.latitude * latitudeScale
            let px = coordinate.longitude * longitudeScale, py = coordinate.latitude * latitudeScale
            let dx = bx - ax, dy = by - ay
            let denominator = dx * dx + dy * dy
            let t = denominator == 0 ? 0 : min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / denominator))
            let nearest = Coordinate(a.longitude + (b.longitude - a.longitude) * t, a.latitude + (b.latitude - a.latitude) * t)
            let distance = distanceMeters(coordinate, nearest)
            if distance < bestDistance {
                bestDistance = distance
                bestRouteDistance = travelled + distanceMeters(a, b) * t
            }
            travelled += distanceMeters(a, b)
        }
        return bestRouteDistance
    }

    public static func colorizeRoute(_ route: [Coordinate], curves: [CurveSegment]) -> [RouteDisplaySegment] {
        guard route.count > 1 else { return [] }
        var distance = 0.0
        var distances = [0.0]
        for index in 1..<route.count { distance += distanceMeters(route[index - 1], route[index]); distances.append(distance) }
        func color(at distance: Double) -> RouteDisplayColor {
            let matching = curves.filter { distance >= $0.routeStartMeters && distance <= $0.routeEndMeters }
            // A generated intersection call takes precedence over an adjoining
            // physical curve only in its tiny maneuver window.
            guard let curve = matching.first(where: { $0.approachRoadName != nil && $0.approachRoadName != $0.roadName }) ?? matching.first else { return .straight }
            // Intersection calls use the navigation maneuver direction. The
            // physical bend immediately afterward may go the other way.
            return curve.presentationDirection == .left ? .left : .right
        }
        var result: [RouteDisplaySegment] = []
        var activeColor = color(at: (distances[0] + distances[1]) / 2)
        var activePoints = [route[0], route[1]]
        for index in 2..<route.count {
            let nextColor = color(at: (distances[index - 1] + distances[index]) / 2)
            if nextColor == activeColor { activePoints.append(route[index]) }
            else {
                result.append(RouteDisplaySegment(coordinates: activePoints, color: activeColor))
                activeColor = nextColor
                activePoints = [route[index - 1], route[index]]
            }
        }
        result.append(RouteDisplaySegment(coordinates: activePoints, color: activeColor))
        return result
    }

    public static func shortRoadName(_ name: String) -> String {
        let replacements = [
            ("Northwest", "NW"), ("Northeast", "NE"), ("Southwest", "SW"), ("Southeast", "SE"),
            ("North", "N"), ("South", "S"), ("East", "E"), ("West", "W"),
            ("Avenue", "Ave"), ("Street", "St"), ("Boulevard", "Blvd"), ("Drive", "Dr"),
            ("Road", "Rd"), ("Place", "Pl"), ("Lane", "Ln"), ("Court", "Ct"), ("Circle", "Cir"),
            ("Terrace", "Ter"), ("Parkway", "Pkwy"), ("Highway", "Hwy"), ("Trail", "Trl")
        ]
        return replacements.reduce(name) { partial, replacement in
            partial.replacingOccurrences(of: replacement.0, with: replacement.1, options: [.caseInsensitive])
        }
    }

    /// Produces a readable timeline label before conceding to an ellipsis.
    /// `characterCapacity` is based on the number of consecutive note chips.
    public static func compactRoadName(_ name: String, characterCapacity: Int) -> String {
        let abbreviated = shortRoadName(name)
        guard abbreviated.count > characterCapacity else { return abbreviated }
        let directionTokens = ["NW ", "NE ", "SW ", "SE ", "N ", "S ", "E ", "W "]
        var result = directionTokens.reduce(abbreviated) { $0.replacingOccurrences(of: $1, with: "") }
        guard result.count > characterCapacity else { return result }
        let suffixes = [" Ave", " St", " Rd", " Dr", " Way", " Blvd", " Pl", " Ln", " Ct", " Cir", " Ter", " Pkwy", " Hwy", " Trl"]
        for suffix in suffixes where result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
            break
        }
        guard result.count > characterCapacity else { return result }
        guard characterCapacity > 1 else { return String(result.prefix(1)) }
        return String(result.prefix(characterCapacity - 1)) + "…"
    }

    private static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double { let d = Double.pi / 180, lon = (b.longitude - a.longitude) * d, lat1 = a.latitude * d, lat2 = b.latitude * d; return atan2(sin(lon) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lon)) * 180 / .pi }
    private static func signedAngle(from: Double, to: Double) -> Double { ((to - from + 540).truncatingRemainder(dividingBy: 360)) - 180 }
    private static func ratingFor(_ change: Double, thresholds: [Double]) -> Int { for (index, threshold) in thresholds.enumerated() where change >= threshold { return min(index + 1, 6) }; return 6 }
    private static func resampleLine(_ coordinates: [Coordinate], spacing: Double) -> [Coordinate] {
        guard coordinates.count >= 2 else { return coordinates }; var sampled = [coordinates[0]], carry = 0.0
        for index in 1..<coordinates.count { let start = coordinates[index - 1], end = coordinates[index], length = distanceMeters(start, end); if length == 0 { continue }; var traversed = spacing - carry; while traversed < length { let ratio = traversed / length; sampled.append(Coordinate(start.longitude + (end.longitude - start.longitude) * ratio, start.latitude + (end.latitude - start.latitude) * ratio)); traversed += spacing }; carry = length - (traversed - spacing) }
        if let last = sampled.last, let end = coordinates.last, distanceMeters(last, end) > 1 { sampled.append(end) }; return sampled
    }
}
