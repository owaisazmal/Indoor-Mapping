import MapKit

/// A custom renderer that draws the floor plan image onto the map tiles.
class IndoorMapOverlayRenderer: MKOverlayRenderer {
    var overlayImage: UIImage
    
    init(overlay: MKOverlay, overlayImage: UIImage) {
        self.overlayImage = overlayImage
        super.init(overlay: overlay)
    }
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let imageReference = overlayImage.cgImage else { return }
        
        let theMapRect = overlay.boundingMapRect
        let theRect = rect(for: theMapRect)
        
        // MapKit drawing contexts are flipped relative to standard CGContexts.
        // We need to flip the coordinate system to draw the image right-side up.
        context.scaleBy(x: 1.0, y: -1.0)
        context.translateBy(x: 0.0, y: -theRect.size.height)
        
        // Optionally, apply an alpha blend so the user can slightly see the underlying map
        context.setAlpha(0.85)
        
        context.draw(imageReference, in: theRect)
    }
}
