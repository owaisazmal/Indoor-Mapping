import SwiftUI
import UIKit
import CoreLocation

// MARK: - AR Navigation destination
// Produced at session-start by converting persisted NavNodes + floor dimensions.
// worldX / worldZ are approximate (UV → metres from centre); used only for the
// distance readout in the AR HUD.

struct NavDestination: Identifiable {
    let id:      Int
    let name:    String
    let icon:    String
    let mapUV:   CGPoint
    let worldX:  Float
    let worldZ:  Float
    let uiColor: UIColor
    var color:   Color { Color(uiColor) }
}
