import Foundation
import CoreLocation
import CoreMotion
import Combine

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager        = CLLocationManager()
    private let activityManager = CMMotionActivityManager()

    @Published var userLocation: CLLocation?
    @Published var userHeading: CLLocationDirection = -1
    @Published var authorizationStatus: CLAuthorizationStatus

    // Set after the user aligns the floor plan to clamp the dot inside the building.
    struct BuildingBounds {
        var center: CLLocationCoordinate2D
        var widthMeters: Double
        var heightMeters: Double
        var rotationDegrees: Double
    }
    var buildingBounds: BuildingBounds?

    // ── Smoothing state ───────────────────────────────────────────────────────
    private var smoothedCoord: CLLocationCoordinate2D?
    private var motionIsStationary = true   // from CMMotionActivityManager

    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter  = kCLDistanceFilterNone
        manager.headingFilter   = 2   // only fire on ≥ 2° changes

        // CMMotionActivityManager gives us reliable stationary detection using
        // the accelerometer — far more accurate than GPS speed indoors.
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
              raw.horizontalAccuracy < 20   // indoor GPS worse than 20 m is useless
        else { return }

        // Use GPS speed as a second, faster movement signal (CMMotionActivity
        // can lag 3-5 s after starting to walk).
        let speedSaysMoving = raw.speed >= 0 && raw.speed > 0.4  // > 0.4 m/s ≈ slow walk

        // Combine both signals — only unfreeze if at least one says we're moving
        let moving = !motionIsStationary || speedSaysMoving

        // Smoothing strength:
        //   stationary → α = 0.05  (barely drifts; absorbs GPS bounce)
        //   walking    → α = 0.30  (responsive but still smooth)
        let alpha: Double    = moving ? 0.30 : 0.05

        // Dead band: reject position changes smaller than this (metres).
        // Stationary indoors: GPS can jump 10–30 m; 4 m dead band freezes the dot.
        // Walking: 1.5 m lets normal step-by-step movement through.
        let deadBand: Double = moving ? 1.5 : 4.0

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
            newCoord = raw.coordinate  // first fix — accept immediately
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

        // Rotate to building-local frame (inverse of the visual clockwise rotation)
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
