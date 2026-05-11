import SwiftUI
import RoomPlan
import RealityKit
import ARKit

/// MappingMode View: Utilizes RoomCaptureSession to scan the environment
/// Exports the mapped USDZ/JSON to be processed into a traversable NavMesh.
struct MappingView: UIViewRepresentable {
    
    func makeUIView(context: Context) -> RoomCaptureView {
        let roomCaptureView = RoomCaptureView(frame: .zero)
        
        // Setup capture session delegate
        roomCaptureView.captureSession.delegate = context.coordinator
        
        // Setup ARSession configuration to align with gravity and heading
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading // Important for anchorless absolute heading
        roomCaptureView.captureSession.arSession.run(config)
        
        return roomCaptureView
    }
    
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // Handle Start/Stop state externally via bindings if needed
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, RoomCaptureSessionDelegate {
        var parent: MappingView
        
        init(_ parent: MappingView) {
            self.parent = parent
        }
        
        func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
            // Real-time updates of walls, doors, windows, objects
            // Useful for showing scanning progress to the user.
        }
        
        func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
            if let error = error {
                print("Capture Session Error: \(error.localizedDescription)")
                return
            }
            
            // Process data with RoomBuilder to get CapturedRoom and export it
            Task {
                let builder = RoomBuilder(options: [.beautifyObjects])
                do {
                    let room = try await builder.capturedRoom(from: data)
                    self.exportRoomData(room)
                } catch {
                    print("RoomBuilder failed: \(error)")
                }
            }
        }
        
        private func exportRoomData(_ room: CapturedRoom) {
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScannedMap.usdz")
                try room.export(to: url)
                print("Successfully exported structural map to \(url)")
                
                // At this stage, the USDZ or JSON property list is sent to a backend
                // or a local Python script (via local execution) to parse bounding boxes
                // and generate the A* MapNode graph.
            } catch {
                print("Failed to export room data: \(error)")
            }
        }
    }
}
