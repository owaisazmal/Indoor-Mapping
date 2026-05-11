import SwiftUI
import MapKit

struct IndoorMapView: UIViewRepresentable {
    var floorPlanImage: UIImage
    
    // The geographic coordinates pinning the Top-Left and Bottom-Right corners of the image.
    var bounds: [CLLocationCoordinate2D]
    
    // An optional route to draw on the map
    var route: MKPolyline?
    
    // Controls the map's tracking behavior (following the user)
    @Binding var trackingMode: MKUserTrackingMode
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Standard Map settings
        mapView.mapType = .standard
        mapView.showsUserLocation = true // Displays the blue dot
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.userTrackingMode = trackingMode
        
        // 1. Calculate the map points for the bounding box
        let p1 = MKMapPoint(bounds[0]) // Top-Left
        let p2 = MKMapPoint(bounds[1]) // Bottom-Right
        
        // 2. Create the MapRect that will contain the image
        let mapRect = MKMapRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p1.x - p2.x),
            height: abs(p1.y - p2.y)
        )
        
        // 3. Create and add the overlay
        let overlay = IndoorMapOverlay(image: floorPlanImage, rect: mapRect)
        mapView.addOverlay(overlay)
        
        // 4. Set the initial camera to look at the floor plan
        // Only set region if we aren't tracking the user
        if trackingMode == .none {
            let region = MKCoordinateRegion(mapRect)
            mapView.setRegion(region, animated: false)
        }
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Sync Tracking Mode
        if uiView.userTrackingMode != trackingMode {
            uiView.setUserTrackingMode(trackingMode, animated: true)
        }
        
        // Find existing polylines
        let existingPolylines = uiView.overlays.compactMap { $0 as? MKPolyline }
        
        // If the route changed, update the overlay
        if let newRoute = route {
            if !existingPolylines.contains(where: { $0 === newRoute }) {
                uiView.removeOverlays(existingPolylines)
                uiView.addOverlay(newRoute)
            }
        } else {
            uiView.removeOverlays(existingPolylines)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: IndoorMapView
        
        init(_ parent: IndoorMapView) {
            self.parent = parent
        }
        
        // Keep the SwiftUI state in sync when the user pans the map manually
        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            DispatchQueue.main.async {
                self.parent.trackingMode = mode
            }
        }
        
        // Instructs MapKit on how to render our custom IndoorMapOverlay
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let indoorOverlay = overlay as? IndoorMapOverlay {
                return IndoorMapOverlayRenderer(overlay: indoorOverlay, overlayImage: indoorOverlay.image)
            }
            
            // Standard fallback for other overlays like navigation routes (MKPolyline)
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 5
                return renderer
            }
            
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
