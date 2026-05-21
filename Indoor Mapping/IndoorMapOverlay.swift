import MapKit

/// A dynamic custom overlay to hold the floor plan image.
class IndoorMapOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D
    var image: UIImage
    
    // Physical dimensions
    var widthMeters: Double
    var heightMeters: Double
    var rotationDegrees: Double
    var alpha: Double
    
    // We return a massive bounding rect so MapKit always asks our renderer to draw it,
    // allowing the image to remain visible while the user dynamically rotates or scales it.
    var boundingMapRect: MKMapRect {
        return MKMapRect.world
    }
    
    init(image: UIImage, coordinate: CLLocationCoordinate2D, widthMeters: Double, heightMeters: Double, rotationDegrees: Double, alpha: Double) {
        self.image = image
        self.coordinate = coordinate
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.rotationDegrees = rotationDegrees
        self.alpha = alpha
    }
}
