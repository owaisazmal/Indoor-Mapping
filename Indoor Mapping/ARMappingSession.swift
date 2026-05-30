import ARKit
import CoreMotion
import simd
import UIKit

// MARK: - AR Mapping Session
// Owns the ARSession, accumulates feature points and camera path,
// and throttles data delivery to ~4 fps via callbacks.

final class ARMappingSession: NSObject {

    let session      = ARSession()
    let hasGyro:       Bool
    let hasBarometer:  Bool

    private let altimeter     = CMAltimeter()
    private var isRecording   = false
    private var _featureBuffer: [simd_float3] = []
    private var _pathBuffer:    [simd_float3] = []
    private var _lastFlush:     TimeInterval  = 0
    private let _flushInterval: TimeInterval  = 1.0 / 4   // 4 fps canvas refresh

    // Callbacks — always invoked on the main actor.
    var onDataFlush:     (([simd_float3], [simd_float3]) -> Void)?
    var onTrackingState: ((String) -> Void)?
    var onAltitude:      ((Float) -> Void)?

    override init() {
        hasGyro      = CMMotionManager().isGyroAvailable
        hasBarometer = CMAltimeter.isRelativeAltitudeAvailable()
        super.init()
        session.delegate = self
    }

    // MARK: - Session control

    func startPreview() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = [.horizontal, .vertical]
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func startRecording() {
        _featureBuffer = []; _pathBuffer = []; _lastFlush = 0
        isRecording = true
        if hasBarometer {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                if let alt = data?.relativeAltitude.floatValue { self?.onAltitude?(alt) }
            }
        }
    }

    /// Stops recording and returns the final accumulated data.
    func stopRecording() -> (features: [simd_float3], path: [simd_float3]) {
        isRecording = false
        altimeter.stopRelativeAltitudeUpdates()
        return (_featureBuffer, _pathBuffer)
    }

    func pause() { session.pause() }

    // MARK: - Coordinate transform (pure static utility)

    struct MapTransform {
        let minX, minZ, scale, offX, offZ: Double
        func canvas(worldX x: Float, worldZ z: Float) -> CGPoint {
            CGPoint(x: (Double(x) - minX) * scale + offX,
                    y: (Double(z) - minZ) * scale + offZ)
        }
    }

    static func makeTransform(features: [simd_float3], path: [simd_float3],
                               size: CGSize) -> MapTransform? {
        guard !path.isEmpty else { return nil }
        let allX = features.map { Double($0.x) } + path.map { Double($0.x) }
        let allZ = features.map { Double($0.z) } + path.map { Double($0.z) }
        let minX = (allX.min() ?? 0) - 0.5, maxX = (allX.max() ?? 0) + 0.5
        let minZ = (allZ.min() ?? 0) - 0.5, maxZ = (allZ.max() ?? 0) + 0.5
        let rangeX = max(maxX - minX, 0.1), rangeZ = max(maxZ - minZ, 0.1)
        let scale  = min(Double(size.width) / rangeX, Double(size.height) / rangeZ)
        return MapTransform(minX: minX, minZ: minZ, scale: scale,
                            offX: (Double(size.width)  - rangeX * scale) / 2,
                            offZ: (Double(size.height) - rangeZ * scale) / 2)
    }

    // MARK: - Map image export

    static func renderMapImage(features: [simd_float3], path: [simd_float3],
                                pois: [MappedPOI],
                                size: CGSize = CGSize(width: 1200, height: 1200)) -> UIImage? {
        guard !path.isEmpty, let t = makeTransform(features: features, path: path, size: size) else {
            return nil
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(white: 0.96, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

            UIColor.darkGray.setFill()
            for p in features {
                let sp = t.canvas(worldX: p.x, worldZ: p.z)
                UIBezierPath(ovalIn: CGRect(x: sp.x-2, y: sp.y-2, width: 4, height: 4)).fill()
            }

            if path.count > 1 {
                let bezier = UIBezierPath()
                bezier.move(to: t.canvas(worldX: path[0].x, worldZ: path[0].z))
                for p in path.dropFirst() { bezier.addLine(to: t.canvas(worldX: p.x, worldZ: p.z)) }
                UIColor.systemBlue.setStroke(); bezier.lineWidth = 4; bezier.stroke()
            }

            for (i, poi) in pois.enumerated() {
                let cp = t.canvas(worldX: poi.worldX, worldZ: poi.worldZ)
                poiUIColors[i % poiUIColors.count].setFill()
                UIBezierPath(ovalIn: CGRect(x: cp.x-10, y: cp.y-10, width: 20, height: 20)).fill()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.darkGray
                ]
                (poi.name as NSString).draw(at: CGPoint(x: cp.x+12, y: cp.y-7), withAttributes: attrs)
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension ARMappingSession: ARSessionDelegate {

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
            guard let self, self.isRecording else {
                // Still report tracking state even during preview
                self?.onTrackingState?(stateStr)
                return
            }

            if let last = self._pathBuffer.last {
                if simd_distance(camPos, last) > 0.15 { self._pathBuffer.append(camPos) }
            } else {
                self._pathBuffer.append(camPos)
            }

            if !sampled.isEmpty {
                self._featureBuffer.append(contentsOf: sampled)
                if self._featureBuffer.count > 40_000 {
                    self._featureBuffer = Array(self._featureBuffer.suffix(40_000))
                }
            }

            if stateStr != (self.onTrackingState == nil ? stateStr : stateStr) {
                self.onTrackingState?(stateStr)
            }

            let now = CACurrentMediaTime()
            if now - self._lastFlush >= self._flushInterval {
                self._lastFlush = now
                self.onDataFlush?(self._featureBuffer, self._pathBuffer)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.onTrackingState?("Sensor error") }
    }
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.onTrackingState?("Interrupted") }
    }
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.onTrackingState?("Resuming...") }
    }
}
