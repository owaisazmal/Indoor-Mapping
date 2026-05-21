import SwiftUI
import ARKit
import CoreMotion
import CoreLocation
import Combine
import simd

// MARK: - Indoor Mapper Engine

class IndoorMapper: NSObject, ObservableObject {

    // Published state
    @Published var isMapping = false
    @Published var hasData = false
    @Published var pointCount = 0
    @Published var scannedAreaM2: Float = 0
    @Published var currentFloor: Float = 0
    @Published var trackingState = "Tap Start to begin"

    // Sensor availability
    @Published var hasGyro: Bool
    @Published var hasBarometer: Bool
    @Published var hasGPS: Bool

    // Map data (ARKit world frame, Y-up)
    @Published private(set) var featurePoints: [simd_float3] = []
    @Published private(set) var cameraPath: [simd_float3] = []

    let session = ARSession()
    private let altimeter = CMAltimeter()

    override init() {
        hasGyro = CMMotionManager().isGyroAvailable
        hasBarometer = CMAltimeter.isRelativeAltitudeAvailable()
        hasGPS = CLLocationManager.locationServicesEnabled()
        super.init()
        session.delegate = self
    }

    /// Starts the AR session so the camera preview shows immediately and the
    /// system permission dialog fires on first launch. Call this from onAppear.
    func startPreview() {
        trackingState = "Initializing..."
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = [.horizontal, .vertical]
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Begins recording feature points and path. Session must already be running.
    func startMapping() {
        featurePoints = []
        cameraPath = []
        isMapping = true
        hasData = false
        pointCount = 0
        scannedAreaM2 = 0

        if hasBarometer {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                if let alt = data?.relativeAltitude.floatValue {
                    self?.currentFloor = alt
                }
            }
        }
    }

    func stopMapping() {
        isMapping = false
        hasData = !featurePoints.isEmpty
        altimeter.stopRelativeAltitudeUpdates()
        computeStats()
        // Session stays running so the user still sees the camera preview.
    }

    func pauseSession() {
        session.pause()
    }

    private func computeStats() {
        guard cameraPath.count > 1 else { return }
        let xs = cameraPath.map { $0.x }
        let zs = cameraPath.map { $0.z }
        let w = (xs.max() ?? 0) - (xs.min() ?? 0)
        let h = (zs.max() ?? 0) - (zs.min() ?? 0)
        scannedAreaM2 = w * h
    }

    /// Renders the collected map data into a UIImage floor plan.
    func renderMapImage(size: CGSize = CGSize(width: 1200, height: 1200)) -> UIImage? {
        guard hasData, !cameraPath.isEmpty else { return nil }

        let allX = featurePoints.map { CGFloat($0.x) } + cameraPath.map { CGFloat($0.x) }
        let allZ = featurePoints.map { CGFloat($0.z) } + cameraPath.map { CGFloat($0.z) }

        let minX = (allX.min() ?? 0) - 1
        let maxX = (allX.max() ?? 0) + 1
        let minZ = (allZ.min() ?? 0) - 1
        let maxZ = (allZ.max() ?? 0) + 1

        let rangeX = max(maxX - minX, 0.1)
        let rangeZ = max(maxZ - minZ, 0.1)
        let scale = min(size.width / rangeX, size.height / rangeZ)
        let offX = (size.width - rangeX * scale) / 2
        let offZ = (size.height - rangeZ * scale) / 2

        func toScreen(_ p: simd_float3) -> CGPoint {
            CGPoint(x: (CGFloat(p.x) - minX) * scale + offX,
                    y: (CGFloat(p.z) - minZ) * scale + offZ)
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let c = ctx.cgContext

            // Background
            UIColor(white: 0.96, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))

            // Feature points — walls / obstacles
            UIColor.darkGray.setFill()
            for p in featurePoints {
                let sp = toScreen(p)
                c.fillEllipse(in: CGRect(x: sp.x - 2, y: sp.y - 2, width: 4, height: 4))
            }

            // Walked path
            if cameraPath.count > 1 {
                let pathBezier = UIBezierPath()
                pathBezier.move(to: toScreen(cameraPath[0]))
                for p in cameraPath.dropFirst() { pathBezier.addLine(to: toScreen(p)) }
                UIColor.systemBlue.setStroke()
                pathBezier.lineWidth = 4
                pathBezier.stroke()
            }

            // Start marker (green)
            if let s = cameraPath.first {
                UIColor.systemGreen.setFill()
                let sp = toScreen(s)
                c.fillEllipse(in: CGRect(x: sp.x - 8, y: sp.y - 8, width: 16, height: 16))
            }

            // End marker (red)
            if let e = cameraPath.last {
                UIColor.systemRed.setFill()
                let ep = toScreen(e)
                c.fillEllipse(in: CGRect(x: ep.x - 8, y: ep.y - 8, width: 16, height: 16))
            }

            // North arrow (top-right corner)
            let arrowOrigin = CGPoint(x: size.width - 50, y: 50)
            let arrowAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 12),
                .foregroundColor: UIColor.systemBlue
            ]
            ("N" as NSString).draw(at: CGPoint(x: arrowOrigin.x - 4, y: arrowOrigin.y - 20), withAttributes: arrowAttrs)
            UIColor.systemBlue.setStroke()
            c.setLineWidth(2)
            c.move(to: arrowOrigin)
            c.addLine(to: CGPoint(x: arrowOrigin.x, y: arrowOrigin.y - 16))
            c.strokePath()
        }
    }
}

// MARK: - ARSessionDelegate
// All callbacks are nonisolated because ARKit delivers them on a background thread.
// The project uses SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so without nonisolated
// these methods would be @MainActor-isolated, causing a thread-safety crash.

extension IndoorMapper: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Heavy computation stays on ARKit's background thread — no actor state touched here.
        let col3 = frame.camera.transform.columns.3
        let camPos = simd_float3(col3.x, col3.y, col3.z)

        // Wall-band filter: points within 6 m horizontally, between -1.8 m and +0.3 m
        // relative to the camera — captures walls and obstacles while skipping floor/ceiling.
        let wallPoints = frame.rawFeaturePoints?.points.filter { p in
            let dy = p.y - camPos.y
            let dx = p.x - camPos.x
            let dz = p.z - camPos.z
            return dy > -1.8 && dy < 0.3 && (dx*dx + dz*dz) < 36.0
        } ?? []

        let sampled = wallPoints.enumerated()
            .filter { $0.offset % 4 == 0 }
            .map { $0.element }

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

        // Hop to the main actor only for @Published property writes.
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
        let view = ARSCNView()
        view.session = mapper.session
        view.automaticallyUpdatesLighting = false
        view.showsStatistics = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Live 2D Map Canvas

struct MapCanvas: View {
    @ObservedObject var mapper: IndoorMapper

    var body: some View {
        Canvas { ctx, size in
            guard !mapper.cameraPath.isEmpty else { return }

            let allX = mapper.featurePoints.map { CGFloat($0.x) }
                     + mapper.cameraPath.map { CGFloat($0.x) }
            let allZ = mapper.featurePoints.map { CGFloat($0.z) }
                     + mapper.cameraPath.map { CGFloat($0.z) }

            let minX = (allX.min() ?? 0) - 0.5
            let maxX = (allX.max() ?? 0) + 0.5
            let minZ = (allZ.min() ?? 0) - 0.5
            let maxZ = (allZ.max() ?? 0) + 0.5
            let rangeX = max(maxX - minX, 0.1)
            let rangeZ = max(maxZ - minZ, 0.1)
            let scale = min(size.width / rangeX, size.height / rangeZ)
            let offX = (size.width - rangeX * scale) / 2
            let offZ = (size.height - rangeZ * scale) / 2

            func pt(_ p: simd_float3) -> CGPoint {
                CGPoint(x: (CGFloat(p.x) - minX) * scale + offX,
                        y: (CGFloat(p.z) - minZ) * scale + offZ)
            }

            // Feature points
            for p in mapper.featurePoints {
                let sp = pt(p)
                ctx.fill(Path(ellipseIn: CGRect(x: sp.x-1, y: sp.y-1, width: 2, height: 2)),
                         with: .color(.gray.opacity(0.6)))
            }

            // Walked path
            if mapper.cameraPath.count > 1 {
                var shape = Path()
                shape.move(to: pt(mapper.cameraPath[0]))
                for p in mapper.cameraPath.dropFirst() { shape.addLine(to: pt(p)) }
                ctx.stroke(shape, with: .color(.blue), lineWidth: 1.5)
            }

            // Current position dot
            if let last = mapper.cameraPath.last {
                let lp = pt(last)
                ctx.fill(Path(ellipseIn: CGRect(x: lp.x-4, y: lp.y-4, width: 8, height: 8)),
                         with: .color(.red))
            }
        }
    }
}

// MARK: - Sensor Badge

struct SensorBadge: View {
    let icon: String
    let label: String
    let active: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(label)
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundColor(active ? .green : Color.white.opacity(0.35))
        .frame(width: 44, height: 38)
        .background(Color.black.opacity(0.55))
        .cornerRadius(8)
    }
}

// MARK: - Stat Chip

struct MappingStatChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold())
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(10)
    }
}

// MARK: - Rounded Corner Helper

struct MappingRoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let bp = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                              cornerRadii: CGSize(width: radius, height: radius))
        return Path(bp.cgPath)
    }
}

extension View {
    func mappingCornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(MappingRoundedCorner(radius: radius, corners: corners))
    }
}

// MARK: - Main Mapping View

struct MappingView: View {
    @StateObject private var mapper = IndoorMapper()
    @State private var showExitAlert = false
    @State private var showSavedAlert = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Live camera feed (ARKit)
            ARCameraView(mapper: mapper)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {

                // ---- TOP BAR ----
                HStack(alignment: .top, spacing: 12) {
                    Button(action: {
                        if mapper.isMapping || mapper.hasData { showExitAlert = true }
                        else { dismiss() }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.5))
                    }

                    Spacer()

                    // Active sensor indicators
                    HStack(spacing: 6) {
                        SensorBadge(icon: "camera.fill",    label: "Camera", active: true)
                        SensorBadge(icon: "gyroscope",      label: "IMU",    active: mapper.hasGyro)
                        SensorBadge(icon: "barometer",      label: "Baro",   active: mapper.hasBarometer)
                        SensorBadge(icon: "location.fill",  label: "GPS",    active: mapper.hasGPS)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Tracking state pill
                Text(mapper.trackingState)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(trackingPillColor.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.top, 8)

                Spacer()

                // ---- MINI MAP (bottom-right) ----
                HStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.75))

                        if mapper.cameraPath.isEmpty {
                            VStack(spacing: 4) {
                                Image(systemName: "map")
                                    .foregroundColor(.gray)
                                    .font(.title3)
                                Text("Walk to map")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        } else {
                            MapCanvas(mapper: mapper).padding(6)
                        }
                    }
                    .frame(width: 158, height: 158)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                }

                // ---- BOTTOM PANEL ----
                VStack(spacing: 14) {

                    // Stats row
                    HStack(spacing: 12) {
                        MappingStatChip(label: "Points", value: "\(mapper.pointCount)")
                        MappingStatChip(label: "Area",   value: String(format: "%.0f m²", mapper.scannedAreaM2))
                        if mapper.hasBarometer {
                            MappingStatChip(label: "Floor Δ", value: String(format: "%.1f m", mapper.currentFloor))
                        }
                    }

                    // Action button(s)
                    if mapper.isMapping {
                        Button(action: { mapper.stopMapping() }) {
                            Label("Finish Mapping", systemImage: "stop.circle.fill")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red)
                                .cornerRadius(14)
                        }
                    } else if mapper.hasData {
                        HStack(spacing: 12) {
                            Button(action: { mapper.startMapping() }) {
                                Label("Re-scan", systemImage: "arrow.clockwise")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(.regularMaterial)
                                    .cornerRadius(14)
                            }
                            Button(action: { saveMap() }) {
                                Label("Save Map", systemImage: "square.and.arrow.down")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.green)
                                    .cornerRadius(14)
                            }
                        }
                    } else {
                        Button(action: { mapper.startMapping() }) {
                            Label("Start Mapping", systemImage: "record.circle")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.indigo)
                                .cornerRadius(14)
                        }
                    }
                }
                .padding(20)
                .background(.ultraThinMaterial)
                .mappingCornerRadius(24, corners: [.topLeft, .topRight])
            }
        }
        .alert("Exit Mapping?", isPresented: $showExitAlert) {
            Button("Discard & Exit", role: .destructive) { mapper.pauseSession(); dismiss() }
            if mapper.hasData {
                Button("Save & Exit") { saveMap(); mapper.pauseSession(); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(mapper.isMapping ? "Scanning is in progress." : "You have unsaved map data.")
        }
        .alert("Map Saved to Photos", isPresented: $showSavedAlert) {
            Button("Done") { mapper.pauseSession(); dismiss() }
            Button("Keep Scanning", role: .cancel) {}
        }
        .onAppear {
            // Start the AR session immediately so the camera feed shows and the
            // system permission dialog fires on first launch.
            mapper.startPreview()
        }
        .onDisappear {
            mapper.pauseSession()
        }
    }

    private var trackingPillColor: Color {
        switch mapper.trackingState {
        case "Tracking":       return .green
        case "Initializing...": return .orange
        default:               return .red
        }
    }

    private func saveMap() {
        guard let img = mapper.renderMapImage() else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        showSavedAlert = true
    }
}
