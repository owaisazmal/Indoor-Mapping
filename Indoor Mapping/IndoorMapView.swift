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

    // Callbacks fired by 2-finger gestures during alignment so the floor plan can be adjusted
    // while 1-finger pan still scrolls the map normally.
    var onMoveFloorPlan:   ((Double, Double) -> Void)? = nil   // latDelta, lonDelta
    var onScaleFloorPlan:  ((CGFloat) -> Void)?        = nil   // incremental scale factor
    var onRotateFloorPlan: ((Double) -> Void)?         = nil   // delta degrees

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

        // Only set a street-level camera when we already have a real location fix.
        // If location is still nil (the common case on launch), leave MapKit's default
        // view — updateUIView will snap to the correct coordinate on the first fix.
        // This prevents the camera jumping to the hardcoded Apple HQ fallback.
        if let coord = userLocation?.coordinate {
            let cam = MKMapCamera(lookingAtCenter: coord, fromDistance: 150, pitch: 0, heading: 0)
            mapView.setCamera(cam, animated: false)
        }

        let overlay = makeFloorPlanOverlay()
        context.coordinator.floorPlanOverlay = overlay
        mapView.addOverlay(overlay)
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        let coord = context.coordinator
        // Keep parent fresh so gesture callbacks always see the latest closures.
        coord.parent = self

        // "Adjust Image" (isEditing = true): lock the map completely so gestures
        // only drive the floor-plan recognisers below, never the underlying map.
        // "Move Map" mode and normal use: map gestures are fully enabled and the
        // floor-plan recognisers are absent, so there is no cross-talk.
        uiView.isScrollEnabled = !isEditing
        uiView.isZoomEnabled   = !isEditing
        uiView.isRotateEnabled = !isEditing
        uiView.isPitchEnabled  = !isEditing

        if isEditing { coord.installFloorPlanGestures(on: uiView) }
        else         { coord.removeFloorPlanGestures(from: uiView) }

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
        //
        // Priority 1 — first-ever fix: snap to street level once, regardless of
        // what tracking mode the button is in.  Also consumes a pending .follow
        // press that arrived before location was available.
        if !coord.hasInitiallyCentered, let loc = userLocation {
            coord.hasInitiallyCentered = true
            centerCamera(on: loc, in: uiView, heading: userHeading, snapToStreetLevel: true)
            if trackingMode == .follow {
                DispatchQueue.main.async { coord.parent.trackingMode = .none }
            }

        // Priority 2 — explicit button press (tracking mode changed).
        // prevTrackingMode is only updated when we successfully act on the change
        // (i.e. when location is available). If location is nil, we leave
        // prevTrackingMode stale so the next updateUIView retries automatically.
        } else if trackingMode != coord.prevTrackingMode, let loc = userLocation {
            coord.prevTrackingMode = trackingMode
            switch trackingMode {
            case .follow:
                // One-shot "Locate Me": snap and zoom to street level once, then
                // immediately release so location updates never re-centre against intent.
                centerCamera(on: loc, in: uiView, heading: userHeading, snapToStreetLevel: true)
                DispatchQueue.main.async { coord.parent.trackingMode = .none }
            case .followWithHeading:
                centerCamera(on: loc, in: uiView, heading: userHeading, snapToStreetLevel: false)
            default:
                break   // .none just clears prevTrackingMode, no camera move needed
            }

        // Priority 3 — continuous follow, only for navigation (.followWithHeading).
        // .follow is always one-shot (handled above) so it never reaches here.
        } else if trackingMode == .followWithHeading, let loc = userLocation {
            let mc = uiView.centerCoordinate
            if abs(mc.latitude  - loc.coordinate.latitude)  > 0.00005 ||
               abs(mc.longitude - loc.coordinate.longitude) > 0.00005 {
                centerCamera(on: loc, in: uiView, heading: userHeading, snapToStreetLevel: false)
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

    private func centerCamera(on loc: CLLocation, in mapView: MKMapView,
                              heading: CLLocationDirection,
                              snapToStreetLevel: Bool = false) {
        if snapToStreetLevel {
            // First-ever fix: force a building-level zoom, ignore current altitude.
            let cam = MKMapCamera(lookingAtCenter: loc.coordinate,
                                  fromDistance: 150, pitch: 0, heading: 0)
            mapView.setCamera(cam, animated: true)
        } else if trackingMode == .followWithHeading && heading >= 0 {
            // Heading mode needs a full camera to set the heading; preserve altitude.
            let cam = MKMapCamera(lookingAtCenter: loc.coordinate,
                                  fromDistance: mapView.camera.altitude,
                                  pitch: 0, heading: heading)
            mapView.setCamera(cam, animated: true)
        } else {
            // Normal follow: only re-centre, never touch the zoom level.
            // Using setCenter avoids creating a new camera mid-animation which would
            // capture the transitional altitude and undo the initial street-level snap.
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

    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: IndoorMapView

        var userLocationAnnotation: UserLocationAnnotation?
        var floorPlanOverlay:       IndoorMapOverlay?
        weak var floorPlanRenderer: IndoorMapOverlayRenderer?
        var currentAccuracyCircle:  MKCircle?
        weak var currentRoute:      MKPolyline?
        var prevTrackingMode:       MKUserTrackingMode = .none
        var lastBoundaryParams:     (Double, Double, Double, Double, Double)?
        var hasInitiallyCentered    = false

        // Floor-plan gesture recognizers (2-finger; installed only while editing)
        private var fpPinch:    UIPinchGestureRecognizer?
        private var fpRotation: UIRotationGestureRecognizer?
        private var fpPan:      UIPanGestureRecognizer?

        // Incremental gesture state
        private var prevScale       = CGFloat(1)
        private var prevRotation    = CGFloat(0)
        private var prevTranslation = CGPoint.zero

        init(_ parent: IndoorMapView) { self.parent = parent }

        // MARK: - Floor-plan gesture management

        func installFloorPlanGestures(on mapView: MKMapView) {
            guard fpPinch == nil else { return }

            let pinch    = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation))
            let pan      = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2

            for gr in [pinch, rotation, pan] as [UIGestureRecognizer] { gr.delegate = self }

            mapView.addGestureRecognizer(pinch)
            mapView.addGestureRecognizer(rotation)
            mapView.addGestureRecognizer(pan)
            fpPinch = pinch; fpRotation = rotation; fpPan = pan
        }

        func removeFloorPlanGestures(from mapView: MKMapView) {
            [fpPinch, fpRotation, fpPan].forEach { gr in
                if let gr { mapView.removeGestureRecognizer(gr) }
            }
            fpPinch = nil; fpRotation = nil; fpPan = nil
        }

        // Allow our three custom recognizers to fire simultaneously with each other,
        // but never with MapKit's built-in gesture recognizers — that is what isolates
        // the two modes. (In practice the map flags are also disabled in Adjust Image
        // mode, so this is belt-and-suspenders for any edge-case recognizer ordering.)
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let ours: [UIGestureRecognizer?] = [fpPinch, fpRotation, fpPan]
            return ours.contains { $0 === g } && ours.contains { $0 === other }
        }

        @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
            switch gr.state {
            case .began:  prevScale = 1
            case .changed:
                let factor = gr.scale / prevScale
                prevScale  = gr.scale
                parent.onScaleFloorPlan?(factor)
            default:      prevScale = 1
            }
        }

        @objc private func handleRotation(_ gr: UIRotationGestureRecognizer) {
            switch gr.state {
            case .began:  prevRotation = 0
            case .changed:
                let delta    = gr.rotation - prevRotation
                prevRotation = gr.rotation
                parent.onRotateFloorPlan?(Double(delta * 180 / .pi))
            default:      prevRotation = 0
            }
        }

        @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let mapView = gr.view as? MKMapView else { return }
            switch gr.state {
            case .began:  prevTranslation = .zero
            case .changed:
                let t  = gr.translation(in: mapView)
                let dx = t.x - prevTranslation.x
                let dy = t.y - prevTranslation.y
                prevTranslation = t
                // Use mapView.convert to derive the geographic delta directly from
                // MapKit's own projection. This is correct regardless of map position,
                // zoom, or rotation — unlike span/size math which can invert direction
                // when the floor plan is offset from the current viewport centre.
                let mid     = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
                let ref     = mapView.convert(mid, toCoordinateFrom: mapView)
                let shifted = mapView.convert(CGPoint(x: mid.x + dx, y: mid.y + dy),
                                              toCoordinateFrom: mapView)
                parent.onMoveFloorPlan?(shifted.latitude  - ref.latitude,
                                        shifted.longitude - ref.longitude)
            default:      prevTranslation = .zero
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            DispatchQueue.main.async {
                self.parent.currentMapCenter = mapView.centerCoordinate
                self.parent.currentMapSpan   = mapView.region.span
            }
            // Break tracking synchronously on a user-initiated pan (animated = false
            // means a gesture, not a programmatic camera move).  Must be synchronous:
            // a location update that fires in the same run-loop cycle would otherwise
            // still see the old trackingMode and immediately re-centre the map.
            if !animated, parent.trackingMode != .none {
                parent.trackingMode = .none
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
