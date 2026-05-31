import Foundation
import CoreGraphics

// MARK: - JSON schema
//
// The canonical on-disk format for a floor-plan navigation graph.
// Save as <name>.json in the app bundle (e.g. "building_1.json").
//
// {
//   "nodes": [
//     { "id": "ENTRANCE", "name": "Main Entrance", "u": 0.50, "v": 0.90 }
//   ],
//   "edges": [
//     { "from": "ENTRANCE", "to": "ELEVATOR_A", "accessible": true  },
//     { "from": "ENTRANCE", "to": "STAIRS_1",   "accessible": false }
//   ]
// }
//
// The "weight" key is optional on every edge.  When absent the runtime
// auto-computes it as the UV-space Euclidean distance between the two
// endpoints, which keeps the A* heuristic admissible without manual tuning.

struct NavGraphPayload: Codable {

    struct NodeRecord: Codable {
        let id:   String
        let name: String
        /// Horizontal UV position on the floor-plan image (0 = left, 1 = right).
        let u: Double
        /// Vertical UV position on the floor-plan image (0 = top, 1 = bottom).
        let v: Double

        var cgPoint: CGPoint { CGPoint(x: u, y: v) }
    }

    struct EdgeRecord: Codable {
        let from:       String
        let to:         String
        /// When nil the weight is derived from UV distance at load time.
        let weight:     Double?
        let accessible: Bool

        // Allow the key to be absent in JSON (older exports may omit weight).
        private enum CodingKeys: String, CodingKey {
            case from, to, weight, accessible
        }
        init(from: String, to: String, weight: Double?, accessible: Bool) {
            self.from = from; self.to = to
            self.weight = weight; self.accessible = accessible
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            from       = try  c.decode(String.self, forKey: .from)
            to         = try  c.decode(String.self, forKey: .to)
            accessible = try  c.decode(Bool.self,   forKey: .accessible)
            weight     = try? c.decodeIfPresent(Double.self, forKey: .weight) ?? nil
        }
    }

    let nodes: [NodeRecord]
    let edges: [EdgeRecord]

    /// Materialise a `NavGraph` from this payload.
    func buildNavGraph() -> NavGraph {
        let graph = NavGraph()
        for n in nodes {
            graph.addNode(NavNode(id: n.id, name: n.name, uv: n.cgPoint))
        }
        for e in edges {
            graph.addEdge(from: e.from, to: e.to,
                          weight: e.weight,
                          isWheelchairAccessible: e.accessible)
        }
        return graph
    }
}

// MARK: - NavGraphFactory

enum NavGraphFactory {

    // MARK: Load

    /// Loads a `NavGraph` from a JSON file in the given bundle.
    ///
    /// Usage:
    /// ```swift
    /// let graph = NavGraphFactory.load(named: "building_1")
    /// ```
    /// Returns `nil` and prints a diagnostic if the file is missing or malformed.
    @discardableResult
    static func load(named filename: String,
                     in bundle: Bundle = .main) -> NavGraph? {
        guard let url = bundle.url(forResource: filename, withExtension: "json") else {
            print("NavGraphFactory: '\(filename).json' not found in bundle")
            return nil
        }
        do {
            let data    = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(NavGraphPayload.self, from: data)
            let graph      = payload.buildNavGraph()
            let nodeCount  = graph.nodes.count
            let edgeCount  = graph.adjacency.values.reduce(0) { $0 + $1.count } / 2
            print("NavGraphFactory: loaded \(nodeCount) nodes, \(edgeCount) edges from '\(filename).json'")
            return graph
        } catch {
            print("NavGraphFactory: failed to decode '\(filename).json': \(error)")
            return nil
        }
    }

    // MARK: Encode

    /// Converts a `NavGraphPayload` to a pretty-printed JSON string.
    /// Called by `GraphBuilderView` to produce the exportable text.
    static func encode(_ payload: NavGraphPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data   = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{ /* encoding error */ }"
        }
        return string
    }

    /// Convenience: encode an existing runtime `NavGraph` back to JSON.
    /// Useful for round-trip verification or exporting a programmatically
    /// built graph.
    static func encode(_ graph: NavGraph) -> String {
        // Reconstruct edge records from the adjacency list.
        // Each undirected edge is stored as two directed entries; we de-duplicate
        // by only emitting the pair where fromID < toID (lexicographic).
        var edgeRecords: [NavGraphPayload.EdgeRecord] = []
        for (fromID, edges) in graph.adjacency {
            for edge in edges where fromID < edge.toID {
                edgeRecords.append(
                    NavGraphPayload.EdgeRecord(from: edge.fromID, to: edge.toID,
                                               weight: edge.weight,
                                               accessible: edge.isWheelchairAccessible))
            }
        }
        let nodeRecords: [NavGraphPayload.NodeRecord] = graph.nodes.values
            .sorted { $0.id < $1.id }
            .map { NavGraphPayload.NodeRecord(id: $0.id, name: $0.name,
                                              u: Double($0.uv.x), v: Double($0.uv.y)) }
        let sortedEdges = edgeRecords.sorted { $0.from < $1.from }
        let payload     = NavGraphPayload(nodes: nodeRecords, edges: sortedEdges)
        return encode(payload)
    }
}
