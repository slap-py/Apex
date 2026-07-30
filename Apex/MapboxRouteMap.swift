import MapboxMaps
import SwiftUI
import UIKit

struct MapboxRouteMap: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("distanceUnit") private var distanceUnit = "mi"
    let stops: [Coordinate]
    let route: RouteResult?
    @Binding var mapError: String?
    let fitRouteOnLoad: Bool
    let showsRouteAnnotations: Bool
    let previewPresentation: Bool
    let onMapTap: (Coordinate) -> Void
    let onCurveTap: (CurveSegment) -> Void

    init(stops: [Coordinate], route: RouteResult?, mapError: Binding<String?>, fitRouteOnLoad: Bool = false, showsRouteAnnotations: Bool = true, previewPresentation: Bool = false, onMapTap: @escaping (Coordinate) -> Void, onCurveTap: @escaping (CurveSegment) -> Void) {
        self.stops = stops
        self.route = route
        self._mapError = mapError
        self.fitRouteOnLoad = fitRouteOnLoad
        self.showsRouteAnnotations = showsRouteAnnotations
        self.previewPresentation = previewPresentation
        self.onMapTap = onMapTap
        self.onCurveTap = onCurveTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onMapTap: onMapTap, onCurveTap: onCurveTap) }

    func makeUIView(context: Context) -> MapView {
        let style: StyleURI = colorScheme == .dark ? .dark : .streets
        let options = MapInitOptions(cameraOptions: CameraOptions(center: CLLocationCoordinate2D(latitude: 47.4387, longitude: -121.8226), zoom: 9), styleURI: style)
        let mapView = MapView(frame: .zero, mapInitOptions: options)
        mapView.ornaments.options.compass.visibility = .hidden
        mapView.ornaments.options.scaleBar.visibility = .visible
        mapView.ornaments.options.scaleBar.margins = CGPoint(x: 20, y: 8)
        mapView.ornaments.options.scaleBar.units = distanceUnit == "km" ? .metric : .imperial
        mapView.ornaments.options.attributionButton.position = .topTrailing
        mapView.ornaments.options.attributionButton.margins = CGPoint(x: 14, y: 1)
        mapView.ornaments.options.logo.position = .topTrailing
        mapView.ornaments.options.logo.margins = CGPoint(x: 14, y: 40)
        context.coordinator.mapView = mapView
        context.coordinator.lastColorScheme = colorScheme
        context.coordinator.currentColorScheme = colorScheme
        context.coordinator.fitRouteOnLoad = fitRouteOnLoad
        context.coordinator.showsRouteAnnotations = showsRouteAnnotations
        context.coordinator.previewPresentation = previewPresentation
        context.coordinator.onMapError = { message in
            DispatchQueue.main.async { mapError = message }
        }
        mapView.mapboxMap.onMapLoadingError.observeNext { [weak coordinator = context.coordinator] error in
            coordinator?.onMapError?(error.localizedDescription)
        }.store(in: &context.coordinator.cancellables)
        mapView.mapboxMap.onMapLoaded.observeNext { [weak coordinator = context.coordinator] _ in
            coordinator?.onMapLoaded()
        }.store(in: &context.coordinator.cancellables)
        mapView.gestures.singleTapGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.didTapMap(_:)))
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onCurveTap = onCurveTap
        context.coordinator.showsRouteAnnotations = showsRouteAnnotations
        context.coordinator.previewPresentation = previewPresentation
        mapView.ornaments.options.scaleBar.units = distanceUnit == "km" ? .metric : .imperial
        context.coordinator.onMapError = { message in
            DispatchQueue.main.async { mapError = message }
        }
        context.coordinator.updateStyle(for: colorScheme)
        context.coordinator.render(stops: stops, route: route)
    }

    final class Coordinator: NSObject {
        weak var mapView: MapView?
        var onMapTap: (Coordinate) -> Void
        var onCurveTap: (CurveSegment) -> Void
        var onMapError: ((String) -> Void)?
        var cancellables = Set<AnyCancelable>()
        var lastColorScheme: ColorScheme?
        var currentColorScheme: ColorScheme = .light
        private var lastRouteSignature: String?
        private var lastStops: [Coordinate] = []
        private var currentRoute: RouteResult?
        private var currentStops: [Coordinate] = []
        private var lineManager: PolylineAnnotationManager?
        private var circleManager: CircleAnnotationManager?
        private var badgeManager: PointAnnotationManager?
        private var controlManager: PointAnnotationManager?
        var fitRouteOnLoad = false
        var showsRouteAnnotations = true
        var previewPresentation = false

        init(onMapTap: @escaping (Coordinate) -> Void, onCurveTap: @escaping (CurveSegment) -> Void) { self.onMapTap = onMapTap; self.onCurveTap = onCurveTap }

        func updateStyle(for colorScheme: ColorScheme) {
            guard let mapView, lastColorScheme != colorScheme else { return }
            lastColorScheme = colorScheme
            currentColorScheme = colorScheme
            mapView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
            mapView.mapboxMap.loadStyleURI(colorScheme == .dark ? .dark : .streets)
        }

        func onMapLoaded() {
            onMapError?("")
            lineManager = nil
            circleManager = nil
            badgeManager = nil
            controlManager = nil
            lastRouteSignature = nil
            lastStops = []
            render(stops: currentStops, route: currentRoute)
        }

        @objc func didTapMap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView, recognizer.state == .ended else { return }
            let point = recognizer.location(in: mapView)
            let coordinate = mapView.mapboxMap.coordinate(for: point)
            onMapTap(Coordinate(coordinate.longitude, coordinate.latitude))
        }

        func render(stops: [Coordinate], route: RouteResult?) {
            guard let mapView else { return }
            currentStops = stops
            currentRoute = route
            let stopsChanged = stops != lastStops
            // Enhancements retain the same route ID, so use the pace-note
            // presentation data too. Otherwise a maneuver direction can be
            // correctly calculated but never make it onto the map.
            let routeSignature = route.map { route in
                route.id + route.curves.map {
                    "\($0.id):\($0.direction.rawValue):\($0.presentationDirection.rawValue):\($0.routeStartMeters):\($0.routeEndMeters):\($0.control?.rawValue ?? "")"
                }.joined(separator: "|")
            }
            let routeChanged = routeSignature != lastRouteSignature
            if lineManager == nil { lineManager = mapView.annotations.makePolylineAnnotationManager() }
            if circleManager == nil { circleManager = mapView.annotations.makeCircleAnnotationManager() }
            if badgeManager == nil { badgeManager = mapView.annotations.makePointAnnotationManager() }
            if controlManager == nil { controlManager = mapView.annotations.makePointAnnotationManager() }
            if routeChanged {
                lastRouteSignature = routeSignature
                if let route {
                    let straightColor = currentColorScheme == .dark ? UIColor(white: 1, alpha: 1) : UIColor(red: 0.06, green: 0.13, blue: 0.14, alpha: 1)
                    let routeSegments = previewPresentation ? [RouteDisplaySegment(coordinates: route.coordinates, color: .straight)] : PaceNotesCore.colorizeRoute(route.coordinates, curves: route.curves)
                    lineManager?.annotations = routeSegments.map { segment in
                        var line = PolylineAnnotation(lineCoordinates: segment.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                        let color: UIColor
                        switch segment.color {
                        case .straight: color = previewPresentation ? (currentColorScheme == .dark ? .white : .black) : straightColor
                        case .left: color = UIColor(red: 0.16, green: 0.47, blue: 0.93, alpha: 1)
                        case .right: color = UIColor(red: 0.86, green: 0.26, blue: 0.26, alpha: 1)
                        }
                        line.lineColor = StyleColor(color); line.lineWidth = 5; line.lineOpacity = 1
                        return line
                    }
                    var paceBadges: [PointAnnotation] = showsRouteAnnotations ? route.curves.enumerated().compactMap { index, curve in
                        // A stop-control icon carries the note when it coincides
                        // with a turn, avoiding two conflicting warnings.
                        guard curve.control == nil else { return nil }
                        let isIntersection = curve.approachRoadName != nil && curve.approachRoadName != curve.roadName
                        let location = isIntersection ? PaceNotesCore.routeCurveMidpoint(route: route.coordinates, curve: curve) : PaceNotesCore.routeCurveApex(route: route.coordinates, curve: curve)
                        var badge = PointAnnotation(coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                        let label = isIntersection ? "I\(curve.presentationDirection == .left ? "L" : "R")" : "\(curve.direction == .left ? "L" : "R")\(curve.rating)\(curve.modifier ?? "")"
                        badge.image = .init(image: makePaceBadge(label: label, color: curve.presentationDirection == .left ? .systemBlue : .systemRed), name: "pace-\(index)-\(label)")
                        badge.tapHandler = { [weak self] _ in self?.onCurveTap(curve); return true }
                        return badge
                    } : []
                    if showsRouteAnnotations {
                        paceBadges += route.gradeEvents.enumerated().map { index, event in
                            var badge = PointAnnotation(coordinate: CLLocationCoordinate2D(latitude: event.coordinate.latitude, longitude: event.coordinate.longitude))
                            let label = event.kind == .bump ? "B" : "D"
                            let textColor: UIColor = currentColorScheme == .dark ? .black : .white
                            badge.image = .init(image: makePaceBadge(label: label, color: UIColor(red: 0.30, green: 0.55, blue: 0.08, alpha: 1), textColor: textColor), name: "grade-\(index)-\(label)")
                            return badge
                        }
                    }
                    badgeManager?.annotations = paceBadges
                    controlManager?.annotations = showsRouteAnnotations ? route.controls.enumerated().map { index, control in
                        var annotation = PointAnnotation(coordinate: CLLocationCoordinate2D(latitude: control.coordinate.latitude, longitude: control.coordinate.longitude))
                        annotation.image = .init(image: makeRouteControlBadge(control.kind), name: "control-\(index)-\(control.kind.rawValue)")
                        return annotation
                    } : []
                    if fitRouteOnLoad {
                        let coordinates = route.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                        let camera = mapView.mapboxMap.camera(for: coordinates, padding: UIEdgeInsets(top: 34, left: 28, bottom: 34, right: 28), bearing: 0, pitch: 0)
                        mapView.mapboxMap.setCamera(to: camera)
                    }
                } else {
                    lineManager?.annotations = []
                    badgeManager?.annotations = []
                    controlManager?.annotations = []
                }
            }
            if stopsChanged {
                lastStops = stops
                let displayedStops = previewPresentation && stops.count > 1 ? [stops[0], stops[stops.count - 1]] : stops
                circleManager?.annotations = displayedStops.enumerated().map { index, stop in
                var annotation = CircleAnnotation(centerCoordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude))
                let isStart = index == 0
                let isEnd = displayedStops.count > 1 && index == displayedStops.count - 1
                annotation.circleColor = StyleColor(isStart ? UIColor(red: 0.86, green: 1, blue: 0.32, alpha: 1) : isEnd ? UIColor.systemRed : UIColor.white)
                annotation.circleRadius = previewPresentation ? 5 : (index == 0 || index == displayedStops.count - 1 ? 9 : 7)
                annotation.circleStrokeColor = StyleColor(UIColor(red: 0.06, green: 0.13, blue: 0.14, alpha: 1)); annotation.circleStrokeWidth = 3
                return annotation
                }
            }
        }
    }
}

private func makeRouteControlBadge(_ control: RouteControlKind) -> UIImage {
    let size = CGSize(width: 21, height: 21)
    return UIGraphicsImageRenderer(size: size).image { context in
        if control == .stopSign {
            let path = UIBezierPath()
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4 - .pi / 8
                let point = CGPoint(x: center.x + cos(angle) * 8.5, y: center.y + sin(angle) * 8.5)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.close()
            UIColor.systemRed.setFill(); path.fill()
            UIColor.white.setStroke(); context.cgContext.setLineWidth(1.4); path.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 5.2, weight: .black), .foregroundColor: UIColor.white]
            "STOP".draw(at: CGPoint(x: 3.5, y: 7), withAttributes: attributes)
        } else {
            let rect = CGRect(x: 5, y: 1, width: 11, height: 19)
            UIColor.black.setFill(); UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()
            [UIColor.systemRed, .systemYellow, .systemGreen].enumerated().forEach { index, color in
                color.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 8, y: 3.5 + CGFloat(index) * 5, width: 5, height: 5))
            }
            UIColor.white.setStroke(); context.cgContext.setLineWidth(1); UIBezierPath(roundedRect: rect, cornerRadius: 4).stroke()
        }
    }
}

private func makePaceBadge(label: String, color: UIColor, textColor: UIColor = .white) -> UIImage {
    let size = CGSize(width: 34, height: 34)
    return UIGraphicsImageRenderer(size: size).image { context in
        let rect = CGRect(origin: .zero, size: size)
        color.setFill(); context.cgContext.fillEllipse(in: rect.insetBy(dx: 2, dy: 2))
        UIColor(red: 0.06, green: 0.13, blue: 0.14, alpha: 1).setStroke(); context.cgContext.setLineWidth(2); context.cgContext.strokeEllipse(in: rect.insetBy(dx: 2, dy: 2))
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .black), .foregroundColor: textColor]
        let textRect = label.boundingRect(with: size, options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
        label.draw(at: CGPoint(x: (size.width - textRect.width) / 2, y: (size.height - textRect.height) / 2), withAttributes: attributes)
    }
}
