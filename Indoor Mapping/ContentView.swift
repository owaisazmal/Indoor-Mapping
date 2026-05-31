import SwiftUI
import MapKit
import PhotosUI

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var floorPlan       = FloorPlanState()
    @StateObject private var locationManager = LocationManager()

    @State private var currentMapCenter      = CLLocationCoordinate2D(latitude: 37.334800, longitude: -122.009000)
    @State private var trackingMode: MKUserTrackingMode = .none
    @State private var activeRoute:          MKPolyline?
    @State private var selectedDestination:  String?
    @State private var showBuildingBoundary  = false
    /// Navigation graph loaded from bundle (optional — features degrade gracefully when nil).
    @State private var navGraph:             NavGraph? = NavGraphFactory.load(named: "building_1")
    /// UV-space path from the last A* query.  Drives the floor-plan polyline.
    @State private var pathUVs:              [CGPoint] = []
    @State private var showingDirectionsSheet = false
    @State private var showingMappingView    = false
    @State private var showingARNav          = false
    @State private var mappingResult:        MappingResult?
    @State private var selectedPhoto:     PhotosPickerItem?
    @State private var currentMapSpan   = MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
    /// true  → 2-finger gestures adjust the floor-plan image
    /// false → normal map interaction; use crosshair + Snap to position
    @State private var alignIsAdjusting = true

    var body: some View {
        ZStack(alignment: .top) {

            // 1. MAP LAYER
            IndoorMapView(
                floorPlanImage:         floorPlan.image,
                overlayCenter:          floorPlan.center,
                overlayWidthMeters:     floorPlan.widthMeters,
                overlayHeightMeters:    floorPlan.heightMeters,
                overlayRotationDegrees: floorPlan.rotationDegrees,
                overlayAlpha:           floorPlan.alpha,
                route:                  pathUVs.isEmpty ? activeRoute : nil,
                userLocation:           locationManager.userLocation,
                userHeading:            locationManager.userHeading,
                showBuildingBoundary:   showBuildingBoundary,
                isEditing:              floorPlan.isEditing && alignIsAdjusting,
                navGraph:               navGraph,
                pathUVs:                pathUVs,
                userUV:                 locationManager.userLocation.map { locationToUV($0) },
                onTapDestination:       { node in handleTapDestination(node) },
                onMoveFloorPlan:        { lat, lon in floorPlan.moveCenter(latDelta: lat, lonDelta: lon) },
                onScaleFloorPlan:       { factor in floorPlan.applyScale(factor) },
                onRotateFloorPlan:      { delta in floorPlan.applyRotation(deltaDegrees: delta) },
                trackingMode:           $trackingMode,
                currentMapCenter:       $currentMapCenter,
                currentMapSpan:         $currentMapSpan
            )
            .edgesIgnoringSafeArea(.all)

            // 2. CROSSHAIR — visible in Move Map mode to show where Snap will land
            if floorPlan.isEditing && !alignIsAdjusting {
                CrosshairOverlay()
            }

            // 3. ADAPTIVE UI
            VStack(spacing: 0) {
                if floorPlan.isEditing {
                    VStack(spacing: 6) {
                        Text(alignIsAdjusting ? "Adjusting Image" : "Move Map")
                            .font(.subheadline).bold()
                        if alignIsAdjusting {
                            HStack(spacing: 14) {
                                Label("Drag",   systemImage: "hand.draw.fill")
                                Label("Pinch",  systemImage: "arrow.up.left.and.arrow.down.right")
                                Label("Rotate", systemImage: "rotate.right")
                            }
                            .font(.caption).foregroundColor(.secondary)
                        } else {
                            Text("Pan to your building, then tap Snap")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 10).padding(.horizontal, 20)
                    .background(.regularMaterial).clipShape(Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    MapSearchBar(selectedPhoto: $selectedPhoto,
                                 isLoading: floorPlan.isLoadingImage)
                }

                Spacer()

                if floorPlan.isEditing {
                    AlignmentEditorView(
                        floorPlan:        floorPlan,
                        isAdjusting:      $alignIsAdjusting,
                        currentMapCenter: currentMapCenter
                    ) {
                        alignIsAdjusting = true
                        floorPlan.finishEditing()
                        locationManager.buildingBounds = BuildingBounds(
                            center:          floorPlan.center,
                            widthMeters:     floorPlan.widthMeters,
                            heightMeters:    floorPlan.heightMeters,
                            rotationDegrees: floorPlan.rotationDegrees
                        )
                        showBuildingBoundary = true
                    }
                } else {
                    MapControlsView(
                        trackingMode:         $trackingMode,
                        showBuildingBoundary: $showBuildingBoundary,
                        hasBuildingBounds:    locationManager.buildingBounds != nil,
                        hasCustomImage:       floorPlan.hasCustomImage,
                        onScan:               { showingMappingView = true },
                        onARNav:              { showingARNav = true },
                        onDirections:         { showingDirectionsSheet = true }
                    )

                    if !floorPlan.hasCustomImage {
                        UploadPromptCard(selectedPhoto: $selectedPhoto,
                                         isLoading: floorPlan.isLoadingImage)
                    } else if let destination = selectedDestination {
                        RouteCardView(destination: destination) {
                            withAnimation(.spring()) {
                                activeRoute         = nil
                                pathUVs             = []
                                selectedDestination = nil
                            }
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: floorPlan.isEditing)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: floorPlan.hasCustomImage)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selectedDestination != nil)
        .onChange(of: selectedPhoto) { newItem in
            guard newItem != nil else { return }
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    floorPlan.load(image, anchoredAt: currentMapCenter)
                }
            }
        }
        .sheet(isPresented: $showingDirectionsSheet) {
            DirectionsSheet { destination, route in
                withAnimation(.spring()) {
                    selectedDestination = destination
                    activeRoute = route
                    showingDirectionsSheet = false
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showingMappingView) {
            MappingView(
                floorPlanImage:    floorPlan.image,
                floorWidthMeters:  floorPlan.widthMeters,
                floorHeightMeters: floorPlan.heightMeters
            ) { result in mappingResult = result }
        }
        .fullScreenCover(isPresented: $showingARNav) {
            ARNavigationView(
                floorPlanImage:    floorPlan.image,
                mappingResult:     mappingResult,
                floorWidthMeters:  floorPlan.widthMeters,
                floorHeightMeters: floorPlan.heightMeters
            )
        }
        .onAppear { locationManager.requestPermission() }
    }
}

// MARK: - Search bar (re-upload from here anytime)

private struct MapSearchBar: View {
    @Binding var selectedPhoto: PhotosPickerItem?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.title3).foregroundColor(.secondary)
            Text("Search building...").foregroundColor(.secondary)
            Spacer()

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.blue)
                    .padding(8)
            } else {
                PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3).foregroundColor(.blue)
                        .padding(8).background(Color.blue.opacity(0.1)).clipShape(Circle())
                }
            }

            Button(action: {}) {
                Image(systemName: "mic.fill")
                    .font(.title3).foregroundColor(.secondary)
                    .padding(8).background(Color.secondary.opacity(0.1)).clipShape(Circle())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial).clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        .padding(.horizontal).padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Upload prompt (shown until a floor plan is loaded)

private struct UploadPromptCard: View {
    @Binding var selectedPhoto: PhotosPickerItem?
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 16) {
            if isLoading {
                HStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.indigo)
                        .scaleEffect(1.2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Loading floor plan…")
                            .font(.subheadline.bold())
                        Text("This will only take a moment")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 16) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.indigo)
                        .frame(width: 52, height: 52)
                        .background(Color.indigo.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add a floor plan")
                            .font(.headline)
                        Text("Upload a building map to unlock scanning and AR navigation")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                PhotosPicker(selection: $selectedPhoto,
                             matching: .images,
                             photoLibrary: .shared()) {
                    Label("Choose from Photos", systemImage: "square.and.arrow.up")
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.indigo).cornerRadius(14)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial)
        .cornerRadius(24)
        .shadow(color: .black.opacity(0.15), radius: 15, x: 0, y: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Crosshair

private struct CrosshairOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Image(systemName: "plus.viewfinder")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundColor(.blue)
                .background(Circle().fill(Color.white.opacity(0.5)).frame(width: 30, height: 30))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .allowsHitTesting(false)
        }
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Alignment editor

private struct AlignmentEditorView: View {
    @ObservedObject var floorPlan: FloorPlanState
    @Binding var isAdjusting: Bool
    let currentMapCenter: CLLocationCoordinate2D
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 14) {

            // Mode toggle
            HStack(spacing: 0) {
                modeButton(title: "Adjust Image", icon: "hand.draw.fill",   active: isAdjusting)  { isAdjusting = true  }
                modeButton(title: "Move Map",     icon: "map",               active: !isAdjusting) { isAdjusting = false }
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if !isAdjusting {
                Button { floorPlan.snap(to: currentMapCenter) } label: {
                    Label("Snap Image to Crosshair", systemImage: "scope")
                        .font(.subheadline).foregroundColor(.blue)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.blue.opacity(0.1)).cornerRadius(12)
                }
            }

            Button(action: onSave) {
                Text("Save Alignment")
                    .font(.headline).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.green).cornerRadius(14)
            }
        }
        .padding(20).background(.regularMaterial).cornerRadius(24)
        .shadow(color: .black.opacity(0.15), radius: 15, x: 0, y: 10)
        .padding(.horizontal, 16).padding(.bottom, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private func modeButton(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(active ? .semibold : .regular))
            .foregroundColor(active ? .white : .secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(active ? Color.indigo : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Map controls

private struct MapControlsView: View {
    @Binding var trackingMode: MKUserTrackingMode
    @Binding var showBuildingBoundary: Bool
    let hasBuildingBounds: Bool
    let hasCustomImage: Bool
    var onScan:       () -> Void
    var onARNav:      () -> Void
    var onDirections: () -> Void

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer()
            VStack(spacing: 12) {

                // Location tracking — always available
                Button { cycleTracking() } label: {
                    Image(systemName: trackingIcon)
                        .font(.system(size: 20))
                        .foregroundColor(trackingMode == .none ? .secondary : .blue)
                        .frame(width: 54, height: 54)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                }

                // These buttons only make sense after a floor plan is loaded
                if hasCustomImage {
                    if hasBuildingBounds {
                        Button { showBuildingBoundary.toggle() } label: {
                            Image(systemName: showBuildingBoundary ? "building.2.fill" : "building.2")
                                .font(.system(size: 20))
                                .foregroundColor(showBuildingBoundary ? .white : .secondary)
                                .frame(width: 54, height: 54)
                                .background(showBuildingBoundary
                                    ? Color.indigo
                                    : Color(UIColor.systemBackground).opacity(0.9))
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                        }
                    }

                    FloatingActionButton(icon: "cube.transparent", color: .indigo, action: onScan)
                    FloatingActionButton(icon: "arkit",            color: .orange, action: onARNav)
                    FloatingActionButton(
                        icon: "arrow.triangle.turn.up.right.diamond.fill",
                        color: .blue,
                        action: onDirections
                    )
                }
            }
            .padding(.trailing, 16)
            // Tighter bottom padding when the upload card sits below
            .padding(.bottom, hasCustomImage ? 30 : 12)
        }
        .transition(.opacity)
    }

    private func cycleTracking() {
        switch trackingMode {
        case .none:   trackingMode = .follow
        case .follow: trackingMode = .followWithHeading
        default:      trackingMode = .follow
        }
    }

    private var trackingIcon: String {
        switch trackingMode {
        case .followWithHeading: return "location.north.line.fill"
        case .follow:            return "location.fill"
        default:                 return "location"
        }
    }
}

private struct FloatingActionButton: View {
    let icon:   String
    let color:  Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20)).foregroundColor(.white)
                .frame(width: 54, height: 54)
                .background(color).clipShape(Circle())
                .shadow(color: color.opacity(0.35), radius: 8, x: 0, y: 4)
        }
    }
}

// MARK: - Active route card

private struct RouteCardView: View {
    let destination: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Navigating to")
                        .font(.caption).foregroundColor(.secondary).textCase(.uppercase)
                    Text(destination).font(.headline)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.title)
                }
            }
            Divider()
            HStack {
                Image(systemName: "figure.walk").foregroundColor(.blue)
                Text("2 mins").bold().foregroundColor(.blue)
                Text("• 150 ft").foregroundColor(.secondary)
            }
            .font(.subheadline)
        }
        .padding(20).background(.regularMaterial).cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: -5)
        .padding(.horizontal, 16).padding(.bottom, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Directions sheet

struct DirectionsSheet: View {
    var onSelectDestination: (String, MKPolyline) -> Void

    private let destinations = ["Conference Room A", "Cafeteria", "Restrooms", "Exit"]

    var body: some View {
        NavigationView {
            List(destinations, id: \.self) { destination in
                Button { makeMockRoute(for: destination) } label: {
                    HStack {
                        Image(systemName: "mappin.and.ellipse").foregroundColor(.blue)
                        Text(destination).foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle("Get Directions")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func makeMockRoute(for destination: String) {
        var coords = [
            CLLocationCoordinate2D(latitude: 37.334000, longitude: -122.008000),
            CLLocationCoordinate2D(latitude: 37.334200, longitude: -122.008200),
            CLLocationCoordinate2D(latitude: 37.334500, longitude: -122.008500),
            CLLocationCoordinate2D(latitude: 37.334700, longitude: -122.008100)
        ]
        onSelectDestination(destination, MKPolyline(coordinates: &coords, count: coords.count))
    }
}

// MARK: - Tap-to-navigate helpers (ContentView extension)

extension ContentView {

    /// Converts a GPS fix to a UV position on the current floor plan.
    /// Uses the same rotation convention as IndoorMapOverlayRenderer.
    func locationToUV(_ location: CLLocation) -> CGPoint {
        let center  = floorPlan.center
        let mPerLat = 111_000.0
        let mPerLon = 111_000.0 * cos(center.latitude * .pi / 180)

        let northM  = (location.coordinate.latitude  - center.latitude)  * mPerLat
        let eastM   = (location.coordinate.longitude - center.longitude) * mPerLon

        let a  = floorPlan.rotationDegrees * .pi / 180.0
        let ca = cos(a), sa = sin(a)

        // Inverse rotation: R(a)⁻¹ = R(a)ᵀ
        let lx = eastM * ca - northM * sa
        let ly = eastM * sa + northM * ca

        return CGPoint(x: 0.5 + lx / floorPlan.widthMeters,
                       y: 0.5 - ly / floorPlan.heightMeters)
    }

    /// Called when the user taps a location on the 2D floor plan.
    /// Runs A* from the current GPS position to the tapped node and updates
    /// `pathUVs` so the map view renders the Google Maps–style route.
    func handleTapDestination(_ node: NavNode) {
        // Start UV: GPS-derived if available, else centre of floor plan
        let startUV = locationManager.userLocation.map { locationToUV($0) }
            ?? CGPoint(x: 0.5, y: 0.5)

        var newPath: [CGPoint]
        if let graph  = navGraph,
           let result = NavPathfinder(graph: graph).findPath(from: startUV, to: node) {
            newPath = result.uvPath
        } else {
            // No graph or no path found: draw a straight line
            newPath = [startUV, node.uv]
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            pathUVs            = newPath
            selectedDestination = node.name
            activeRoute        = nil   // suppress legacy route while UV path is active
        }
    }
}

#Preview {
    ContentView()
}
