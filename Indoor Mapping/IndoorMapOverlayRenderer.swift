import MapKit

/// A custom renderer that draws the floor plan image onto the map tiles with dynamic rotation and scaling.
class IndoorMapOverlayRenderer: MKOverlayRenderer {
    var overlayImage: UIImage
    
    init(overlay: MKOverlay, overlayImage: UIImage) {
        self.overlayImage = overlayImage
        super.init(overlay: overlay)
    }
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let imageReference = overlayImage.cgImage,
              let indoorOverlay = overlay as? IndoorMapOverlay else { return }
        
        // 1. Find the center in MapKit MapPoints
        let centerMapPoint = MKMapPoint(indoorOverlay.coordinate)
        
        // 2. Convert meters to MapPoints at this specific latitude (since MapPoints distort near the poles)
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(indoorOverlay.coordinate.latitude)
        let widthInPoints = indoorOverlay.widthMeters * pointsPerMeter
        let heightInPoints = indoorOverlay.heightMeters * pointsPerMeter
        
        let rect = CGRect(x: centerMapPoint.x - widthInPoints / 2,
                          y: centerMapPoint.y - heightInPoints / 2,
                          width: widthInPoints,
                          height: heightInPoints)
        
        // 3. Setup drawing context
        context.saveGState()
        
        // 4. Apply Rotation around the center coordinate
        context.translateBy(x: centerMapPoint.x, y: centerMapPoint.y)
        let rotationRadians = indoorOverlay.rotationDegrees * .pi / 180.0
        context.rotate(by: CGFloat(rotationRadians))
        context.translateBy(x: -centerMapPoint.x, y: -centerMapPoint.y)
        
        // 5. MapKit coordinate systems are flipped vertically relative to standard CoreGraphics.
        context.translateBy(x: 0.0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1.0, y: -1.0)
        
        // 6. Apply Opacity
        context.setAlpha(indoorOverlay.alpha)
        
        // 7. Draw the floor plan
        context.draw(imageReference, in: rect)
        
        context.restoreGState()
    }
}
