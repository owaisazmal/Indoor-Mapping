import ARKit

// MARK: - AR Navigation Session
// Single responsibility: run an ARSession and deliver raw camera world-position
// via a callback. Has no knowledge of floor plans, POIs, or SceneKit.

final class ARNavSession: NSObject {

    let session = ARSession()

    /// Called on the main actor every AR frame with the camera's world (X, Z).
    var onCameraPosition: ((Float, Float) -> Void)?

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravityAndHeading
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session.pause() }
}

// MARK: - ARSessionDelegate

extension ARNavSession: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let x = frame.camera.transform.columns.3.x
        let z = frame.camera.transform.columns.3.z
        Task { @MainActor [weak self] in self?.onCameraPosition?(x, z) }
    }
}
