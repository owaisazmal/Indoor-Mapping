import SwiftUI
import UIKit
import CoreLocation

// MARK: - Mapping models

struct MappingResult {
    let pois: [MappedPOI]
}

struct MappedPOI: Identifiable {
    let id: UUID
    var name: String
    var icon: String
    /// UV on the floor plan image (0–1, origin top-left).
    let mapUV: CGPoint
    /// AR world position derived from mapUV × floor dimensions.
    let worldX: Float
    let worldZ: Float
    let colorIndex: Int

    init(name: String, icon: String, mapUV: CGPoint,
         worldX: Float, worldZ: Float, colorIndex: Int) {
        id = UUID()
        self.name = name; self.icon = icon; self.mapUV = mapUV
        self.worldX = worldX; self.worldZ = worldZ; self.colorIndex = colorIndex
    }

    func toNavDestination(id: Int) -> NavDestination {
        NavDestination(id: id, name: name, icon: icon, mapUV: mapUV,
                       worldX: worldX, worldZ: worldZ,
                       uiColor: poiUIColors[colorIndex])
    }
}

// MARK: - AR Navigation models

struct NavDestination: Identifiable {
    let id: Int
    let name: String
    let icon: String
    /// UV on the floor plan image (0–1, origin top-left).
    let mapUV: CGPoint
    /// AR world position recorded during mapping.
    let worldX: Float
    let worldZ: Float
    let uiColor: UIColor
    var color: Color { Color(uiColor) }
}

// MARK: - Building bounds (used by LocationManager for GPS clamping)

struct BuildingBounds {
    var center: CLLocationCoordinate2D
    var widthMeters: Double
    var heightMeters: Double
    var rotationDegrees: Double
}
