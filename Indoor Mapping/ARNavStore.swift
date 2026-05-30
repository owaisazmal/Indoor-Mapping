import ARKit
import Combine
import SceneKit

// MARK: - AR Navigation Store
// Thin coordinator: owns ARNavSession (position) and ARNodeBuilder (nodes).
// Bridges raw camera data into published floor-plan state for the navigation UI.

final class ARNavStore: ObservableObject {

    @Published var userUV      = CGPoint(x: 0.5, y: 0.85)
    @Published var activeNav:   NavDestination?
    @Published var pathUVs:    [CGPoint] = []
    @Published var distMeters: Float = 0

    let scene = SCNScene()

    // Set by ARNavigationView before calling start().
    var floorWidthMeters:  Double = 30
    var floorHeightMeters: Double = 20
    var originUV = CGPoint(x: 0.5, y: 0.85)

    private let arSession  = ARNavSession()
    private var pathNodes: [SCNNode] = []

    // Position tracking relative to session start
    private var hasOrigin = false
    private var originX:  Float = 0
    private var originZ:  Float = 0

    /// The ARKit session — exposed so ARNavSceneView can attach to it.
    var arKitSession: ARSession { arSession.session }

    init() {
        arSession.onCameraPosition = { [weak self] worldX, worldZ in
            self?.handlePosition(worldX: worldX, worldZ: worldZ)
        }
    }

    // MARK: - Session control

    func start() {
        hasOrigin = false
        arSession.start()
    }

    func stop() { arSession.stop() }

    // MARK: - Navigation commands

    func navigate(to dest: NavDestination) {
        activeNav = dest
        ARNodeBuilder.clearNodes(&pathNodes)
        pathNodes = ARNodeBuilder.buildPath(to: dest, in: scene)
        pathUVs   = [userUV, dest.mapUV]
    }

    func cancel() {
        activeNav = nil; pathUVs = []
        ARNodeBuilder.clearNodes(&pathNodes)
    }

    // MARK: - Private

    private func handlePosition(worldX: Float, worldZ: Float) {
        if !hasOrigin { originX = worldX; originZ = worldZ; hasOrigin = true }

        let relX = worldX - originX
        let relZ = worldZ - originZ
        let dx   = CGFloat(relX) / CGFloat(floorWidthMeters)
        let dz   = CGFloat(relZ) / CGFloat(floorHeightMeters)
        userUV   = CGPoint(x: originUV.x + dx, y: originUV.y + dz)

        if let nav = activeNav {
            let ex = worldX - nav.worldX, ez = worldZ - nav.worldZ
            distMeters = sqrt(ex * ex + ez * ez)
        }
    }
}
