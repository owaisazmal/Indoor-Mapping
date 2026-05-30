import SwiftUI
import Combine
import CoreLocation

/// Observable state for the floor plan overlay — position, size, rotation, opacity, and edit mode.
@MainActor
final class FloorPlanState: ObservableObject {

    @Published var image: UIImage = {
        let config = UIImage.SymbolConfiguration(pointSize: 500)
        return UIImage(systemName: "photo.artframe", withConfiguration: config) ?? UIImage()
    }()

    @Published var center:           CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 37.334800, longitude: -122.009000)
    @Published var widthMeters:      Double = 150
    @Published var heightMeters:     Double = 150
    @Published var rotationDegrees:  Double = 0
    @Published var alpha:            Double = 1.0
    @Published var isEditing:        Bool   = false
    @Published var hasCustomImage:   Bool   = false
    @Published var isLoadingImage:   Bool   = false

    // MARK: - Mutating actions

    func load(_ uiImage: UIImage, anchoredAt mapCenter: CLLocationCoordinate2D) {
        image           = uiImage
        heightMeters    = widthMeters * aspectRatio(of: uiImage)
        center          = mapCenter
        alpha           = 0.6
        hasCustomImage  = true
        isLoadingImage  = false
        withAnimation(.spring()) { isEditing = true }
    }

    func cancelLoading() {
        isLoadingImage = false
    }

    func snap(to mapCenter: CLLocationCoordinate2D) {
        withAnimation(.spring()) { center = mapCenter }
    }

    func setWidth(_ w: Double) {
        widthMeters  = w
        heightMeters = w * aspectRatio(of: image)
    }

    func moveCenter(latDelta: Double, lonDelta: Double) {
        center = CLLocationCoordinate2D(latitude:  center.latitude  + latDelta,
                                        longitude: center.longitude + lonDelta)
    }

    func applyScale(_ factor: CGFloat) {
        setWidth(max(10, widthMeters * Double(factor)))
    }

    func applyRotation(deltaDegrees: Double) {
        rotationDegrees += deltaDegrees
    }

    func finishEditing() {
        withAnimation(.spring()) {
            alpha     = 1.0
            isEditing = false
        }
    }

    // MARK: - Helpers

    private func aspectRatio(of img: UIImage) -> Double {
        guard img.size.width > 0 else { return 1 }
        return img.size.height / img.size.width
    }
}
