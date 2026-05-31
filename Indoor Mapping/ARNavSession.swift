import ARKit

// MARK: - AR Navigation Session
// Single responsibility: run an ARSession and deliver raw camera world-position
// via callbacks. Has no knowledge of floor plans, POIs, or SceneKit.
// All callbacks are dispatched to the main actor before being invoked.

final class ARNavSession: NSObject {

    let session = ARSession()

    // MARK: - Callbacks (set by ARNavStore before calling start())

    /// Fired every AR frame with the camera's world (X, Z) while tracking is active.
    var onCameraPosition:   ((Float, Float) -> Void)?

    /// Fired when the OS interrupts the AR session (camera covered, app backgrounded).
    var onInterrupted:      (() -> Void)?

    /// Fired when the interruption ends. VIO origin cannot be trusted at this point.
    var onInterruptionEnded: (() -> Void)?

    /// Fired when ARKit reports a fatal session error.
    var onFailed:           ((Error) -> Void)?

    /// Fired whenever ARKit's camera tracking quality changes.
    /// The store uses this to transition to `.degraded` on `.limited` states.
    var onTrackingQualityChanged: ((ARCamera.TrackingState) -> Void)?

    // MARK: - Session control

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravityAndHeading
        session.delegate = self
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

    /// The OS interrupted the session — camera unavailable or app entered background.
    /// Position updates must halt immediately; the current UV is frozen in place.
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.onInterrupted?() }
    }

    /// The interruption ended but ARKit's VIO origin has shifted by an unknown
    /// amount.  Without physical anchors there is no way to quantify or correct
    /// the drift, so the session must be stopped and the user must re-calibrate.
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.onInterruptionEnded?() }
    }

    /// A fatal sensor or configuration error that makes the session unrecoverable.
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.onFailed?(error) }
    }

    /// ARKit's camera tracking quality changed — e.g. moved to .limited due to
    /// insufficient visual features or relocalizing after a brief interruption.
    nonisolated func session(_ session: ARSession,
                             camera: ARCamera,
                             didChangeTrackingState trackingState: ARCamera.TrackingState) {
        Task { @MainActor [weak self] in self?.onTrackingQualityChanged?(trackingState) }
    }
}
