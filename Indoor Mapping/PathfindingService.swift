import Foundation
import simd

/// Represents a traversable point generated from the RoomPlan scan.
struct MapNode: Identifiable, Hashable {
    let id: UUID
    var position: simd_float3 // [x, y, z] in the ARKit map coordinate space
    var connectedNodeIDs: [UUID]
}

/// Anchor-free pathfinding using A* over the generated MapNode graph.
class PathfindingService {
    
    var nodes: [UUID: MapNode] = [:]
    
    init(nodes: [MapNode]) {
        for node in nodes {
            self.nodes[node.id] = node
        }
    }
    
    /// Finds the shortest path using A*
    func findPath(from startID: UUID, to targetID: UUID) -> [MapNode]? {
        guard let startNode = nodes[startID], let targetNode = nodes[targetID] else { return nil }
        
        var openSet = Set([startID])
        var cameFrom: [UUID: UUID] = [:]
        
        // Cost from start along best known path
        var gScore: [UUID: Float] = [startID: 0]
        
        // Estimated total cost from start to goal through y
        var fScore: [UUID: Float] = [startID: heuristicCostEstimate(from: startNode, to: targetNode)]
        
        while !openSet.isEmpty {
            // Find node in openSet with lowest fScore
            let currentID = openSet.min { fScore[$0] ?? .infinity < fScore[$1] ?? .infinity }!
            
            if currentID == targetID {
                return reconstructPath(cameFrom: cameFrom, currentID: currentID)
            }
            
            openSet.remove(currentID)
            let currentNode = nodes[currentID]!
            
            for neighborID in currentNode.connectedNodeIDs {
                guard let neighborNode = nodes[neighborID] else { continue }
                
                let tentativeGScore = (gScore[currentID] ?? .infinity) + distance(from: currentNode, to: neighborNode)
                
                if tentativeGScore < (gScore[neighborID] ?? .infinity) {
                    cameFrom[neighborID] = currentID
                    gScore[neighborID] = tentativeGScore
                    fScore[neighborID] = tentativeGScore + heuristicCostEstimate(from: neighborNode, to: targetNode)
                    
                    if !openSet.contains(neighborID) {
                        openSet.insert(neighborID)
                    }
                }
            }
        }
        
        return nil // No path found
    }
    
    // Euclidean distance heuristic
    private func heuristicCostEstimate(from node1: MapNode, to node2: MapNode) -> Float {
        return simd_distance(node1.position, node2.position)
    }
    
    private func distance(from node1: MapNode, to node2: MapNode) -> Float {
        return simd_distance(node1.position, node2.position)
    }
    
    private func reconstructPath(cameFrom: [UUID: UUID], currentID: UUID) -> [MapNode] {
        var totalPath = [nodes[currentID]!]
        var current = currentID
        while let prev = cameFrom[current] {
            totalPath.append(nodes[prev]!)
            current = prev
        }
        return totalPath.reversed()
    }
}
