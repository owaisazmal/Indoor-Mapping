import SceneKit
import simd
import UIKit

// MARK: - ARPathRenderer
//
// Converts a UV-space A* path back into ARKit world coordinates and renders
// it as floor-level chevron arrows + connecting tubes in a SceneKit scene.
//
// Inverse of the forward tracking math in ARNavStore.handlePosition:
//
//   Forward (tracking):
//     relX = worldX − originX
//     relZ = worldZ − originZ
//     relX_r =  relX·cosθ − relZ·sinθ      ← rotate by +θ
//     relZ_r =  relX·sinθ + relZ·cosθ
//     userUV = originUV + (relX_r/floorW, relZ_r/floorH)
//
//   Inverse (rendering):
//     du     = (uv.x − originUV.x) · floorW
//     dv     = (uv.y − originUV.y) · floorH
//     relX   = du·cosθ + dv·sinθ           ← rotate by −θ (R⁻¹ = Rᵀ)
//     relZ   = −du·sinθ + dv·cosθ
//     world  = (originX + relX,  floorY,  originZ + relZ)

final class ARPathRenderer {

    // ── Tuning constants ──────────────────────────────────────────────────────

    /// Y-offset from ARKit session origin to floor level.
    /// ARKit places its origin at device height when the session starts
    /// (~1.2–1.5 m above the floor), so a value of -1.2 places geometry
    /// at approximately floor level.
    var floorYOffset: Float = -1.2

    /// Horizontal radius (meters) within which a waypoint is considered
    /// "passed" and its corresponding segment node is hidden.
    var passRadius: Float = 0.9

    // ── Internal storage ──────────────────────────────────────────────────────

    private struct SegmentEntry {
        let node:      SCNNode
        let fromWorld: simd_float3   // XZ position of the segment's start waypoint
    }
    private var segments: [SegmentEntry] = []

    // Cached coordinate-system parameters — set once per buildPath call.
    private var cachedOriginUV = CGPoint.zero
    private var cachedOriginX: Float = 0
    private var cachedOriginZ: Float = 0
    private var cachedFloorW:  Double = 30
    private var cachedFloorH:  Double = 20
    private var cachedCosT:    Float  = 1   // cos(θ) where θ = headingOffsetDegrees
    private var cachedSinT:    Float  = 0   // sin(θ)

    // MARK: - Coordinate transform

    /// Converts a UV floor-plan coordinate into an ARKit world position using
    /// the coordinate system captured in the last `buildPath(...)` call.
    func worldPosition(for uv: CGPoint) -> simd_float3 {
        let du = Float(uv.x - cachedOriginUV.x) * Float(cachedFloorW)
        let dv = Float(uv.y - cachedOriginUV.y) * Float(cachedFloorH)
        // R⁻¹ = Rᵀ for a 2-D rotation matrix:
        //   relX =  du·cosθ + dv·sinθ
        //   relZ = −du·sinθ + dv·cosθ
        let relX = du * cachedCosT + dv * cachedSinT
        let relZ = -du * cachedSinT + dv * cachedCosT
        return simd_float3(cachedOriginX + relX, floorYOffset, cachedOriginZ + relZ)
    }

    // MARK: - Build

    /// Clears any previous path and renders `uvs` as a floor-level arrow trail
    /// in `scene`.  Must be called after the ARKit session has established its
    /// first frame (i.e. `originX`/`originZ` are valid in the store).
    func buildPath(
        uvs:                  [CGPoint],
        originUV:             CGPoint,
        originX:              Float,
        originZ:              Float,
        floorWidthMeters:     Double,
        floorHeightMeters:    Double,
        headingOffsetDegrees: Double,
        in scene:             SCNScene
    ) {
        clearPath(in: scene)
        guard uvs.count >= 2 else { return }

        // Cache coordinate system for this path so updateProgress can use it
        // without needing the store's private fields.
        cachedOriginUV = originUV
        cachedOriginX  = originX
        cachedOriginZ  = originZ
        cachedFloorW   = floorWidthMeters
        cachedFloorH   = floorHeightMeters
        let theta      = Float(headingOffsetDegrees * .pi / 180.0)
        cachedCosT     = cos(theta)
        cachedSinT     = sin(theta)

        let positions  = uvs.map { worldPosition(for: $0) }

        for i in 0 ..< positions.count - 1 {
            let from    = positions[i]
            let to      = positions[i + 1]
            let node    = makeSegmentNode(from: from, to: to)
            node.name   = "pathSeg_\(i)"
            scene.rootNode.addChildNode(node)
            segments.append(SegmentEntry(node: node, fromWorld: from))
        }

        let destNode = makeDestinationNode(at: positions[positions.count - 1])
        destNode.name = "pathDest"
        scene.rootNode.addChildNode(destNode)
        // Store destination separately — we never hide it via progress checks.
        segments.append(SegmentEntry(node: destNode,
                                     fromWorld: positions[positions.count - 1]))
    }

    // MARK: - Dynamic progress

    /// Call every AR frame (from `ARNavStore.handlePosition`) while navigation
    /// is active.  Hides each segment whose starting waypoint the user has
    /// walked past (XZ distance < `passRadius`).
    func updateProgress(userUV: CGPoint) {
        guard !segments.isEmpty else { return }
        let user = worldPosition(for: userUV)
        for entry in segments {
            guard entry.node.name?.hasPrefix("pathSeg") == true,
                  !entry.node.isHidden else { continue }
            let dx   = entry.fromWorld.x - user.x
            let dz   = entry.fromWorld.z - user.z
            let dist = (dx * dx + dz * dz).squareRoot()
            if dist < passRadius {
                entry.node.isHidden = true
            }
        }
    }

    // MARK: - Clear

    func clearPath(in scene: SCNScene) {
        segments.forEach { $0.node.removeFromParentNode() }
        segments.removeAll()
    }

    // MARK: - SceneKit node factories

    /// One segment = a floor-level tube (the path line) + a chevron cone
    /// (directional arrow) at the start waypoint.
    private func makeSegmentNode(from: simd_float3, to: simd_float3) -> SCNNode {
        let dx  = to.x - from.x
        let dz  = to.z - from.z
        let len = (dx * dx + dz * dz).squareRoot()
        guard len > 0.05 else { return SCNNode() }

        let dir = simd_float3(dx / len, 0, dz / len)
        let rot = quaternionAligning(yAxisTo: dir)
        let container = SCNNode()

        // ── Connecting tube ───────────────────────────────────────────────────
        let tube = SCNCylinder(radius: 0.035, height: CGFloat(len))
        tube.firstMaterial?.diffuse.contents  = UIColor.systemBlue.withAlphaComponent(0.75)
        tube.firstMaterial?.emission.contents = UIColor.systemCyan.withAlphaComponent(0.35)
        tube.firstMaterial?.lightingModel     = .constant
        tube.firstMaterial?.isDoubleSided     = true

        let tubeNode             = SCNNode(geometry: tube)
        tubeNode.simdPosition    = simd_float3((from.x + to.x) / 2,
                                                floorYOffset,
                                                (from.z + to.z) / 2)
        tubeNode.simdOrientation = rot

        // ── Directional chevron at the start of this segment ─────────────────
        let cone = SCNCone(topRadius: 0, bottomRadius: 0.10, height: 0.20)
        cone.firstMaterial?.diffuse.contents  = UIColor.white.withAlphaComponent(0.90)
        cone.firstMaterial?.emission.contents = UIColor.systemCyan.withAlphaComponent(0.55)
        cone.firstMaterial?.lightingModel     = .constant
        cone.firstMaterial?.isDoubleSided     = true

        let coneNode             = SCNNode(geometry: cone)
        coneNode.simdPosition    = simd_float3(from.x, floorYOffset + 0.01, from.z)
        coneNode.simdOrientation = rot

        container.addChildNode(tubeNode)
        container.addChildNode(coneNode)
        return container
    }

    /// Pulsing green sphere marking the final destination.
    private func makeDestinationNode(at position: simd_float3) -> SCNNode {
        let sphere = SCNSphere(radius: 0.20)
        sphere.firstMaterial?.diffuse.contents  = UIColor.systemGreen.withAlphaComponent(0.75)
        sphere.firstMaterial?.emission.contents = UIColor.systemGreen.withAlphaComponent(0.50)
        sphere.firstMaterial?.lightingModel     = .constant
        sphere.firstMaterial?.isDoubleSided     = true

        let node          = SCNNode(geometry: sphere)
        node.simdPosition = simd_float3(position.x, floorYOffset + 0.20, position.z)

        let pulse          = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue    = 0.40
        pulse.toValue      = 1.0
        pulse.duration     = 1.0
        pulse.autoreverses = true
        pulse.repeatCount  = .infinity
        node.addAnimation(pulse, forKey: "destinationPulse")

        return node
    }

    // MARK: - Rotation helper

    /// Returns a quaternion that rotates the +Y axis to align with `dir`.
    ///
    /// Derivation:
    ///   cross(Y=(0,1,0), dir=(dx,0,dz)) = (dz, 0, −dx)    — already unit-length when |dir|=1
    ///   dot(Y, dir)                     = 0                 — Y ⊥ dir (dir is horizontal)
    ///   → rotation is always exactly 90° around (dz, 0, −dx)
    ///
    /// Proof via Rodrigues: rotating (0,1,0) by 90° around (dz,0,−dx) gives
    ///   k × v = (0·0−(−dx)·1, (−dx)·0−dz·0, dz·1−0·0) = (dx, 0, dz) ✓
    private func quaternionAligning(yAxisTo dir: simd_float3) -> simd_quatf {
        // axis = (dir.z, 0, −dir.x), which equals cross(Y, dir) for a horizontal dir
        let axis = simd_normalize(simd_float3(dir.z, 0, -dir.x))
        return simd_quatf(angle: .pi / 2, axis: axis)
    }
}
