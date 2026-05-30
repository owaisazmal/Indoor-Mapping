import Foundation
import CoreLocation
import CoreMotion
import Combine

// MARK: - Location Manager
// Single responsibility: deliver smoothed GPS position and heading updates.
// Building-bounds clamping is kept here because it directly transforms the
// coordinates before publishing — it is part of the "deliver position" contract.

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager         = CLLocationManager()
    private let activityManager = CMMotionActivityManager()

    @Published var userLocation: CLLocation?
    @Published var userHeading:  CLLocationDirection = -1
    @Published var authorizationStatus: CLAuthorizationStatus

    /// Set after the user saves alignment to clamp the dot inside the building.
    var buildingBounds: BuildingBounds?

    private var smoothedCoord:    CLLocationCoordinate2D?
    private var motionIsStationary = true

    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate        = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter  = kCLDistanceFilterNone
        manager.headingFilter   = 2

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let a = activity else { return }
                self?.motionIsStationary = a.stationary
            }
        }
    }

    func requestPermission() { manager.requestWhenInUseAuthorization() }

    func startUpdating() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        activityManager.stopActivityUpdates()
    }

    // MARK: - Authorization

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse ||
           authorizationStatus == .authorizedAlways {
            startUpdating()
        }
    }

    // MARK: - Location updates

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let raw = locations.last,
              raw.horizontalAccuracy > 0,
              raw.horizontalAccuracy < 20
        else { return }

        let speedSaysMoving = raw.speed >= 0 && raw.speed > 0.4
        let moving          = !motionIsStationary || speedSaysMoving
        let alpha:   Double = moving ? 0.30 : 0.05
        let deadBand:Double = moving ? 1.5  : 4.0

        let newCoord: CLLocationCoordinate2D
        if let prev = smoothedCoord {
            let candidate = CLLocationCoordinate2D(
                latitude:  prev.latitude  + alpha * (raw.coordinate.latitude  - prev.latitude),
                longitude: prev.longitude + alpha * (raw.coordinate.longitude - prev.longitude)
            )
            let delta = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                            .distance(from: CLLocation(latitude: prev.latitude, longitude: prev.longitude))
            newCoord = delta > deadBand ? candidate : prev
        } else {
            newCoord = raw.coordinate
        }
        smoothedCoord = newCoord

        let final = clamp(newCoord)
        userLocation = CLLocation(
            coordinate:         final,
            altitude:           raw.altitude,
            horizontalAccuracy: raw.horizontalAccuracy,
            verticalAccuracy:   raw.verticalAccuracy,
            course:             raw.course,
            speed:              raw.speed,
            timestamp:          raw.timestamp
        )
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        userHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    // MARK: - Building-bounds clamping

    private func clamp(_ coord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard let b = buildingBounds else { return coord }

        let mPerLat = 111_000.0
        let mPerLon = 111_000.0 * cos(b.center.latitude * .pi / 180)

        let east  = (coord.longitude - b.center.longitude) * mPerLon
        let north = (coord.latitude  - b.center.latitude)  * mPerLat

        let a = b.rotationDegrees * .pi / 180
        let ca = cos(a), sa = sin(a)
        let lx =  east * ca - north * sa
        let ly =  east * sa + north * ca

        let margin    = 2.0
        let clampedLx = max(-b.widthMeters  / 2 - margin, min(b.widthMeters  / 2 + margin, lx))
        let clampedLy = max(-b.heightMeters / 2 - margin, min(b.heightMeters / 2 + margin, ly))

        guard clampedLx != lx || clampedLy != ly else { return coord }

        let clampedEast  =  clampedLx * ca + clampedLy * sa
        let clampedNorth = -clampedLx * sa + clampedLy * ca

        return CLLocationCoordinate2D(
            latitude:  b.center.latitude  + clampedNorth / mPerLat,
            longitude: b.center.longitude + clampedEast  / mPerLon
        )
    }
}
