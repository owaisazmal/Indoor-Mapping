import SwiftUI
import MapKit
import CoreLocation

// MARK: - Overlay subclasses

class BorderRoutePolyline: MKPolyline {}
class FillRoutePolyline:   MKPolyline {}
class BuildingBoundaryPolygon: MKPolygon {}

// MARK: - Custom user-location annotation
// @objc dynamic makes `coordinate` KVO-observable so MapKit
// smoothly repositions the pin when we write a new value.
class UserLocationAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D = .init()) { coordinate = c }
}

// MARK: - Google Maps–style dot view

class GoogleStyleUserDot: MKAnnotationView {

    private let canvasSize:    CGFloat = 96
    private let dotRadius:     CGFloat = 9
    private let ringWidth:     CGFloat = 3
    private let coneRadius:    CGFloat = 38
    private let coneHalfAngle: CGFloat = .pi / 7

    private let coneLayer   = CAShapeLayer()
    private let shadowLayer = CAShapeLayer()
    private let dotLayer    = CAShapeLayer()

    var heading: CLLocationDirection? { didSet { updateCone() } }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        centerOffset = .zero
        isOpaque = false
        backgroundColor = .clear
        let c = CGPoint(x: canvasSize / 2, y: canvasSize / 2)

        coneLayer.frame = bounds
        coneLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.18).cgColor
        layer.addSublayer(coneLayer)

        let shadowPath = UIBezierPath(arcCenter: c, radius: dotRadius + ringWidth,
                                     startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        shadowLayer.path = shadowPath
        shadowLayer.fillColor = UIColor.white.cgColor
        shadowLayer.shadowColor = UIColor.black.cgColor
        shadowLayer.shadowOpacity = 0.22
        shadowLayer.shadowRadius = 5
        shadowLayer.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(shadowLayer)

        let dotPath = UIBezierPath(arcCenter: c, radius: dotRadius,
                                  startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        dotLayer.path = dotPath
        dotLayer.fillColor = UIColor(red: 0.26, green: 0.58, blue: 0.97, alpha: 1).cgColor
        layer.addSublayer(dotLayer)
        updateCone()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateCone() {
        guard let h = heading else { coneLayer.path = nil; return }
        let c = CGPoint(x: canvasSize / 2, y: canvasSize / 2)
        let angle = CGFloat(h) * .pi / 180 - .pi / 2
        let p = UIBezierPath()
        p.move(to: c)
        p.addArc(withCenter: c, radius: coneRadius,
                 startAngle: angle - coneHalfAngle,
                 endAngle: angle + coneHalfAngle, clockwise: true)
        p.close()
        coneLayer.path = p.cgPath
    }
}

// MARK: - IndoorMapView

struct IndoorMapView: UIViewRepresentable {

    var floorPlanImage:       UIImage
    var overlayCenter:        CLLocationCoordinate2D
    var overlayWidthMeters:   Double
    var overlayHeightMeters:  Double
    var overlayRotationDegrees: Double
    var overlayAlpha:         Double
    var route:                MKPolyline?
    var userLocation:         CLLocation?
    var userHeading:          CLLocationDirection
    var showBuildingBoundary: Bool

    var isEditing: Bool

    @Binding var trackingMode:      MKUserTrackingMode
    @Binding var currentMapCenter:  CLLocationCoordinate2D
    @Binding var currentMapSpan:    MKCoordinateSpan

    // MARK: UIViewRepresentable

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsUserLocation = false   // Managed via our custom annotation
        mapView.showsCompass = true
        mapView.showsScale = true

        let overlay = makeFloorPlanOverlay()
        context.coordinator.floorPlanOverlay = overlay
        mapView.addOverlay(overlay)
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        let coord = context.coordinator

        // Disable map interaction during alignment so finger gestures reach SwiftUI
        uiView.isScrollEnabled  = !isEditing
        uiView.isZoomEnabled    = !isEditing
        uiView.isRotateEnabled  = !isEditing
        uiView.isPitchEnabled   = !isEditing

        // ── User location annotation ──────────────────────────────────────────
        if let loc = userLocation {
            if let ann = coord.userLocationAnnotation {
                // KVO fires → MapKit glides the dot to the new position
                ann.coordinate = loc.coordinate
            } else {
                let ann = UserLocationAnnotation(loc.coordinate)
                coord.userLocationAnnotation = ann
                uiView.addAnnotation(ann)
            }
            if let ann = coord.userLocationAnnotation,
               let dot = uiView.view(for: ann) as? GoogleStyleUserDot {
                dot.heading = userHeading >= 0 ? userHeading : nil
            }
        } else if let ann = coord.userLocationAnnotation {
            uiView.removeAnnotation(ann)
            coord.userLocationAnnotation = nil
        }

        // ── Camera tracking (manual, since showsUserLocation = false) ─────────
        if trackingMode != coord.prevTrackingMode {
            // Mode just changed — snap to user immediately
            coord.prevTrackingMode = trackingMode
            if trackingMode != .none, let loc = userLocation {
                centerCamera(on: loc, in: uiView, heading: userHeading)
            }
        } else if trackingMode != .none, let loc = userLocation {
            // Keep following — only move if user has drifted > ~5 m from centre
            let mc = uiView.centerCoordinate
            if abs(mc.latitude - loc.coordinate.latitude)   > 0.00005 ||
               abs(mc.longitude - loc.coordinate.longitude) > 0.00005 {
                centerCamera(on: loc, in: uiView, heading: userHeading)
            }
        }

        // ── Floor plan overlay — update in-place to avoid flicker on sliders ──
        if let current = coord.floorPlanOverlay {
            if current.image !== floorPlanImage {
                uiView.removeOverlay(current)
                let new = makeFloorPlanOverlay()
                coord.floorPlanOverlay = new
                uiView.addOverlay(new)
            } else {
                current.coordinate     = overlayCenter
                current.widthMeters    = overlayWidthMeters
                current.heightMeters   = overlayHeightMeters
                current.rotationDegrees = overlayRotationDegrees
                current.alpha          = overlayAlpha
                coord.floorPlanRenderer?.setNeedsDisplay()
            }
        }

        // ── Building boundary polygon ─────────────────────────────────────────
        let existingBoundaries = uiView.overlays.compactMap { $0 as? BuildingBoundaryPolygon }
        if showBuildingBoundary {
            let p = coord.lastBoundaryParams
            let paramsChanged = p == nil
                || p!.0 != overlayCenter.latitude  || p!.1 != overlayCenter.longitude
                || p!.2 != overlayWidthMeters       || p!.3 != overlayHeightMeters
                || p!.4 != overlayRotationDegrees

            if paramsChanged {
                uiView.removeOverlays(existingBoundaries)
                let poly = buildingPolygon(center: overlayCenter,
                                           widthM: overlayWidthMeters,
                                           heightM: overlayHeightMeters,
                                           rotDeg: overlayRotationDegrees)
                coord.lastBoundaryParams = (overlayCenter.latitude, overlayCenter.longitude,
                                            overlayWidthMeters, overlayHeightMeters, overlayRotationDegrees)
                uiView.addOverlay(poly, level: .aboveRoads)
            }
        } else if !existingBoundaries.isEmpty {
            uiView.removeOverlays(existingBoundaries)
            coord.lastBoundaryParams = nil
        }

        // ── Accuracy circle ───────────────────────────────────────────────────
        if let loc = userLocation, loc.horizontalAccuracy > 0, loc.horizontalAccuracy < 1000 {
            let needsUpdate = coord.currentAccuracyCircle.map {
                abs($0.coordinate.latitude  - loc.coordinate.latitude)  > 0.00002 ||
                abs($0.coordinate.longitude - loc.coordinate.longitude) > 0.00002 ||
                abs($0.radius - loc.horizontalAccuracy) > 3
            } ?? true
            if needsUpdate {
                if let old = coord.currentAccuracyCircle { uiView.removeOverlay(old) }
                let circle = MKCircle(center: loc.coordinate, radius: loc.horizontalAccuracy)
                coord.currentAccuracyCircle = circle
                uiView.addOverlay(circle, level: .aboveRoads)
            }
        } else if let old = coord.currentAccuracyCircle {
            uiView.removeOverlay(old)
            coord.currentAccuracyCircle = nil
        }

        // ── Route (border + fill) ─────────────────────────────────────────────
        if let newRoute = route {
            if coord.currentRoute !== newRoute {
                uiView.removeOverlays(uiView.overlays.compactMap { $0 as? BorderRoutePolyline })
                uiView.removeOverlays(uiView.overlays.compactMap { $0 as? FillRoutePolyline })
                coord.currentRoute = newRoute
                var coords = [CLLocationCoordinate2D](repeating: .init(), count: newRoute.pointCount)
                newRoute.getCoordinates(&coords, range: NSRange(location: 0, length: newRoute.pointCount))
                uiView.addOverlay(BorderRoutePolyline(coordinates: &coords, count: coords.count))
                uiView.addOverlay(FillRoutePolyline(coordinates: &coords, count: coords.count))
            }
        } else if coord.currentRoute != nil {
            uiView.removeOverlays(uiView.overlays.compactMap { $0 as? BorderRoutePolyline })
            uiView.removeOverlays(uiView.overlays.compactMap { $0 as? FillRoutePolyline })
            coord.currentRoute = nil
        }
    }

    // MARK: Helpers

    private func centerCamera(on loc: CLLocation, in mapView: MKMapView, heading: CLLocationDirection) {
        if trackingMode == .followWithHeading && heading >= 0 {
            let cam = MKMapCamera(lookingAtCenter: loc.coordinate,
                                  fromDistance: mapView.camera.altitude,
                                  pitch: 0, heading: heading)
            mapView.setCamera(cam, animated: true)
        } else {
            mapView.setCenter(loc.coordinate, animated: true)
        }
    }

    private func makeFloorPlanOverlay() -> IndoorMapOverlay {
        IndoorMapOverlay(image: floorPlanImage, coordinate: overlayCenter,
                         widthMeters: overlayWidthMeters, heightMeters: overlayHeightMeters,
                         rotationDegrees: overlayRotationDegrees, alpha: overlayAlpha)
    }

    /// Builds a rotated rectangle polygon that outlines the placed floor plan.
    /// Rotation convention matches IndoorMapOverlayRenderer (clockwise-visual).
    private func buildingPolygon(center: CLLocationCoordinate2D,
                                  widthM: Double, heightM: Double,
                                  rotDeg: Double) -> BuildingBoundaryPolygon {
        let mPerLat = 111_000.0
        let mPerLon = 111_000.0 * cos(center.latitude * .pi / 180)
        let hw = widthM / 2, hh = heightM / 2
        let a = rotDeg * .pi / 180.0
        let ca = cos(a), sa = sin(a)

        // For each local corner (lx, ly):
        //   east  (m) = lx*ca + ly*sa
        //   north (m) = –lx*sa + ly*ca
        func corner(_ lx: Double, _ ly: Double) -> CLLocationCoordinate2D {
            let east  =  lx * ca + ly * sa
            let north = -lx * sa + ly * ca
            return CLLocationCoordinate2D(latitude:  center.latitude  + north / mPerLat,
                                          longitude: center.longitude + east  / mPerLon)
        }

        var pts = [corner(-hw, -hh), corner(hw, -hh), corner(hw, hh), corner(-hw, hh)]
        return BuildingBoundaryPolygon(coordinates: &pts, count: 4)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Coordinator

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: IndoorMapView

        var userLocationAnnotation: UserLocationAnnotation?
        var floorPlanOverlay:       IndoorMapOverlay?
        weak var floorPlanRenderer: IndoorMapOverlayRenderer?
        var currentAccuracyCircle:  MKCircle?
        weak var currentRoute:      MKPolyline?
        var prevTrackingMode:       MKUserTrackingMode = .none
        var lastBoundaryParams:     (Double, Double, Double, Double, Double)?

        init(_ parent: IndoorMapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            DispatchQueue.main.async {
                self.parent.currentMapCenter = mapView.centerCoordinate
                self.parent.currentMapSpan   = mapView.region.span
            }
            if !animated, parent.trackingMode != .none {
                DispatchQueue.main.async { self.parent.trackingMode = .none }
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            DispatchQueue.main.async {
                self.parent.currentMapCenter = mapView.centerCoordinate
                self.parent.currentMapSpan   = mapView.region.span
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is UserLocationAnnotation else { return nil }
            let id = "GoogleStyleUserDot"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? GoogleStyleUserDot)
                ?? GoogleStyleUserDot(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.heading = parent.userHeading >= 0 ? parent.userHeading : nil
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let floor = overlay as? IndoorMapOverlay {
                let r = IndoorMapOverlayRenderer(overlay: floor, overlayImage: floor.image)
                floorPlanRenderer = r
                return r
            }
            if let boundary = overlay as? BuildingBoundaryPolygon {
                let r = MKPolygonRenderer(polygon: boundary)
                r.strokeColor = UIColor.systemIndigo.withAlphaComponent(0.85)
                r.fillColor   = UIColor.systemIndigo.withAlphaComponent(0.06)
                r.lineWidth   = 2.5
                r.lineDashPattern = [8, 6]
                return r
            }
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                r.fillColor   = UIColor.systemBlue.withAlphaComponent(0.10)
                r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.28)
                r.lineWidth   = 1
                return r
            }
            if let border = overlay as? BorderRoutePolyline {
                let r = MKPolylineRenderer(polyline: border)
                r.strokeColor = .white; r.lineWidth = 11
                r.lineCap = .round;     r.lineJoin  = .round
                return r
            }
            if let fill = overlay as? FillRoutePolyline {
                let r = MKPolylineRenderer(polyline: fill)
                r.strokeColor = UIColor(red: 0.26, green: 0.58, blue: 0.97, alpha: 1)
                r.lineWidth = 6; r.lineCap = .round; r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
