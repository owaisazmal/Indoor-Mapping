import ARKit
import Combine
import SwiftUI
import simd

// MARK: - Indoor Mapper
// Thin coordinator: owns ARMappingSession (AR + sensors) and exposes
// @Published state for the mapping UI. POI management lives here because
// it belongs to the same scanning workflow.

final class IndoorMapper: ObservableObject {

    @Published var isMapping        = false
    @Published var hasData          = false
    @Published var pointCount       = 0
    @Published var scannedAreaM2:   Float = 0
    @Published var currentFloor:    Float = 0
    @Published var trackingState    = "Tap Start to begin"
    @Published var pois:            [MappedPOI] = []

    @Published private(set) var featurePoints: [simd_float3] = []
    @Published private(set) var cameraPath:    [simd_float3] = []

    private let arSession = ARMappingSession()

    var hasGyro:      Bool { arSession.hasGyro }
    var hasBarometer: Bool { arSession.hasBarometer }
    let hasGPS = true

    init() {
        arSession.onDataFlush = { [weak self] features, path in
            guard let self else { return }
            self.featurePoints = features
            self.cameraPath    = path
            self.pointCount    = features.count
        }
        arSession.onTrackingState = { [weak self] state in
            guard let self, state != self.trackingState else { return }
            self.trackingState = state
        }
        arSession.onAltitude = { [weak self] alt in
            self?.currentFloor = alt
        }
    }

    // MARK: - Session control

    func startPreview() {
        trackingState = "Initializing..."
        arSession.startPreview()
    }

    func startMapping() {
        featurePoints = []; cameraPath = []
        isMapping = true; hasData = false; pointCount = 0; scannedAreaM2 = 0
        arSession.startRecording()
    }

    func stopMapping() {
        isMapping = false
        let (features, path) = arSession.stopRecording()
        featurePoints = features
        cameraPath    = path
        pointCount    = features.count
        hasData       = !features.isEmpty
        let xs = path.map { $0.x }, zs = path.map { $0.z }
        scannedAreaM2 = ((xs.max() ?? 0) - (xs.min() ?? 0)) *
                        ((zs.max() ?? 0) - (zs.min() ?? 0))
    }

    func pauseSession() { arSession.pause() }

    /// The underlying ARSession — exposed so ARCameraView can attach to it.
    var arKitSession: ARSession { arSession.session }

    // MARK: - POI management

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

    // MARK: - Coordinate transform (delegates to ARMappingSession)

    func makeTransform(size: CGSize) -> ARMappingSession.MapTransform? {
        ARMappingSession.makeTransform(features: featurePoints, path: cameraPath, size: size)
    }

    // MARK: - Map image export

    func renderMapImage(size: CGSize = CGSize(width: 1200, height: 1200)) -> UIImage? {
        guard hasData else { return nil }
        return ARMappingSession.renderMapImage(features: featurePoints,
                                               path: cameraPath, pois: pois, size: size)
    }
}
