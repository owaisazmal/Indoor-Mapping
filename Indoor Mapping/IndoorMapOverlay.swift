import MapKit

/// A custom overlay to hold the floor plan image and its geographic bounds.
class IndoorMapOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D
    var boundingMapRect: MKMapRect
    var image: UIImage
    
    init(image: UIImage, rect: MKMapRect) {
        self.image = image
        self.boundingMapRect = rect
        // The center coordinate of the overlay
        self.coordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
    }
}
