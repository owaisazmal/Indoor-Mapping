import ARKit
import Combine
import SceneKit

// MARK: - Tracking status

/// The four states the AR navigation session can be in.
/// Only `.active` allows `userUV` to be updated.
enum TrackingStatus: Equatable {
    /// Normal operation — VIO is running and position updates flow through.
    case active
    /// ARKit reported `.limited` tracking quality (insufficient visual features
    /// or relocalizing after a brief gap).  Position updates are frozen until
    /// quality returns to `.normal`.  The session is still running and may
    /// auto-recover without user intervention.
    case degraded
    /// The OS interrupted the session (camera covered, app backgrounded).
    /// Position updates are frozen; the overlay prompts the user to restore
    /// the camera view.  The session may automatically recover.
    case interrupted
    /// The interruption ended but the VIO origin has drifted by an unknown
    /// amount.  The session has been stopped.  The user must re-drop their
    /// starting pin before navigation can resume.
    case lost
}

// MARK: - AR Navigation Store
// Thin coordinator: owns ARNavSession (position) and ARNodeBuilder (nodes).
// Bridges raw camera data into published floor-plan state for the navigation UI.

final class ARNavStore: ObservableObject {

    @Published var userUV:           CGPoint       // starts at originUV, updated each AR frame
    @Published var activeNav:        NavDestination?
    @Published var pathUVs:         [CGPoint] = []
    @Published var distMeters:       Float = 0
    /// Current session health.  The UI observes this to show interruption overlays.
    @Published private(set) var trackingStatus: TrackingStatus = .active

    let scene = SCNScene()

    // Set by ARNavActiveView before start() is called.
    var floorWidthMeters:  Double = 30
    var floorHeightMeters: Double = 20

    /// The user's confirmed starting position on the floor plan (UV, 0–1).
    /// Passed in at initialisation from the calibration tap; never changes after that.
    private(set) var originUV: CGPoint

    /// Rotation offset (degrees) that aligns ARKit's world axes with the floor plan
    /// image axes.  Derived by the caller as:
    ///   deviceMagneticHeading (at calibration time) − floorPlan.rotationDegrees
    /// A value of 0 means the top of the floor plan image faces magnetic north,
    /// which is exactly what ARKit's −Z axis represents.
    private(set) var headingOffsetDegrees: Double

    /// Optional graph used for A* pathfinding in navigate(to:).
    /// When nil the navigator falls back to a direct UV line to the destination.
    var navGraph: NavGraph?

    private let arSession      = ARNavSession()
    private let pathRenderer   = ARPathRenderer()
    private var pathNodes:       [SCNNode] = []

    // Position tracking relative to the first AR frame
    private var hasOrigin = false
    private var originX:  Float = 0
    private var originZ:  Float = 0

    /// The ARKit session — exposed so ARNavSceneView can attach to it.
    var arKitSession: ARSession { arSession.session }

    /// Designated init.
    /// - `originUV`: UV coordinate the user tapped to mark their physical position.
    /// - `headingOffsetDegrees`: compass heading of the device at calibration time
    ///   minus the floor plan's visual rotation angle.  Defaults to 0 (north-up map).
    init(originUV: CGPoint, headingOffsetDegrees: Double = 0) {
        self.originUV             = originUV
        self.headingOffsetDegrees = headingOffsetDegrees
        self.userUV               = originUV   // dot starts at the calibrated position
        wireSessionCallbacks()
    }

    private func wireSessionCallbacks() {
        arSession.onCameraPosition = { [weak self] worldX, worldZ in
            self?.handlePosition(worldX: worldX, worldZ: worldZ)
        }
        arSession.onInterrupted = { [weak self] in
            guard let self else { return }
            // Freeze position updates immediately; leave the session running so
            // ARKit can attempt automatic recovery for short interruptions.
            self.trackingStatus = .interrupted
        }
        arSession.onInterruptionEnded = { [weak self] in
            guard let self else { return }
            // The OS restored the session, but VIO has drifted by an unknown
            // amount without physical anchors to correct against.  Stop the
            // session to prevent stale positions from reaching handlePosition,
            // then require the user to re-calibrate.
            self.arSession.stop()
            self.trackingStatus = .lost
        }
        arSession.onFailed = { [weak self] (_: Error) in
            guard let self else { return }
            self.arSession.stop()
            self.trackingStatus = .lost
        }
        arSession.onTrackingQualityChanged = { [weak self] (state: ARCamera.TrackingState) in
            guard let self else { return }
            switch state {
            case .normal:
                // Only lift out of .degraded; never override .interrupted or .lost
                // with a stale quality callback that arrives after those are set.
                if self.trackingStatus == .degraded { self.trackingStatus = .active }
            case .limited(let reason):
                // Guard: don't downgrade a more-severe status.
                guard self.trackingStatus == .active else { return }
                switch reason {
                case .insufficientFeatures, .relocalizing:
                    self.trackingStatus = .degraded
                default:
                    break
                }
            default:
                break
            }
        }
    }

    // MARK: - Session control

    func start() {
        hasOrigin      = false
        trackingStatus = .active
        arSession.start()
    }

    func stop() { arSession.stop() }

    // MARK: - Navigation commands

    func navigate(to dest: NavDestination) {
        activeNav = dest
        ARNodeBuilder.clearNodes(&pathNodes)
        pathNodes = ARNodeBuilder.buildPath(to: dest, in: scene)

        // Build UV path — A* through the graph if one is loaded, direct line otherwise.
        if let graph = navGraph,
           let result = NavPathfinder(graph: graph)
               .findPath(from: userUV, to: NavNode.from(dest)) {
            pathUVs = result.uvPath
        } else {
            pathUVs = [userUV, dest.mapUV]
        }

        // Render floor-level AR chevrons only once the session has a world origin.
        if hasOrigin {
            pathRenderer.buildPath(
                uvs:                  pathUVs,
                originUV:             originUV,
                originX:              originX,
                originZ:              originZ,
                floorWidthMeters:     floorWidthMeters,
                floorHeightMeters:    floorHeightMeters,
                headingOffsetDegrees: headingOffsetDegrees,
                in:                   scene)
        }
    }

    func cancel() {
        activeNav = nil; pathUVs = []
        ARNodeBuilder.clearNodes(&pathNodes)
        pathRenderer.clearPath(in: scene)
    }

    // MARK: - Private

    private func handlePosition(worldX: Float, worldZ: Float) {
        // Hard gate: never update userUV while interrupted or lost.
        // The session callbacks set trackingStatus; this guard is a safety net
        // in case a queued frame arrives after status already changed.
        guard trackingStatus == .active else { return }

        // Record the world-space origin on the very first frame so all subsequent
        // positions are expressed as deltas relative to where the session started.
        if !hasOrigin { originX = worldX; originZ = worldZ; hasOrigin = true }

        let relX = worldX - originX
        let relZ = worldZ - originZ

        // ── Heading correction ────────────────────────────────────────────────
        // ARKit (worldAlignment: .gravityAndHeading) fixes its coordinate axes to
        // magnetic north: −Z = North, +X = East.  The floor plan image has its own
        // orientation that may differ from north by `headingOffsetDegrees`.
        //
        // We rotate the raw (relX, relZ) displacement vector by θ so that movement
        // along the real-world axes maps correctly onto the image's u/v axes:
        //
        //   relX_r = relX · cos θ  −  relZ · sin θ
        //   relZ_r = relX · sin θ  +  relZ · cos θ
        //
        // θ = 0  → no-op (floor plan top already faces north).
        // θ = 90 → walking north on the device reads as walking "left" on the image,
        //          which is correct when the floor plan's top faces East.
        let theta  = Float(headingOffsetDegrees * .pi / 180.0)
        let cosT   = cos(theta)
        let sinT   = sin(theta)
        let relX_r = relX * cosT - relZ * sinT
        let relZ_r = relX * sinT + relZ * cosT

        let dx = CGFloat(relX_r) / CGFloat(floorWidthMeters)
        let dz = CGFloat(relZ_r) / CGFloat(floorHeightMeters)

        // Apply the rotated delta to the user-confirmed UV origin.
        userUV = CGPoint(x: originUV.x + dx, y: originUV.y + dz)

        if let nav = activeNav {
            let ex = worldX - nav.worldX, ez = worldZ - nav.worldZ
            distMeters = sqrt(ex * ex + ez * ez)
            pathRenderer.updateProgress(userUV: userUV)
        }
    }
}
