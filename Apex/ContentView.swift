import Combine
import SwiftUI

private struct RoutePlannerView: View {
    @ObservedObject var library: RouteLibrary
    @Environment(\.colorScheme) private var colorScheme
    @State private var stops: [Coordinate] = []
    @State private var routes: [RouteResult] = []
    @State private var routeIndex = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedCurve: CurveSegment?
    @State private var mapError: String?
    @State private var isEditing = true
    @State private var showingRouteOverview = false
    @AppStorage("distanceUnit") private var distanceUnit = "mi"
    @AppStorage("heightUnit") private var heightUnit = "ft"
    private let routing = MapboxRoutingService()

    private var route: RouteResult? { routes.indices.contains(routeIndex) ? routes[routeIndex] : nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MapboxRouteMap(stops: stops, route: route, mapError: $mapError) { coordinate in
                if isEditing { addStop(coordinate) } else { selectNearestCurve(to: coordinate) }
            } onCurveTap: { curve in
                selectedCurve = curve
            }
            .ignoresSafeArea()

            if let mapError, !mapError.isEmpty {
                VStack(spacing: 8) {
                    Text("MAPBOX MAP ERROR").font(.caption.weight(.bold)).tracking(1)
                    Text(mapError).font(.footnote).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            LinearGradient(colors: [colorScheme == .dark ? .black.opacity(0.72) : .white.opacity(0.86), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
                .ignoresSafeArea(edges: .top)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    ApexLogo()
                    Spacer()
                }
            }
            .padding(.horizontal, 22).padding(.top, 28)

            VStack {
                Spacer()
                bottomPanel
            }

            if let selectedCurve {
                VStack {
                    Spacer()
                    CurveDetailCard(curve: selectedCurve, roadName: selectedCurve.roadName ?? route?.roadName) {
                        self.selectedCurve = nil
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 178)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedCurve?.id)
        .onChange(of: library.routeToEdit) { _, stored in
            loadStoredRouteIfNeeded(stored)
        }
        .onAppear { loadStoredRouteIfNeeded(library.routeToEdit) }
        .fullScreenCover(isPresented: $showingRouteOverview) {
            if let route {
                RouteOverviewView(route: route, isSaved: library.contains(stops: stops), initialDriveName: library.routes.first(where: { $0.id == library.editingRouteID })?.title) {
                    isEditing = true
                    showingRouteOverview = false
                } onClose: {
                    showingRouteOverview = false
                    if library.contains(stops: stops) { resetRoute() }
                } onSave: { shouldSave, title in
                    if shouldSave { library.save(stops: stops, title: title) }
                    else { library.remove(stops: stops) }
                }
            } else {
                EmptyView()
            }
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let errorMessage { Text(errorMessage).font(.caption.weight(.semibold)).foregroundStyle(.red) }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stops.isEmpty ? "Know the bend" : route == nil ? "Route in progress" : isEditing ? "Route ready · editing" : "Route ready")
                        .font(.system(size: 23, weight: .bold, design: .rounded)).foregroundStyle(Color.apexInk)
                    if stops.isEmpty || isEditing {
                        Text(stops.isEmpty ? "Tap the map to set a start, then an end. Keep tapping to add waypoints." : statusText)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.apexMuted).lineLimit(2)
                    }
                }
                Spacer()
                if isLoading { ProgressView().tint(Color.apexAcid) }
            }

            if let route {
                HStack(spacing: 0) {
                    metric(distanceText(for: route.distanceMeters), "DISTANCE")
                    Divider().frame(height: 28)
                    metric("\(Int(route.durationSeconds / 60)) min", "EST. TIME")
                    Divider().frame(height: 28)
                    metric("\(route.paceNoteCount)", "PACE NOTES")
                }
                if !route.curves.isEmpty { curveStrip(for: route) }
            }

            HStack(spacing: 8) {
                Button { undoLastStop() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 38, height: 36) }
                    .buttonStyle(.bordered).controlSize(.small).tint(colorScheme == .dark ? .white : .black).foregroundStyle(colorScheme == .dark ? .white : .black).disabled(!isEditing || stops.isEmpty)
                Button { resetRoute() } label: { Image(systemName: "trash").frame(width: 38, height: 36) }
                    .buttonStyle(.bordered).controlSize(.small).tint(colorScheme == .dark ? .white : .black).foregroundStyle(colorScheme == .dark ? .white : .black).disabled(stops.isEmpty)
                Button { doneOrEdit() } label: { Label(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil").lineLimit(1).frame(maxWidth: .infinity, minHeight: 36) }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
                    .background(colorScheme == .dark ? .white : .black, in: Capsule())
                    .disabled(stops.count < 2 || route == nil)
            }
        }
        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.apexLine, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 20)
    }

    private var statusText: String { stops.count == 1 ? "Tap again to set the end point." : stops.count == 2 ? "Tap to extend with a waypoint." : "\(stops.count - 2) waypoint\(stops.count == 3 ? "" : "s") · tap to extend." }
    @ViewBuilder private func curveStrip(for route: RouteResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(Color.apexLine).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 7) {
                    let groups = roadGroups(for: route.curves)
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        CurveTimelineGroup(group: group) { curve in selectedCurve = curve }
                        if index < groups.count - 1 {
                            Rectangle().fill(Color.apexLine).frame(width: 1, height: 31).padding(.bottom, 1)
                        }
                    }
                }
            }
        }
    }
    private func distanceText(for meters: Double) -> String { distanceUnit == "km" ? "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km" : "\((meters / 1_609.344).formatted(.number.precision(.fractionLength(1)))) mi" }
    private func metric(_ value: String, _ label: String) -> some View { VStack(spacing: 2) { Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Color.apexInk); Text(label).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(Color.apexMuted) }.frame(maxWidth: .infinity) }
    private func loadStoredRouteIfNeeded(_ stored: StoredRoute?) {
        guard let stored else { return }
        stops = stored.stops
        routes = []
        routeIndex = 0
        isEditing = true
        library.editingRouteID = stored.id
        library.routeToEdit = nil
        if stops.count >= 2 { Task { await calculateRoute() } }
    }
    private func addStop(_ coordinate: Coordinate) { stops.append(coordinate); if stops.count >= 2 { Task { await calculateRoute() } } }
    private func undoLastStop() {
        guard isEditing, !stops.isEmpty else { return }
        stops.removeLast(); routes = []; routeIndex = 0
        if stops.count >= 2 { Task { await calculateRoute() } }
    }
    private func selectNearestCurve(to coordinate: Coordinate) {
        guard let route, let curve = route.curves.min(by: { lhs, rhs in
            PaceNotesCore.distanceMeters(coordinate, PaceNotesCore.routeCurveApex(route: route.coordinates, curve: lhs)) < PaceNotesCore.distanceMeters(coordinate, PaceNotesCore.routeCurveApex(route: route.coordinates, curve: rhs))
        }) else { return }
        if PaceNotesCore.distanceMeters(coordinate, PaceNotesCore.routeCurveApex(route: route.coordinates, curve: curve)) < 350 { selectedCurve = curve }
    }
    private func calculateRoute() async {
        isLoading = true; errorMessage = nil
        do {
            let nextRoutes = try await routing.routes(for: stops)
            routes = nextRoutes; routeIndex = 0
            if let snapped = nextRoutes.first?.snappedStops, snapped.count == stops.count { stops = snapped }
            if let id = library.editingRouteID { library.update(id: id, stops: stops) }
            if let primaryRoute = nextRoutes.first {
                Task {
                    let enrichedRoute = await routing.applyingRouteEnhancements(to: primaryRoute)
                    guard routes.first?.id == primaryRoute.id else { return }
                    routes[0] = enrichedRoute
                }
            }
        } catch { errorMessage = error.localizedDescription; routes = [] }
        isLoading = false
    }
    private func resetRoute() {
        stops = []; routes = []; routeIndex = 0; errorMessage = nil; isEditing = true
        library.editingRouteID = nil
    }
    private func doneOrEdit() {
        guard stops.count >= 2, route != nil else { return }
        if isEditing {
            isEditing = false
            showingRouteOverview = true
        } else {
            isEditing = true
        }
    }

    private func roadGroups(for curves: [CurveSegment]) -> [RoadCurveGroup] {
        curves.reduce(into: []) { result, curve in
            if result.last?.roadName == curve.roadName {
                result[result.count - 1].curves.append(curve)
            } else {
                result.append(RoadCurveGroup(roadName: curve.roadName ?? "Route", curves: [curve]))
            }
        }
    }
}

struct ContentView: View {
    @AppStorage("themeMode") private var themeMode = "system"
    @State private var tab: AppSection = .plan
    @StateObject private var library = RouteLibrary()
    @State private var savedRouteToPreview: StoredRoute?

    var body: some View {
        ZStack {
            // Keep the planner mounted while a user changes app settings so its
            // in-progress route and map state are not discarded.
            RoutePlannerView(library: library)
                .opacity(tab == .plan ? 1 : 0)
                .allowsHitTesting(tab == .plan)
                .accessibilityHidden(tab != .plan)

            if tab != .plan {
                switch tab {
                case .saved: SavedRoutesView(library: library) { savedRouteToPreview = $0 }
                case .drive: DriveHomeView()
                case .history: HistoryView()
                case .settings: SettingsView()
                case .plan: EmptyView()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selection: $tab)
        }
        .fullScreenCover(item: $savedRouteToPreview) { storedRoute in
            SavedRoutePreviewLoader(storedRoute: storedRoute, library: library) {
                savedRouteToPreview = nil
                library.routeToEdit = storedRoute
                tab = .plan
            } onClose: {
                savedRouteToPreview = nil
            }
        }
        .preferredColorScheme(themeMode == "dark" ? .dark : themeMode == "light" ? .light : nil)
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case saved, plan, drive, history, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self { case .saved: return "bookmark"; case .plan: return "map"; case .drive: return "steeringwheel"; case .history: return "clock.arrow.circlepath"; case .settings: return "gearshape" }
    }
}

private struct StoredRoute: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var stops: [Coordinate]
    var savedAt: Date
}

private final class RouteLibrary: ObservableObject {
    @Published private(set) var routes: [StoredRoute] = []
    @Published var routeToEdit: StoredRoute?
    @Published var editingRouteID: UUID?
    private let storageKey = "apex.savedRoutes.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey), let decoded = try? JSONDecoder().decode([StoredRoute].self, from: data) {
            routes = decoded.sorted { $0.savedAt > $1.savedAt }
        }
    }

    func contains(stops: [Coordinate]) -> Bool { routes.contains { $0.stops == stops } }
    func save(stops: [Coordinate], title: String) {
        guard stops.count >= 2 else { return }
        if let index = routes.firstIndex(where: { $0.stops == stops }) {
            routes[index].title = title
            routes[index].savedAt = Date()
        } else {
            routes.append(StoredRoute(id: UUID(), title: title, stops: stops, savedAt: Date()))
        }
        persist()
    }
    func remove(stops: [Coordinate]) {
        routes.removeAll { $0.stops == stops }
        persist()
    }
    func update(id: UUID, stops: [Coordinate]) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].stops = stops
        routes[index].savedAt = Date()
        persist()
    }
    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(routes), forKey: storageKey)
        routes.sort { $0.savedAt > $1.savedAt }
    }
}

private struct AppTabBar: View {
    @Binding var selection: AppSection
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppSection.allCases) { section in
                Button { selection = section } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.icon).font(.system(size: 15, weight: .semibold))
                        Text(section.title).font(.system(size: 9, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(selection == section ? Color.apexAccent : Color.apexMuted)
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.apexLine, lineWidth: 1))
        .padding(.horizontal, 18).padding(.bottom, 5)
    }
}

private struct SavedRoutesView: View {
    @ObservedObject var library: RouteLibrary
    let openPreview: (StoredRoute) -> Void
    @State private var routePendingDeletion: StoredRoute?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved routes").font(.system(size: 32, weight: .black, design: .rounded))
            if library.routes.isEmpty {
                Spacer()
                ContentUnavailableView("No saved routes", systemImage: "bookmark", description: Text("Save a completed route to build your library."))
            } else {
                List(library.routes) { route in
                    Button {
                        openPreview(route)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(route.title).font(.headline)
                            Text("\(route.stops.count) planner points · \(route.savedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(Color.apexMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { routePendingDeletion = route } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }.listStyle(.plain)
            }
            Spacer()
        }
        .padding(22)
        .confirmationDialog("Delete this saved route?", isPresented: Binding(
            get: { routePendingDeletion != nil },
            set: { if !$0 { routePendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete route", role: .destructive) {
                if let route = routePendingDeletion { library.remove(stops: route.stops) }
                routePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { routePendingDeletion = nil }
        } message: {
            Text("This removes the locally saved route from your library.")
        }
    }
}

/// Opens a saved route directly into its preview. Routing happens behind this
/// lightweight loading state so the planner never appears or flickers first.
private struct SavedRoutePreviewLoader: View {
    let storedRoute: StoredRoute
    @ObservedObject var library: RouteLibrary
    let onEdit: () -> Void
    let onClose: () -> Void
    @State private var route: RouteResult?
    @State private var errorMessage: String?
    private let routing = MapboxRoutingService()

    var body: some View {
        Group {
            if let route {
                RouteOverviewView(route: route, isSaved: true, initialDriveName: storedRoute.title, onEdit: onEdit, onClose: onClose) { shouldSave, title in
                    if shouldSave { library.save(stops: storedRoute.stops, title: title) }
                    else { library.remove(stops: storedRoute.stops) }
                }
            } else if let errorMessage {
                ContentUnavailableView("Couldn’t open route", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(Color.apexAccent)
                    Text("Opening route").font(.headline)
                }
            }
        }
        .task { await loadRoute() }
    }

    private func loadRoute() async {
        guard route == nil else { return }
        do {
            guard let baseRoute = try await routing.routes(for: storedRoute.stops).first else {
                errorMessage = "No route could be generated from the saved points."
                return
            }
            // Present the familiar preview as soon as Mapbox returns. Optional
            // enrichment can then refresh it without delaying saved-route open.
            route = baseRoute
            let enrichedRoute = await routing.applyingRouteEnhancements(to: baseRoute)
            route = enrichedRoute
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HistoryView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("History").font(.system(size: 32, weight: .black, design: .rounded))
            Text("Completed drives will appear here.").foregroundStyle(Color.apexMuted)
            Spacer()
            ContentUnavailableView("No completed drives", systemImage: "clock.arrow.circlepath")
            Spacer()
        }.padding(22)
    }
}

private struct DriveHomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Drive").font(.system(size: 32, weight: .black, design: .rounded))
            Text("Select a saved route to begin a drive preview.").foregroundStyle(Color.apexMuted)
            Spacer()
            ContentUnavailableView("No route selected", systemImage: "steeringwheel", description: Text("Saved routes will be available here."))
            Spacer()
        }.padding(22)
    }
}

private struct ApexLogo: View {
    var body: some View { HStack(spacing: 9) { Text("↝").font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(Color.apexAcid).frame(width: 37, height: 37).background(Color.apexLogoBackground, in: Circle()); VStack(alignment: .leading, spacing: 1) { Text("APEX").font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(1.6); Text("PACE NOTES").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4) }.foregroundStyle(Color.apexInk) } }
}

private struct RoadCurveGroup: Identifiable {
    var id: String { curves.first?.id ?? roadName }
    let roadName: String
    var curves: [CurveSegment]
}

private struct CurveTimelineGroup: View {
    let group: RoadCurveGroup
    let action: (CurveSegment) -> Void

    var body: some View {
        let width = CGFloat(group.curves.count * 44 + max(0, group.curves.count - 1) * 7)
        VStack(spacing: 3) {
            Text(PaceNotesCore.compactRoadName(group.roadName, characterCapacity: max(7, group.curves.count * 9)).uppercased())
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(0.5).foregroundStyle(Color.apexMuted)
                .lineLimit(1).frame(width: width)
            HStack(spacing: 7) {
                ForEach(group.curves) { curve in
                    Button { action(curve) } label: {
                        Text("\(curve.presentationDirection == .left ? "L" : "R")\(curve.rating)\(curve.modifier ?? "")")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 27)
                            .background(curve.presentationDirection == .left ? Color.apexBlue : Color.apexRed, in: Capsule())
                    }
                }
            }
        }
    }
}

private struct CurveDetailCard: View {
    let curve: CurveSegment
    let roadName: String?
    let dismiss: () -> Void
    @AppStorage("curveLengthUnit") private var curveLengthUnit = "m"
    @AppStorage("heightUnit") private var heightUnit = "ft"
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PACE NOTE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.4).foregroundStyle(Color.apexMuted)
                    Text(detailTitle)
                        .font(.system(size: 27, weight: .black, design: .rounded))
                        .foregroundStyle(curve.presentationDirection == .left ? Color.apexBlue : Color.apexRed)
                }
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.apexMuted)
                        .frame(width: 28, height: 28)
                        .background(Color.apexInk.opacity(0.08), in: Circle())
                }
            }
            if let roadName, !roadName.isEmpty {
                Text(roadDescription.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2).foregroundStyle(Color.apexMuted)
            }
            if curve.control != nil || curve.elevationChangeMeters != nil {
                HStack(spacing: 7) {
                    if let control = curve.control { detailTag(control.displayName) }
                    if let elevation = curve.elevationChangeMeters { detailTag(elevationText(elevation)) }
                }
            }
            HStack(spacing: 0) {
                detailMetric(lengthText(curve.lengthMeters), "LENGTH")
                Divider().frame(height: 34)
                detailMetric("\(Int(curve.headingChangeDegrees))°", "HEADING")
                Divider().frame(height: 34)
                detailMetric(curve.modifier?.capitalized ?? "None", "MODIFIER")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .top) {
            Capsule().fill(curve.presentationDirection == .left ? Color.apexBlue : Color.apexRed)
                .frame(width: 74, height: 3).padding(.top, 7)
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
    }

    private func detailMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline.weight(.bold)).foregroundStyle(Color.apexInk)
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(Color.apexMuted)
        }.frame(maxWidth: .infinity)
    }

    private var roadDescription: String {
        guard let approach = curve.approachRoadName, let destination = roadName, approach != destination else { return roadName ?? "" }
        return "\(approach) → \(destination)"
    }
    private func detailTag(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.7)
            .foregroundStyle(Color.apexMuted).padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.apexInk.opacity(0.08), in: Capsule())
    }
    private func elevationText(_ meters: Double) -> String {
        if heightUnit == "m" {
            let value = Int(meters.rounded())
            return "\(value >= 0 ? "↑" : "↓") \(abs(value)) m"
        }
        let feet = Int((meters * 3.28084).rounded())
        return "\(feet >= 0 ? "↑" : "↓") \(abs(feet)) ft"
    }
    private func lengthText(_ meters: Double) -> String {
        curveLengthUnit == "ft" ? "\(Int((meters * 3.28084).rounded())) ft" : "\(Int(meters.rounded())) m"
    }
    private var detailTitle: String {
        if let control = curve.control { return "\(control.displayName) \(curve.presentationDirection == .left ? "Left" : "Right")" }
        if curve.approachRoadName != nil && curve.approachRoadName != curve.roadName { return "Intersection \(curve.presentationDirection == .left ? "Left" : "Right")" }
        return curve.displayLabel
    }
}

/// This is intentionally a full page rather than another map overlay. It is the
/// hand-off point for the future drive/preview experience.
private struct PreviewPaceNote: Identifiable {
    let id: String
    let routeDistance: Double
    let curve: CurveSegment?
    let control: RouteControl?
    let gradeEvent: GradeEvent?
}

private struct RouteOverviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    let route: RouteResult
    let onEdit: () -> Void
    let onClose: () -> Void
    let onSave: (Bool, String) -> Void
    @State private var mapError: String?
    @State private var selectedCurve: CurveSegment?
    @State private var selectedControl: RouteControl?
    @State private var selectedGrade: GradeEvent?
    @State private var showingFullMap = false
    @State private var showingNameEditor = false
    @State private var customDriveName = ""
    @State private var isSaved: Bool
    @State private var showingSavedMessage = false
    @State private var showingDeleteConfirmation = false
    @AppStorage("distanceUnit") private var distanceUnit = "mi"
    @AppStorage("heightUnit") private var heightUnit = "ft"

    init(route: RouteResult, isSaved: Bool, initialDriveName: String? = nil, onEdit: @escaping () -> Void, onClose: @escaping () -> Void, onSave: @escaping (Bool, String) -> Void) {
        self.route = route
        self.onEdit = onEdit
        self.onClose = onClose
        self.onSave = onSave
        self._isSaved = State(initialValue: isSaved)
        self._customDriveName = State(initialValue: initialDriveName ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.bold)).frame(width: 38, height: 38)
                            .background(.thinMaterial, in: Circle())
                    }
                    Spacer()
                    ZStack {
                        if showingSavedMessage {
                            Text(isSaved ? "SAVED LOCALLY" : "DELETED ROUTE")
                                .transition(.opacity)
                        } else {
                            Text(isSaved ? "SAVED ROUTE" : "ROUTE PREVIEW").transition(.opacity)
                        }
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.4).foregroundStyle(Color.apexMuted)
                    .animation(.easeInOut(duration: 0.25), value: showingSavedMessage)
                    Spacer()
                    HStack(spacing: 7) {
                        if isSaved {
                            Button { showingDeleteConfirmation = true } label: {
                                Image(systemName: "trash")
                                    .font(.subheadline.weight(.bold)).frame(width: 38, height: 38)
                                    .background(.thinMaterial, in: Circle())
                            }
                        } else {
                            Button {
                                isSaved = true
                                onSave(true, driveName)
                                showingSavedMessage = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showingSavedMessage = false }
                            } label: {
                                Image(systemName: "bookmark")
                                    .font(.subheadline.weight(.bold)).frame(width: 38, height: 38)
                                    .background(.thinMaterial, in: Circle())
                            }
                        }
                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 12).frame(height: 38)
                            .background(Color.apexInk, in: Capsule()).foregroundStyle(colorScheme == .dark ? .black : .white)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(driveName).font(.system(size: 31, weight: .black, design: .rounded))
                        Button {
                            customDriveName = driveName
                            showingNameEditor = true
                        } label: {
                            Image(systemName: "pencil.circle.fill").font(.system(size: 15)).foregroundStyle(Color.apexMuted)
                        }
                    }
                }

                MapboxRouteMap(stops: route.snappedStops, route: route, mapError: $mapError, fitRouteOnLoad: true, showsRouteAnnotations: false, previewPresentation: true, onMapTap: { _ in
                    showingFullMap = true
                }, onCurveTap: { curve in
                    selectedCurve = curve
                })
                    .frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.apexLine, lineWidth: 1))

                HStack(spacing: 0) {
                    overviewMetric(distanceText(route.distanceMeters), "DISTANCE")
                    Divider().frame(height: 34)
                    overviewMetric("\(Int(route.durationSeconds / 60)) min", "EST. TIME")
                    Divider().frame(height: 34)
                    overviewMetric("\(route.paceNoteCount)", "PACE NOTES")
                }
                .padding(.vertical, 8)

                if !turnDirections.isEmpty {
                    overviewSection("ROUTE TURNS") {
                        Text(turnDirections).font(.caption).foregroundStyle(Color.apexMuted)
                    }
                }

                overviewSection("PACE NOTES") {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(previewNotes.enumerated()), id: \.element.id) { index, note in
                            Button {
                                selectedCurve = nil; selectedControl = nil; selectedGrade = nil
                                if let curve = note.curve { selectedCurve = curve }
                                if let control = note.control { selectedControl = control }
                                if let grade = note.gradeEvent { selectedGrade = grade }
                            } label: {
                            HStack(spacing: 12) {
                                Text((index + 1).formatted(.number.precision(.integerLength(2))))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color.apexAccent)
                                    .frame(width: 22, alignment: .leading)
                                Text(noteCode(note))
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                                    .foregroundStyle(note.gradeEvent != nil ? (colorScheme == .dark ? .black : .white) : .white)
                                    .frame(width: 42, height: 27)
                                    .background(noteColor(note), in: Capsule())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(noteTitle(note)).font(.subheadline.weight(.bold))
                                    Text(noteRoad(note))
                                        .font(.caption).foregroundStyle(Color.apexMuted).lineLimit(1)
                                }
                                Spacer()
                                Text(noteDistance(note))
                                    .font(.caption.monospacedDigit()).foregroundStyle(Color.apexMuted)
                            }
                            .padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            if index < route.curves.count - 1 { Divider() }
                        }
                    }
                }

                overviewSection("ELEVATION PROFILE") {
                    VStack(alignment: .leading, spacing: 8) {
                        ElevationProfileChart(samples: route.elevationProfile, curves: route.curves, gradeEvents: route.gradeEvents)
                            .frame(height: 72)
                        if route.elevationProfile.isEmpty {
                            Text("Elevation data is unavailable for this route.").font(.caption).foregroundStyle(Color.apexMuted)
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 34)
        }
        .background(Color(uiColor: .systemBackground))
        .alert("Name this drive", isPresented: $showingNameEditor) {
            TextField("Drive name", text: $customDriveName)
            Button("Save") {
                if isSaved { onSave(true, customDriveName) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete this saved route?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete route", role: .destructive) {
                isSaved = false
                onSave(false, driveName)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the locally saved route from your library.")
        }
        .fullScreenCover(isPresented: $showingFullMap) {
            RouteMapExplorer(route: route, onClose: { showingFullMap = false })
        }
        .overlay(alignment: .bottom) {
            if let selectedCurve {
                CurveDetailCard(curve: selectedCurve, roadName: selectedCurve.roadName) { self.selectedCurve = nil }
                    .padding(.horizontal, 24).padding(.bottom, 22)
            }
            if let selectedControl {
                RouteControlDetailCard(control: selectedControl) { self.selectedControl = nil }
                    .padding(.horizontal, 24).padding(.bottom, 22)
            }
            if let selectedGrade {
                GradeDetailCard(event: selectedGrade) { self.selectedGrade = nil }
                    .padding(.horizontal, 24).padding(.bottom, 22)
            }
        }
    }

    private func overviewMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.8).foregroundStyle(Color.apexMuted)
        }.frame(maxWidth: .infinity)
    }

    private func overviewSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.3).foregroundStyle(Color.apexMuted)
            content()
        }
        .padding(15).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func distanceText(_ meters: Double) -> String {
        distanceUnit == "km" ? "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km" : "\((meters / 1_609.344).formatted(.number.precision(.fractionLength(1)))) mi"
    }

    private var driveName: String { customDriveName.isEmpty ? (route.driveTitle ?? "Route Drive") : customDriveName }
    private func roadDescription(for curve: CurveSegment) -> String {
        guard let approach = curve.approachRoadName, let destination = curve.roadName, approach != destination else { return curve.roadName ?? "Unnamed road" }
        return "Intersection"
    }
    private var turnDirections: String {
        guard let firstRoad = route.curves.first?.approachRoadName ?? route.curves.first?.roadName else { return "" }
        var moves = ["Begin on \(firstRoad)"]
        for curve in route.curves where curve.approachRoadName != nil && curve.approachRoadName != curve.roadName {
            if let destination = curve.roadName { moves.append("turn \(curve.presentationDirection == .left ? "left" : "right") on \(destination)") }
        }
        return moves.joined(separator: ", ") + "."
    }

    private var previewNotes: [PreviewPaceNote] {
        let curves = route.curves.map { curve in
            PreviewPaceNote(id: curve.id, routeDistance: (curve.routeStartMeters + curve.routeEndMeters) / 2, curve: curve, control: nil, gradeEvent: nil)
        }
        let standaloneControls = route.controls.filter { control in
            !route.curves.contains { control.routeDistanceMeters >= $0.routeStartMeters - 14 && control.routeDistanceMeters <= $0.routeEndMeters + 14 }
        }.map { control in
            PreviewPaceNote(id: control.id, routeDistance: control.routeDistanceMeters, curve: nil, control: control, gradeEvent: nil)
        }
        let grades = route.gradeEvents.map { event in
            PreviewPaceNote(id: event.id, routeDistance: event.routeDistanceMeters, curve: nil, control: nil, gradeEvent: event)
        }
        return (curves + standaloneControls + grades).sorted { $0.routeDistance < $1.routeDistance }
    }

    private func noteCode(_ note: PreviewPaceNote) -> String {
        if let control = note.control { return control.kind == .stopSign ? "SS" : "TL" }
        if let event = note.gradeEvent { return event.kind == .bump ? "B" : "D" }
        guard let curve = note.curve else { return "NOTE" }
        if curve.control != nil { return curve.control == .stopSign ? "SS" : "TL" }
        if curve.approachRoadName != nil && curve.approachRoadName != curve.roadName { return "I\(curve.presentationDirection == .left ? "L" : "R")" }
        return "\(curve.direction == .left ? "L" : "R")\(curve.rating)\(curve.modifier ?? "")"
    }
    private func noteTitle(_ note: PreviewPaceNote) -> String {
        if let control = note.control { return "\(control.kind.displayName) straight" }
        if let event = note.gradeEvent { return "\(event.kind == .bump ? "Bump" : "Dip") (\(elevationMagnitude(event.elevationChangeMeters)))" }
        guard let curve = note.curve else { return "Pace note" }
        if let control = curve.control { return "\(control.displayName) \(curve.presentationDirection == .left ? "left" : "right")" }
        if curve.approachRoadName != nil && curve.approachRoadName != curve.roadName { return "Intersection \(curve.presentationDirection == .left ? "Left" : "Right")" }
        return curve.displayLabel
    }
    private func noteRoad(_ note: PreviewPaceNote) -> String { note.curve.map(roadDescription(for:)) ?? note.gradeEvent?.roadName ?? "Intersection" }
    private func noteDistance(_ note: PreviewPaceNote) -> String { note.curve.map { "\(Int($0.lengthMeters)) m" } ?? "" }
    private func noteColor(_ note: PreviewPaceNote) -> Color {
        if note.control != nil { return Color.apexAccent }
        if let curve = note.curve, curve.control != nil {
            return curve.presentationDirection == .left ? Color.apexBlue : Color.apexRed
        }
        if note.gradeEvent != nil { return Color.apexAccent }
        return note.curve?.direction == .left ? Color.apexBlue : Color.apexRed
    }
    private func elevationMagnitude(_ meters: Double) -> String {
        heightUnit == "m" ? "\(abs(Int(meters.rounded()))) m" : "\(abs(Int((meters * 3.28084).rounded()))) ft"
    }
}

private struct ElevationProfileChart: View {
    let samples: [ElevationSample]
    let curves: [CurveSegment]
    let gradeEvents: [GradeEvent]
    @AppStorage("heightUnit") private var heightUnit = "ft"
    @AppStorage("distanceUnit") private var distanceUnit = "mi"
    var body: some View {
        GeometryReader { proxy in
            let values = samples.map(\.elevationMeters)
            let range = max((values.max() ?? 1) - (values.min() ?? 0), 1)
            let baseline = values.min() ?? 0
            ZStack {
                ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
                    Path { path in
                        let y = proxy.size.height - CGFloat(fraction) * (proxy.size.height - 8) - 4
                        path.move(to: CGPoint(x: 30, y: y)); path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }.stroke(Color.apexLine, style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    let value = baseline + range * fraction
                    Text(axisText(value)).font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundStyle(Color.apexMuted)
                        .position(x: 13, y: proxy.size.height - CGFloat(fraction) * (proxy.size.height - 8) - 4)
                }
                Path { path in
                    guard samples.count > 1 else { return }
                    for (index, sample) in samples.enumerated() {
                        let x = 30 + CGFloat(index) / CGFloat(samples.count - 1) * (proxy.size.width - 30)
                        let y = proxy.size.height - CGFloat((sample.elevationMeters - baseline) / range) * (proxy.size.height - 8) - 4
                        index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                }.stroke(Color.apexAccent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                ForEach(curves.filter { $0.modifier != nil }) { curve in
                    let totalDistance = max(max(samples.last?.routeDistanceMeters ?? 0, curves.map(\.routeEndMeters).max() ?? 0), 1)
                    let x = 30 + CGFloat((curve.routeStartMeters + curve.routeEndMeters) / 2 / totalDistance) * (proxy.size.width - 30)
                    Rectangle().fill(curve.modifier == "B" ? Color.apexRed : Color.apexBlue).frame(width: 1, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)
                }
                ForEach(gradeEvents) { event in
                    let totalDistance = max(max(samples.last?.routeDistanceMeters ?? 0, curves.map(\.routeEndMeters).max() ?? 0), 1)
                    let x = 30 + CGFloat(event.routeDistanceMeters / totalDistance) * (proxy.size.width - 30)
                    Rectangle().fill(Color.apexAccent).frame(width: 1, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)
                }
                let totalDistance = max(samples.last?.routeDistanceMeters ?? 0, 1)
                ForEach(1...3, id: \.self) { marker in
                    let displayDistance = Double(marker) * (distanceUnit == "km" ? 1 : 0.5)
                    let meters = distanceUnit == "km" ? displayDistance * 1_000 : displayDistance * 1_609.344
                    if meters < totalDistance {
                        let x = 30 + CGFloat(meters / totalDistance) * (proxy.size.width - 30)
                        Text("\(displayDistance.formatted(.number.precision(.fractionLength(1)))) \(distanceUnit)")
                            .font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundStyle(Color.apexMuted)
                            .position(x: x, y: proxy.size.height - 3)
                    }
                }
            }
        }
    }
    private func axisText(_ meters: Double) -> String {
        heightUnit == "m" ? "\(Int(meters.rounded()))m" : "\(Int((meters * 3.28084).rounded()))ft"
    }
}

private struct RouteControlDetailCard: View {
    let control: RouteControl
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: control.kind == .stopSign ? "octagon.fill" : "trafficlight.fill")
                .font(.title2).foregroundStyle(control.kind == .stopSign ? Color.apexRed : Color.apexAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text("ROUTE CONTROL").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(Color.apexMuted)
                Text(control.kind.displayName).font(.headline.weight(.bold))
                Text("Approach with care").font(.caption).foregroundStyle(Color.apexMuted)
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 28, height: 28).background(Color.apexInk.opacity(0.08), in: Circle()) }
        }
        .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}

private struct GradeDetailCard: View {
    let event: GradeEvent
    let dismiss: () -> Void
    @AppStorage("heightUnit") private var heightUnit = "ft"
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: event.kind == .bump ? "arrow.up.right" : "arrow.down.right")
                .font(.title2.weight(.bold)).foregroundStyle(Color.apexAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text("ELEVATION NOTE").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(Color.apexMuted)
                Text(event.kind == .bump ? "Bump" : "Dip").font(.headline.weight(.bold))
                Text(changeText).font(.caption).foregroundStyle(Color.apexMuted)
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 28, height: 28).background(Color.apexInk.opacity(0.08), in: Circle()) }
        }
        .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.22), lineWidth: 1))
    }
    private var changeText: String {
        let value = heightUnit == "m" ? Int(event.elevationChangeMeters.rounded()) : Int((event.elevationChangeMeters * 3.28084).rounded())
        return "\(value >= 0 ? "↑" : "↓") \(abs(value)) \(heightUnit)"
    }
}

private struct RouteMapExplorer: View {
    let route: RouteResult
    let onClose: () -> Void
    @State private var mapError: String?
    @State private var selectedCurve: CurveSegment?

    var body: some View {
        ZStack(alignment: .topLeading) {
            MapboxRouteMap(stops: route.snappedStops, route: route, mapError: $mapError, fitRouteOnLoad: true, onMapTap: { _ in }, onCurveTap: { curve in
                selectedCurve = curve
            })
            .ignoresSafeArea()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold)).frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.leading, 18).padding(.top, 68)
            if let selectedCurve {
                VStack {
                    Spacer()
                    CurveDetailCard(curve: selectedCurve, roadName: selectedCurve.roadName) { self.selectedCurve = nil }
                        .padding(.horizontal, 24).padding(.bottom, 28)
                }
            }
        }
    }
}

private struct SettingsView: View {
    @AppStorage("themeMode") private var themeMode = "system"
    @AppStorage("heightUnit") private var heightUnit = "ft"
    @AppStorage("distanceUnit") private var distanceUnit = "mi"
    @AppStorage("curveLengthUnit") private var curveLengthUnit = "m"
    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $themeMode) {
                        Text("Use device setting").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section("Units") {
                    Picker("Height", selection: $heightUnit) { Text("Feet").tag("ft"); Text("Meters").tag("m") }
                    Picker("Route distance", selection: $distanceUnit) { Text("Miles").tag("mi"); Text("Kilometers").tag("km") }
                    Picker("Curve length", selection: $curveLengthUnit) { Text("Meters").tag("m"); Text("Feet").tag("ft") }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
private extension Color { static let apexAcid = Color(red: 0.86, green: 1, blue: 0.32); static let apexAccent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.86, green: 1, blue: 0.32, alpha: 1) : UIColor(red: 0.26, green: 0.42, blue: 0.05, alpha: 1) }); static let apexLogoBackground = Color(uiColor: UIColor { _ in UIColor(red: 0.04, green: 0.08, blue: 0.09, alpha: 1) }); static let apexInk = Color.primary; static let apexMuted = Color.secondary; static let apexLine = Color.primary.opacity(0.14); static let apexPanel = Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(red: 0.05, green: 0.10, blue: 0.11, alpha: 1) : UIColor(red: 0.94, green: 0.94, blue: 0.90, alpha: 1) }); static let apexBlue = Color(red: 0.16, green: 0.47, blue: 0.93); static let apexRed = Color(red: 0.86, green: 0.26, blue: 0.26) }

#Preview { ContentView() }
