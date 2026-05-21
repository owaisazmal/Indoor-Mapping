import SwiftUI
import MapKit

struct IndoorMapView: UIViewRepresentable {
    var floorPlanImage: UIImage
    
    // Dynamic Overlay Properties
    var overlayCenter: CLLocationCoordinate2D
    var overlayWidthMeters: Double
    var overlayHeightMeters: Double
    var overlayRotationDegrees: Double
    var overlayAlpha: Double
    
    var route: MKPolyline?
    
    @Binding var trackingMode: MKUserTrackingMode
    @Binding var currentMapCenter: CLLocationCoordinate2D
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Standard Map settings
        mapView.mapType = .standard
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.userTrackingMode = trackingMode
        
        // Initial Overlay
        let overlay = IndoorMapOverlay(image: floorPlanImage, coordinate: overlayCenter, widthMeters: overlayWidthMeters, heightMeters: overlayHeightMeters, rotationDegrees: overlayRotationDegrees, alpha: overlayAlpha)
        mapView.addOverlay(overlay)
        
        // Initial Camera Setup
        let region = MKCoordinateRegion(center: overlayCenter, latitudinalMeters: max(overlayHeightMeters * 2, 200), longitudinalMeters: max(overlayWidthMeters * 2, 200))
        mapView.setRegion(region, animated: false)
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Sync Tracking Mode
        if uiView.userTrackingMode != trackingMode {
            uiView.setUserTrackingMode(trackingMode, animated: true)
        }
        
        // 1. Update the Floor Plan Overlay if properties changed
        let existingOverlays = uiView.overlays.compactMap { $0 as? IndoorMapOverlay }
        if let currentOverlay = existingOverlays.first {
            // Check if any critical property changed that requires a re-draw
            if currentOverlay.coordinate.latitude != overlayCenter.latitude ||
               currentOverlay.coordinate.longitude != overlayCenter.longitude ||
               currentOverlay.widthMeters != overlayWidthMeters ||
               currentOverlay.heightMeters != overlayHeightMeters ||
               currentOverlay.rotationDegrees != overlayRotationDegrees ||
               currentOverlay.alpha != overlayAlpha ||
               currentOverlay.image !== floorPlanImage {
                
                uiView.removeOverlay(currentOverlay)
                
                let newOverlay = IndoorMapOverlay(image: floorPlanImage, coordinate: overlayCenter, widthMeters: overlayWidthMeters, heightMeters: overlayHeightMeters, rotationDegrees: overlayRotationDegrees, alpha: overlayAlpha)
                uiView.addOverlay(newOverlay)
            }
        } else {
            // Re-add if it was missing entirely
            let newOverlay = IndoorMapOverlay(image: floorPlanImage, coordinate: overlayCenter, widthMeters: overlayWidthMeters, heightMeters: overlayHeightMeters, rotationDegrees: overlayRotationDegrees, alpha: overlayAlpha)
            uiView.addOverlay(newOverlay)
        }
        
        // 2. Update Navigational Routes
        let existingPolylines = uiView.overlays.compactMap { $0 as? MKPolyline }
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
        
        // Track the exact center of the screen as the user pans, crucial for alignment
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            DispatchQueue.main.async {
                self.parent.currentMapCenter = mapView.centerCoordinate
            }
        }
        
        // Instructs MapKit on how to render our overlays
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let indoorOverlay = overlay as? IndoorMapOverlay {
                return IndoorMapOverlayRenderer(overlay: indoorOverlay, overlayImage: indoorOverlay.image)
            }
            
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
