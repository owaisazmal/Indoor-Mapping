import CoreGraphics
import Foundation

// MARK: - NavNode

/// A waypoint in the floor-plan navigation graph.
/// Positions are stored in UV space (0–1 on each axis, origin at top-left of
/// the floor-plan image) so they map directly onto `userUV` and POI `mapUV`.
struct NavNode: Identifiable, Hashable {
    let id:   String
    let name: String
    let uv:   CGPoint
    var icon: String = "mappin.fill"

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: NavNode, rhs: NavNode) -> Bool { lhs.id == rhs.id }

    /// Stable color index derived from the node id — no need to store it on disk.
    var colorIndex: Int { abs(id.hashValue) % poiUIColors.count }

    static func from(_ dest: NavDestination) -> NavNode {
        NavNode(id: "POI_\(dest.id)", name: dest.name, uv: dest.mapUV, icon: dest.icon)
    }

    /// Build a NavDestination for AR navigation from this node's UV position.
    func toNavDestination(id destID: Int,
                          widthMeters: Double,
                          heightMeters: Double) -> NavDestination {
        NavDestination(
            id:      destID,
            name:    name,
            icon:    icon,
            mapUV:   uv,
            worldX:  Float((uv.x - 0.5) * widthMeters),
            worldZ:  Float((uv.y - 0.5) * heightMeters),
            uiColor: poiUIColors[colorIndex]
        )
    }
}

// MARK: - NavEdge

/// A directed connection between two nodes in the graph.
/// `NavGraph.addEdge` always adds both directions, making edges undirected in practice.
struct NavEdge {
    let fromID: String
    let toID:   String
    /// Traversal cost. When not supplied, `NavGraph` auto-computes this as the
    /// UV-space Euclidean distance between the two endpoints.  Keep weights in
    /// the same unit as the A* heuristic (UV distance) for admissibility.
    let weight: Double
    /// `true`  → corridor, elevator, ramp (no level change via stairs).
    /// `false` → stairs only; skipped when `accessibilityRequired` is set.
    let isWheelchairAccessible: Bool
}

// MARK: - NavGraph

/// The navigation graph for a single floor plan.
/// Build it once at app startup (or when a floor plan is loaded) and hand the
/// same instance to `NavPathfinder`.
final class NavGraph {

    private(set) var nodes:     [String: NavNode]   = [:]
    private(set) var adjacency: [String: [NavEdge]] = [:]
    /// Walkable zones drawn in GraphBuilderView. UV coords, origin top-left.
    /// Empty means unconstrained (fallback: clamp to [0,1] image bounds).
    var walkableRects: [CGRect] = []

    // MARK: Mutations

    func addNode(_ node: NavNode) {
        nodes[node.id] = node
        if adjacency[node.id] == nil { adjacency[node.id] = [] }
    }

    /// Adds an **undirected** edge (stored as two directed edges internally).
    ///
    /// - Parameters:
    ///   - fromID / toID: IDs of nodes that must already exist in the graph.
    ///   - weight: Traversal cost. Defaults to UV Euclidean distance between
    ///     the two nodes — keep this consistent with the A* heuristic.
    ///   - isWheelchairAccessible: Pass `false` for stair-only connections.
    func addEdge(from fromID: String,
                 to   toID: String,
                 weight: Double? = nil,
                 isWheelchairAccessible: Bool = true) {
        guard let a = nodes[fromID], let b = nodes[toID] else {
            assertionFailure("NavGraph.addEdge: unknown node id '\(fromID)' or '\(toID)'")
            return
        }
        let w = weight ?? a.uv.navDistance(to: b.uv)
        adjacency[fromID, default: []].append(
            NavEdge(fromID: fromID, toID: toID, weight: w,
                    isWheelchairAccessible: isWheelchairAccessible))
        adjacency[toID,   default: []].append(
            NavEdge(fromID: toID, toID: fromID, weight: w,
                    isWheelchairAccessible: isWheelchairAccessible))
    }

    // MARK: Queries

    /// The node geographically closest to `uv`. O(n) — acceptable for the
    /// typical indoor floor-plan scale (≤ a few hundred nodes).
    func nearestNode(to uv: CGPoint) -> NavNode? {
        nodes.values.min { $0.uv.navDistance(to: uv) < $1.uv.navDistance(to: uv) }
    }
}

// MARK: - NavPathfinder

/// Runs A* on a `NavGraph` to find the shortest (optionally wheelchair-accessible)
/// path between any UV position on the floor plan and a destination `NavNode`.
final class NavPathfinder {

    // MARK: Result type

    struct PathResult {
        /// Ordered waypoints from the snapped start node to the destination.
        let nodes: [NavNode]
        /// Sum of edge weights along the chosen path (UV distance by default).
        let totalCost: Double
        /// Convenience UV sequence ready to draw on `NavMapCanvas`.
        var uvPath: [CGPoint] { nodes.map(\.uv) }
    }

    // MARK: Stored state

    private let graph: NavGraph

    init(graph: NavGraph) { self.graph = graph }

    // MARK: Public API

    /// Finds the cheapest path using A*.
    ///
    /// - Parameters:
    ///   - startUV: The user's current UV position (`ARNavStore.userUV`).
    ///     Snapped to the nearest graph node automatically.
    ///   - destination: Target `NavNode` to navigate to.
    ///   - accessibilityRequired: When `true`, only edges where
    ///     `isWheelchairAccessible == true` are traversed — routing through
    ///     elevators and ramps instead of stairs.
    /// - Returns: A `PathResult` with the ordered waypoint list, or `nil` when
    ///   no valid path exists (disconnected graph or no accessible route).
    func findPath(from startUV: CGPoint,
                  to destination: NavNode,
                  accessibilityRequired: Bool = false) -> PathResult? {

        guard graph.nodes[destination.id] != nil else { return nil }
        guard let startNode = graph.nearestNode(to: startUV)  else { return nil }

        if startNode.id == destination.id {
            return PathResult(nodes: [startNode], totalCost: 0)
        }

        return astar(from: startNode, to: destination,
                     accessibilityRequired: accessibilityRequired)
    }

    // MARK: A* core

    private func astar(from start: NavNode,
                       to goal: NavNode,
                       accessibilityRequired: Bool) -> PathResult? {

        // gScore[id] — best confirmed cost from start to this node.
        var gScore:   [String: Double] = [start.id: 0]
        // cameFrom[id] — predecessor on the cheapest path found so far.
        var cameFrom: [String: String] = [:]

        // Open list stored as an array of (id, fScore) pairs.
        // We use "lazy deletion": when a cheaper path to a node is found we
        // append a new entry rather than updating the existing one, then skip
        // stale entries via `closedIDs`. This keeps the implementation simple
        // and correct; swap in a proper min-heap if node counts exceed ~500.
        var open:      [(id: String, f: Double)] = [(start.id, heuristic(start, goal))]
        var closedIDs: Set<String> = []

        while !open.isEmpty {

            // Pull the entry with the lowest f value.
            let minIndex = open.indices.min { open[$0].f < open[$1].f }!
            let current  = open.remove(at: minIndex)

            // Skip stale open-list entries for already-settled nodes.
            guard !closedIDs.contains(current.id) else { continue }
            closedIDs.insert(current.id)

            // ── Goal reached ─────────────────────────────────────────────────
            if current.id == goal.id {
                return reconstruct(cameFrom: cameFrom, from: start.id, to: goal.id,
                                   cost: gScore[goal.id] ?? 0)
            }

            // ── Expand neighbours ─────────────────────────────────────────────
            for edge in graph.adjacency[current.id] ?? [] {

                // Accessibility gate: skip stair-only edges when required.
                if accessibilityRequired && !edge.isWheelchairAccessible { continue }
                if closedIDs.contains(edge.toID) { continue }

                let tentativeG = (gScore[current.id] ?? .infinity) + edge.weight
                guard tentativeG < (gScore[edge.toID] ?? .infinity) else { continue }

                cameFrom[edge.toID] = current.id
                gScore[edge.toID]   = tentativeG

                if let neighbour = graph.nodes[edge.toID] {
                    open.append((edge.toID, tentativeG + heuristic(neighbour, goal)))
                }
            }
        }

        return nil
    }

    // MARK: Helpers

    /// UV Euclidean distance — an admissible, consistent heuristic provided edge
    /// weights are also UV distances (never overestimates the true cost).
    private func heuristic(_ a: NavNode, _ b: NavNode) -> Double {
        a.uv.navDistance(to: b.uv)
    }

    /// Walks `cameFrom` backwards from goal to start and reverses the result.
    private func reconstruct(cameFrom: [String: String],
                             from startID: String,
                             to goalID: String,
                             cost: Double) -> PathResult? {
        var path: [NavNode] = []
        var current = goalID

        while true {
            guard let node = graph.nodes[current] else { return nil }
            path.append(node)
            if current == startID { break }
            guard let prev = cameFrom[current] else { return nil }
            current = prev
        }

        return PathResult(nodes: path.reversed(), totalCost: cost)
    }
}

// MARK: - CGPoint UV helpers (file-private)

private extension CGPoint {
    /// Euclidean distance in UV space.  Both axes are in [0, 1] so this is
    /// scale-independent and consistent with the A* heuristic.
    func navDistance(to other: CGPoint) -> Double {
        let dx = Double(x - other.x)
        let dy = Double(y - other.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
