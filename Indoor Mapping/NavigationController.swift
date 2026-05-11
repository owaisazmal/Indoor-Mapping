import SwiftUI
import RealityKit
import ARKit

/// The Direction Mode controller. Renders the calculated A* path in AR
/// and dynamically anchors it relative to the ES-EKF filtered position.
struct NavigationController: UIViewRepresentable {
    
    var pathNodes: [MapNode]
    @ObservedObject var sensorFusionEngine: SensorFusionEngine
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        arView.session.run(config)
        arView.session.delegate = context.coordinator
        
        // Start the EKF
        sensorFusionEngine.start()
        
        // Draw the initial path
        context.coordinator.drawPath(in: arView, nodes: pathNodes)
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Update RealityKit entities based on updated pathNodes if routing changes
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, ARSessionDelegate {
        var parent: NavigationController
        var pathAnchor: AnchorEntity?
        
        init(_ parent: NavigationController) {
            self.parent = parent
        }
        
        // Feeds the ARKit VIO data into the ES-EKF Update Step
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let cameraTransform = frame.camera.transform // simd_float4x4
            parent.sensorFusionEngine.update(arkitTransform: cameraTransform)
            
            // Optionally, we can dynamically offset the pathAnchor here
            // based on the drift correction determined by the EKF.
            // drift = cameraTransform.position - EKF.position
        }
        
        /// Projects the A* nodes into the AR scene
        func drawPath(in arView: ARView, nodes: [MapNode]) {
            guard nodes.count > 1 else { return }
            
            let anchor = AnchorEntity(world: [0,0,0]) // Absolute anchor (anchorless logic)
            self.pathAnchor = anchor
            arView.scene.addAnchor(anchor)
            
            // Draw waypoints
            for node in nodes {
                let mesh = MeshResource.generateSphere(radius: 0.1)
                let material = SimpleMaterial(color: .blue, isMetallic: false)
                let model = ModelEntity(mesh: mesh, materials: [material])
                
                model.position = node.position
                anchor.addChild(model)
            }
            
            // Draw lines between nodes
            for i in 0..<(nodes.count - 1) {
                let startNode = nodes[i]
                let endNode = nodes[i+1]
                
                let midPoint = (startNode.position + endNode.position) / 2
                let distance = simd_distance(startNode.position, endNode.position)
                
                let lineMesh = MeshResource.generateBox(size: [0.05, 0.05, distance])
                let lineMaterial = SimpleMaterial(color: .cyan.withAlphaComponent(0.6), isMetallic: false)
                let lineModel = ModelEntity(mesh: lineMesh, materials: [lineMaterial])
                
                lineModel.position = midPoint
                lineModel.look(at: endNode.position, from: midPoint, relativeTo: nil)
                
                anchor.addChild(lineModel)
            }
        }
    }
}
