import SwiftUI
import ARKit
import CoreMotion
import CoreLocation
import Combine
import simd

// MARK: - MappingResult

struct MappingResult {
    let pois: [MappedPOI]
}

// MARK: - MappedPOI

struct MappedPOI: Identifiable {
    let id: UUID
    var name: String
    var icon: String
    /// Where the POI sits on the floor plan image (0–1 UV, origin top-left).
    let mapUV: CGPoint
    /// AR world position derived from mapUV × floor dimensions (for 3-D navigation nodes).
    let worldX: Float
    let worldZ: Float
    let colorIndex: Int

    init(name: String, icon: String, mapUV: CGPoint,
         worldX: Float, worldZ: Float, colorIndex: Int) {
        id = UUID()
        self.name = name; self.icon = icon
        self.mapUV = mapUV
        self.worldX = worldX; self.worldZ = worldZ
        self.colorIndex = colorIndex
    }
}

let poiUIColors: [UIColor] = [.systemBlue, .systemOrange, .systemGreen,
                               .systemRed,  .systemPurple, .systemTeal]
let poiColors:   [Color]   = [.blue, .orange, .green, .red, .purple, .teal]

let poiIconOptions = ["mappin", "person.2.fill", "door.left.hand.open",
                      "fork.knife", "toilet", "cart.fill",
                      "info.circle", "cup.and.saucer.fill"]

// MARK: - Indoor Mapper Engine

class IndoorMapper: NSObject, ObservableObject {

    @Published var isMapping        = false
    @Published var hasData          = false
    @Published var pointCount       = 0
    @Published var scannedAreaM2:   Float = 0
    @Published var currentFloor:    Float = 0
    @Published var trackingState    = "Tap Start to begin"
    @Published var pois:            [MappedPOI] = []

    @Published var hasGyro:      Bool
    @Published var hasBarometer: Bool
    let hasGPS = true

    @Published private(set) var featurePoints: [simd_float3] = []
    @Published private(set) var cameraPath:    [simd_float3] = []

    let session = ARSession()
    private let altimeter = CMAltimeter()

    override init() {
        hasGyro      = CMMotionManager().isGyroAvailable
        hasBarometer = CMAltimeter.isRelativeAltitudeAvailable()
        super.init()
        session.delegate = self
    }

    // MARK: Session control

    func startPreview() {
        trackingState = "Initializing..."
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = [.horizontal, .vertical]
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func startMapping() {
        featurePoints = []; cameraPath = []
        isMapping = true; hasData = false; pointCount = 0; scannedAreaM2 = 0
        if hasBarometer {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                if let alt = data?.relativeAltitude.floatValue { self?.currentFloor = alt }
            }
        }
    }

    func stopMapping() {
        isMapping = false
        hasData = !featurePoints.isEmpty
        altimeter.stopRelativeAltitudeUpdates()
        let xs = cameraPath.map { $0.x }, zs = cameraPath.map { $0.z }
        scannedAreaM2 = ((xs.max() ?? 0) - (xs.min() ?? 0)) *
                        ((zs.max() ?? 0) - (zs.min() ?? 0))
    }

    func pauseSession() { session.pause() }

    // MARK: POI management

    /// Adds a POI at a floor-plan UV position.
    /// World position is derived geometrically: UV (0.5, 0.5) = center = AR (0, 0).
    /// East = +X (U increases), South = +Z (V increases, since floor plan top = North).
    func addPOI(mapUV: CGPoint, name: String, icon: String,
                floorWidthM: Double, floorHeightM: Double) {
        let worldX = Float((mapUV.x - 0.5) * floorWidthM)
        let worldZ = Float((mapUV.y - 0.5) * floorHeightM)
        pois.append(MappedPOI(name: name, icon: icon, mapUV: mapUV,
                               worldX: worldX, worldZ: worldZ,
                               colorIndex: pois.count % poiUIColors.count))
    }

    func removePOI(_ id: UUID) { pois.removeAll { $0.id == id } }

    func makeMappingResult() -> MappingResult { MappingResult(pois: pois) }

    // MARK: Mini-map coordinate transform

    struct MapTransform {
        let minX, minZ, scale, offX, offZ: Double
        func canvas(worldX x: Float, worldZ z: Float) -> CGPoint {
            CGPoint(x: (Double(x) - minX) * scale + offX,
                    y: (Double(z) - minZ) * scale + offZ)
        }
    }

    func makeTransform(size: CGSize) -> MapTransform? {
        guard !cameraPath.isEmpty else { return nil }
        let allX = featurePoints.map { Double($0.x) } + cameraPath.map { Double($0.x) }
        let allZ = featurePoints.map { Double($0.z) } + cameraPath.map { Double($0.z) }
        let minX = (allX.min() ?? 0) - 0.5, maxX = (allX.max() ?? 0) + 0.5
        let minZ = (allZ.min() ?? 0) - 0.5, maxZ = (allZ.max() ?? 0) + 0.5
        let rangeX = max(maxX - minX, 0.1), rangeZ = max(maxZ - minZ, 0.1)
        let scale = min(Double(size.width) / rangeX, Double(size.height) / rangeZ)
        return MapTransform(minX: minX, minZ: minZ, scale: scale,
                            offX: (Double(size.width)  - rangeX * scale) / 2,
                            offZ: (Double(size.height) - rangeZ * scale) / 2)
    }

    // MARK: Export scanned map as image

    func renderMapImage(size: CGSize = CGSize(width: 1200, height: 1200)) -> UIImage? {
        guard hasData, !cameraPath.isEmpty, let t = makeTransform(size: size) else { return nil }
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(white: 0.96, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

            UIColor.darkGray.setFill()
            for p in featurePoints {
                let sp = t.canvas(worldX: p.x, worldZ: p.z)
                UIBezierPath(ovalIn: CGRect(x: sp.x-2, y: sp.y-2, width: 4, height: 4)).fill()
            }

            if cameraPath.count > 1 {
                let path = UIBezierPath()
                path.move(to: t.canvas(worldX: cameraPath[0].x, worldZ: cameraPath[0].z))
                for p in cameraPath.dropFirst() {
                    path.addLine(to: t.canvas(worldX: p.x, worldZ: p.z))
                }
                UIColor.systemBlue.setStroke(); path.lineWidth = 4; path.stroke()
            }

            for (i, poi) in pois.enumerated() {
                let cp = t.canvas(worldX: poi.worldX, worldZ: poi.worldZ)
                poiUIColors[i % poiUIColors.count].setFill()
                UIBezierPath(ovalIn: CGRect(x: cp.x-10, y: cp.y-10, width: 20, height: 20)).fill()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.darkGray]
                (poi.name as NSString).draw(at: CGPoint(x: cp.x+12, y: cp.y-7), withAttributes: attrs)
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension IndoorMapper: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let col3   = frame.camera.transform.columns.3
        let camPos = simd_float3(col3.x, col3.y, col3.z)

        let wallPoints = frame.rawFeaturePoints?.points.filter { p in
            let dy = p.y - camPos.y; let dx = p.x - camPos.x; let dz = p.z - camPos.z
            return dy > -1.8 && dy < 0.3 && (dx*dx + dz*dz) < 36.0
        } ?? []
        let sampled = wallPoints.enumerated().filter { $0.offset % 4 == 0 }.map { $0.element }

        let stateStr: String
        switch frame.camera.trackingState {
        case .normal:                   stateStr = "Tracking"
        case .notAvailable:             stateStr = "Not Available"
        case .limited(let reason):
            switch reason {
            case .initializing:         stateStr = "Initializing..."
            case .insufficientFeatures: stateStr = "Move slowly — need more features"
            case .excessiveMotion:      stateStr = "Slow down"
            case .relocalizing:         stateStr = "Relocalizing..."
            @unknown default:           stateStr = "Limited"
            }
        @unknown default:               stateStr = "Tracking"
        }

        Task { @MainActor [weak self] in
            guard let self, self.isMapping else { return }
            if let last = self.cameraPath.last {
                if simd_distance(camPos, last) > 0.15 { self.cameraPath.append(camPos) }
            } else {
                self.cameraPath.append(camPos)
            }
            if !sampled.isEmpty {
                self.featurePoints.append(contentsOf: sampled)
                if self.featurePoints.count > 40_000 {
                    self.featurePoints = Array(self.featurePoints.suffix(40_000))
                }
                self.pointCount = self.featurePoints.count
            }
            self.trackingState = stateStr
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.trackingState = "Sensor error" }
    }
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.trackingState = "Interrupted" }
    }
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.trackingState = "Resuming..." }
    }
}

// MARK: - AR Camera Feed

struct ARCameraView: UIViewRepresentable {
    let mapper: IndoorMapper
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(); v.session = mapper.session
        v.automaticallyUpdatesLighting = false; v.showsStatistics = false; return v
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Mini-map canvas (feature points + path, shown while scanning)

struct MapCanvas: View {
    @ObservedObject var mapper: IndoorMapper

    var body: some View {
        Canvas { ctx, size in
            guard !mapper.cameraPath.isEmpty,
                  let t = mapper.makeTransform(size: size) else { return }

            for p in mapper.featurePoints {
                let sp = t.canvas(worldX: p.x, worldZ: p.z)
                ctx.fill(Path(ellipseIn: CGRect(x: sp.x-1.5, y: sp.y-1.5, width: 3, height: 3)),
                         with: .color(.gray.opacity(0.55)))
            }
            if mapper.cameraPath.count > 1 {
                var shape = Path()
                shape.move(to: t.canvas(worldX: mapper.cameraPath[0].x, worldZ: mapper.cameraPath[0].z))
                for p in mapper.cameraPath.dropFirst() {
                    shape.addLine(to: t.canvas(worldX: p.x, worldZ: p.z))
                }
                ctx.stroke(shape, with: .color(.blue), lineWidth: 1.5)
            }
            if let last = mapper.cameraPath.last {
                let lp = t.canvas(worldX: last.x, worldZ: last.z)
                ctx.fill(Path(ellipseIn: CGRect(x: lp.x-5, y: lp.y-5, width: 10, height: 10)),
                         with: .color(.red))
            }
        }
    }
}

// MARK: - Floor plan POI canvas
// The user's uploaded floor plan shown full-screen so they can tap to place POIs.

struct FloorPlanPOICanvas: View {
    let floorPlanImage: UIImage
    let pois: [MappedPOI]          // value type — no reactive observation, no AR-frame re-renders
    var onTap: ((CGPoint) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Image(uiImage: floorPlanImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: w, height: h)
                    .clipped()

                // POI pins — only re-render when the pois array itself changes
                ForEach(pois) { poi in
                    POIPin(poi: poi)
                        .position(x: poi.mapUV.x * w, y: poi.mapUV.y * h)
                        .allowsHitTesting(false)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { val in
                            let uv = CGPoint(x: val.location.x / w, y: val.location.y / h)
                            onTap?(uv)
                        }
                    )
            }
        }
    }
}

// Small coloured pin shown on the floor plan canvas
struct POIPin: View {
    let poi: MappedPOI
    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Circle().fill(poiColors[poi.colorIndex]).frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                Image(systemName: poi.icon).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
            }
            Text(poi.name).font(.system(size: 9, weight: .semibold)).foregroundColor(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.black.opacity(0.55)).clipShape(Capsule())
        }
    }
}

// MARK: - Supporting UI

struct SensorBadge: View {
    let icon: String; let label: String; let active: Bool
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 13))
            Text(label).font(.system(size: 8, weight: .semibold))
        }
        .foregroundColor(active ? .green : Color.white.opacity(0.35))
        .frame(width: 44, height: 38).background(Color.black.opacity(0.55)).cornerRadius(8)
    }
}

struct MappingStatChip: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold())
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06)).cornerRadius(10)
    }
}

struct MappingRoundedCorner: Shape {
    var radius: CGFloat; var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

extension View {
    func mappingCornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(MappingRoundedCorner(radius: radius, corners: corners))
    }
    func actionButtonStyle(color: Color) -> some View {
        self.font(.headline).foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(color).cornerRadius(14)
    }
}

// MARK: - POI name entry sheet

private struct AddPOISheet: View {
    let onAdd: (String, String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var selectedIcon = "mappin"
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                TextField("e.g. Exit B, Lab 203, Cafeteria", text: $name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .submitLabel(.done).padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Icon").font(.subheadline).foregroundColor(.secondary).padding(.horizontal)
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 12) {
                        ForEach(poiIconOptions, id: \.self) { icon in
                            Button { selectedIcon = icon } label: {
                                Image(systemName: icon).font(.title3)
                                    .foregroundColor(selectedIcon == icon ? .white : .primary)
                                    .frame(width: 52, height: 52)
                                    .background(selectedIcon == icon ? Color.blue : Color.primary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Name this Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let t = name.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        onAdd(t, selectedIcon)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).bold()
                }
            }
        }
        .onAppear { nameFocused = true }
    }
}

// MARK: - Main Mapping View

struct MappingView: View {
    /// The floor plan image the user uploaded and aligned on the main map.
    var floorPlanImage: UIImage
    var floorWidthMeters:  Double = 30
    var floorHeightMeters: Double = 20
    var onComplete: ((MappingResult) -> Void)? = nil

    @StateObject private var mapper = IndoorMapper()

    // Whether the optional AR scanning mode is open
    @State private var showScanView = false
    // UV of the last tap on the floor plan, pending name entry
    @State private var pendingUV: CGPoint? = nil
    @State private var showPOISheet = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if showScanView {
                scanModeView
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                floorPlanModeView
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showScanView)
        .sheet(isPresented: $showPOISheet) {
            AddPOISheet { name, icon in
                if let uv = pendingUV {
                    mapper.addPOI(mapUV: uv, name: name, icon: icon,
                                  floorWidthM: floorWidthMeters,
                                  floorHeightM: floorHeightMeters)
                }
                showPOISheet = false; pendingUV = nil
            } onCancel: {
                showPOISheet = false; pendingUV = nil
            }
            .presentationDetents([.medium])
        }
        .onDisappear { mapper.pauseSession() }
    }

    // MARK: - Floor plan mode (default experience)

    private var floorPlanModeView: some View {
        ZStack {
            // Full-screen floor plan background (tappable)
            FloorPlanPOICanvas(floorPlanImage: floorPlanImage, pois: mapper.pois) { uv in
                pendingUV = uv
                showPOISheet = true
            }
            .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {

                // ── Top bar ──────────────────────────────────────────────────
                HStack {
                    Button { onComplete?(mapper.makeMappingResult()); mapper.pauseSession(); dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 32))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("Mark Locations").font(.subheadline.bold()).foregroundColor(.white)
                        Text("on your floor plan").font(.caption2).foregroundColor(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.45)).clipShape(Capsule())
                    Spacer()
                    Color.clear.frame(width: 32, height: 32)
                }
                .padding(.horizontal, 16).padding(.top, 12)

                // ── Instruction pill ─────────────────────────────────────────
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                    Text(mapper.pois.isEmpty
                         ? "Tap your floor plan to add a navigation point"
                         : "Tap to add more, or press Done below")
                }
                .font(.caption.bold()).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color.indigo.opacity(0.92)).clipShape(Capsule())
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .padding(.top, 10)

                Spacer()

                // ── Bottom panel ─────────────────────────────────────────────
                VStack(spacing: 14) {

                    // Scrollable list of added locations
                    if !mapper.pois.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(mapper.pois) { poi in
                                    HStack(spacing: 6) {
                                        Image(systemName: poi.icon)
                                            .font(.caption.bold()).foregroundColor(.white)
                                            .frame(width: 26, height: 26)
                                            .background(poiColors[poi.colorIndex]).clipShape(Circle())
                                        Text(poi.name).font(.caption.bold()).lineLimit(1)
                                        Button { mapper.removePOI(poi.id) } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.08)).clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    } else {
                        // Placeholder hint when no POIs yet
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundColor(.secondary)
                            Text("Your locations will appear here")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }

                    Divider()

                    // Optional AR scan button — session starts only here, not on view appear
                    Button {
                        mapper.startPreview()   // boot ARKit now, not on view appear
                        mapper.startMapping()
                        withAnimation { showScanView = true }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "camera.viewfinder")
                                .foregroundColor(.secondary)
                            Text("Optional: Walk & Scan with AR Camera")
                                .foregroundColor(.secondary)
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.primary.opacity(0.05)).cornerRadius(12)
                    }

                    // Main action button
                    Button {
                        onComplete?(mapper.makeMappingResult())
                        mapper.pauseSession(); dismiss()
                    } label: {
                        Label(
                            mapper.pois.isEmpty
                                ? "Done — No Locations Added"
                                : "Use \(mapper.pois.count) Location\(mapper.pois.count == 1 ? "" : "s") for AR Navigation",
                            systemImage: mapper.pois.isEmpty ? "checkmark" : "arkit"
                        )
                        .actionButtonStyle(color: mapper.pois.isEmpty ? .gray : .green)
                    }
                }
                .padding(20).background(.ultraThinMaterial)
                .mappingCornerRadius(24, corners: [.topLeft, .topRight])
            }
        }
    }

    // MARK: - AR Scan mode (optional — reached from the button above)

    private var scanModeView: some View {
        ZStack {
            ARCameraView(mapper: mapper).edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {

                // ── Top bar ──────────────────────────────────────────────────
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        mapper.stopMapping()
                        mapper.pauseSession()   // stop AR frames while on floor plan screen
                        withAnimation { showScanView = false }
                    } label: {
                        Image(systemName: "chevron.left.circle.fill").font(.system(size: 32))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        SensorBadge(icon: "camera.fill",   label: "Camera", active: true)
                        SensorBadge(icon: "gyroscope",     label: "IMU",    active: mapper.hasGyro)
                        SensorBadge(icon: "barometer",     label: "Baro",   active: mapper.hasBarometer)
                        SensorBadge(icon: "location.fill", label: "GPS",    active: mapper.hasGPS)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12)

                Text(mapper.trackingState)
                    .font(.caption.bold()).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(trackingPillColor.opacity(0.9)).clipShape(Capsule())
                    .padding(.top, 8)

                Spacer()

                // Mini-map (bottom-right corner)
                HStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.75))
                        if mapper.cameraPath.isEmpty {
                            VStack(spacing: 4) {
                                Image(systemName: "figure.walk").foregroundColor(.gray).font(.title3)
                                Text("Walk to build map").font(.caption2).foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(8)
                        } else {
                            MapCanvas(mapper: mapper).padding(6)
                        }
                    }
                    .frame(width: 158, height: 158)
                    .padding(.trailing, 16).padding(.bottom, 12)
                }

                // ── Scan panel ───────────────────────────────────────────────
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        MappingStatChip(label: "Points",  value: "\(mapper.pointCount)")
                        MappingStatChip(label: "Area",    value: String(format: "%.0f m²", mapper.scannedAreaM2))
                        if mapper.hasBarometer {
                            MappingStatChip(label: "Floor Δ",
                                            value: String(format: "%.1f m", mapper.currentFloor))
                        }
                    }

                    Text("Walk through every room so the camera can capture the space.")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)

                    Button {
                        mapper.stopMapping()
                        mapper.pauseSession()   // stop AR frames while on floor plan screen
                        withAnimation { showScanView = false }
                    } label: {
                        Label("Finish Scanning — Back to Floor Plan",
                              systemImage: "checkmark.circle.fill")
                        .actionButtonStyle(color: .indigo)
                    }
                }
                .padding(20).background(.ultraThinMaterial)
                .mappingCornerRadius(24, corners: [.topLeft, .topRight])
            }
        }
    }

    // MARK: Helpers

    private var trackingPillColor: Color {
        switch mapper.trackingState {
        case "Tracking": return .green
        case "Initializing...": return .orange
        default: return .red
        }
    }
}
