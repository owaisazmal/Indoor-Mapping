import SwiftUI
import MapKit
import CoreLocation

// MARK: - Overlay subclasses

class GlowRoutePolyline:      MKPolyline {}   // outer ambient glow layer
class BorderRoutePolyline:    MKPolyline {}   // white border layer
class FillRoutePolyline:      MKPolyline {}   // vibrant blue fill layer
class BuildingBoundaryPolygon: MKPolygon  {}

// MARK: - Destination annotation (tap-to-navigate pin)

class DestinationAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    let nodeID: String
    init(_ coord: CLLocationCoordinate2D, title: String, nodeID: String) {
        self.coordinate = coord; self.title = title; self.nodeID = nodeID
    }
}

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
        shadowLayer.path        = shadowPath
        shadowLayer.fillColor   = UIColor.white.cgColor
        shadowLayer.shadowColor = UIColor.black.cgColor
        shadowLayer.shadowOpacity = 0.22
        shadowLayer.shadowRadius  = 5
        shadowLayer.shadowOffset  = CGSize(width: 0, height: 2)
        layer.addSublayer(shadowLayer)

        let dotPath = UIBezierPath(arcCenter: c, radius: dotRadius,
                                   startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        dotLayer.path      = dotPath
        dotLayer.fillColor = UIColor(red: 0.26, green: 0.58, blue: 0.97, alpha: 1).cgColor
        layer.addSublayer(dotLayer)
        updateCone()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateCone() {
        guard let h = heading else { coneLayer.path = nil; return }
        let c     = CGPoint(x: canvasSize / 2, y: canvasSize / 2)
        let angle = CGFloat(h) * .pi / 180 - .pi / 2
        let p     = UIBezierPath()
        p.move(to: c)
        p.addArc(withCenter: c, radius: coneRadius,
                 startAngle: angle - coneHalfAngle,
                 endAngle:   angle + coneHalfAngle, clockwise: true)
        p.close()
        coneLayer.path = p.cgPath
    }
}

// MARK: - IndoorMapView

struct IndoorMapView: UIViewRepresentable {

    var floorPlanImage:         UIImage
    var overlayCenter:          CLLocationCoordinate2D
    var overlayWidthMeters:     Double
    var overlayHeightMeters:    Double
    var overlayRotationDegrees: Double
    var overlayAlpha:           Double
    var route:                  MKPolyline?
    var userLocation:           CLLocation?
    var userHeading:            CLLocationDirection
    var showBuildingBoundary:   Bool
    var isEditing:              Bool

    // ── Tap-to-navigate ───────────────────────────────────────────────────────
    /// Enables single-tap node snapping when non-nil.
    var navGraph:         NavGraph?          = nil
    /// UV-space waypoints from the pathfinder.  When non-empty this renders as
    /// a three-layer Google Maps–style polyline and supersedes `route`.
    var pathUVs:          [CGPoint]          = []
    /// Current user UV position (from GPS→UV or AR tracking).
    /// Used to trim the leading edge of the rendered path as the user advances.
    var userUV:           CGPoint?           = nil
    /// Fired with the snapped NavNode when the user taps the floor plan.
    var onTapDestination: ((NavNode) -> Void)? = nil

    // Callbacks fired by 2-finger gestures during alignment
    var onMoveFloorPlan:   ((Double, Double) -> Void)? = nil
    var onScaleFloorPlan:  ((CGFloat) -> Void)?        = nil
    var onRotateFloorPlan: ((Double) -> Void)?         = nil

    @Binding var trackingMode:      MKUserTrackingMode
    @Binding var currentMapCenter:  CLLocationCoordinate2D
    @Binding var currentMapSpan:    MKCoordinateSpan

    // MARK: UIViewRepresentable

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsUserLocation = false
        mapView.showsCompass = true
        mapView.showsScale   = true

        if let coord = userLocation?.coordinate {
            let cam = MKMapCamera(lookingAtCenter: coord, fromDistance: 150, pitch: 0, heading: 0)
            mapView.setCamera(cam, animated: false)
        }

        let overlay = makeFloorPlanOverlay()
        context.coordinator.floorPlanOverlay = overlay
        mapView.addOverlay(overlay)

        // Single-tap recognizer for tap-to-navigate.
        // Installed always; enabled/disabled based on navGraph in updateUIView.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleMapTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap

        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        // Gesture lock for floor-plan editing
        uiView.isScrollEnabled = !isEditing
        uiView.isZoomEnabled   = !isEditing
        uiView.isRotateEnabled = !isEditing
        uiView.isPitchEnabled  = !isEditing

        if isEditing { coord.installFloorPlanGestures(on: uiView) }
        else         { coord.removeFloorPlanGestures(from: uiView) }

        // Tap recognizer active only outside editing mode and when a graph is loaded
        coord.tapRecognizer?.isEnabled = (navGraph != nil) && !isEditing

        // ── User location annotation ──────────────────────────────────────────
        if let loc = userLocation {
            if let ann = coord.userLocationAnnotation {
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

        // ── Camera tracking ───────────────────────────────────────────────────
        if !coord.hasInitiallyCentered, let loc = userLocation {
            coord.hasInitiallyCentered = true
            centerCamera(on: loc, in: uiView, heading: userHeading, snapToStreetLevel: true)
            if trackingMode == .follow {
                DispatchQueue.main.async { coord.parent.trackingMode = .none }
            }
        } else if trackingMode != coord.prevTrackingMode, let loc = userLocation {
            coord.prevTrackingMode = trackingMode
            switch trackingMode {
            case .follow:
                centerCamera(on: loc, in: uiView, heading: userHeading, snapToStreetLevel: true)
                DispatchQueue.main.async { coord.parent.trackingMode = .none }
            case .followWithHeading:
                centerCamera(on: loc, in: uiView, heading: userHeading, snapToStreetLevel: false)
            default: break
            }
        } else if trackingMode == .followWithHeading, let loc = userLocation {
            let mc = uiView.centerCoordinate
            if abs(mc.latitude  - loc.coordinate.latitude)  > 0.00005 ||
               abs(mc.longitude - loc.coordinate.longitude) > 0.00005 {
                centerCamera(on: loc, in: uiView, heading: userHeading, snapToStreetLevel: false)
            }
        }

        // ── Floor plan overlay ────────────────────────────────────────────────
        if let current = coord.floorPlanOverlay {
            if current.image !== floorPlanImage {
                uiView.removeOverlay(current)
                let new = makeFloorPlanOverlay()
                coord.floorPlanOverlay = new
                uiView.addOverlay(new)
            } else {
                current.coordinate      = overlayCenter
                current.widthMeters     = overlayWidthMeters
                current.heightMeters    = overlayHeightMeters
                current.rotationDegrees = overlayRotationDegrees
                current.alpha           = overlayAlpha
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

        // ── Route: UV path takes precedence over legacy MKPolyline ────────────
        //
        // Three cases:
        //  A) pathUVs is non-empty  → render glow+border+fill from UV waypoints,
        //                             trimming the leading edge as the user advances.
        //  B) pathUVs is empty and `route` is set → render legacy MKPolyline.
        //  C) both empty            → clear all route overlays.

        let pvs = pathUVs
        if !pvs.isEmpty {
            if pvs != coord.currentPathUVs {
                // New or changed path: full rebuild from index 0
                coord.currentPathUVs = pvs
                coord.currentTrimIdx = 0
                coord.rebuildRoute(in: uiView, from: 0)
            } else if let uuv = userUV {
                // Same path, user moved forward: advance trim index if closer
                // to a later waypoint than the current trim index.
                let newTrim = pvs.indices.min {
                    pvs[$0].uvDist(to: uuv) < pvs[$1].uvDist(to: uuv)
                } ?? 0
                if newTrim > coord.currentTrimIdx {
                    coord.currentTrimIdx = newTrim
                    coord.rebuildRoute(in: uiView, from: newTrim)
                }
            }
        } else if !coord.currentPathUVs.isEmpty {
            // Path was explicitly cleared
            coord.currentPathUVs = []
            coord.currentTrimIdx = 0
            coord.clearRouteOverlays(in: uiView)
            if let ann = coord.destinationAnnotation {
                uiView.removeAnnotation(ann)
                coord.destinationAnnotation = nil
            }
        } else if let newRoute = route {
            // Legacy MKPolyline route (DirectionsSheet etc.)
            if coord.currentRoute !== newRoute {
                coord.clearRouteOverlays(in: uiView)
                coord.currentRoute = newRoute
                var coords = [CLLocationCoordinate2D](repeating: .init(), count: newRoute.pointCount)
                newRoute.getCoordinates(&coords, range: NSRange(location: 0, length: newRoute.pointCount))
                uiView.addOverlay(GlowRoutePolyline(coordinates:   &coords, count: coords.count))
                uiView.addOverlay(BorderRoutePolyline(coordinates: &coords, count: coords.count))
                uiView.addOverlay(FillRoutePolyline(coordinates:   &coords, count: coords.count))
            }
        } else if coord.currentRoute != nil {
            coord.clearRouteOverlays(in: uiView)
        }
    }

    // MARK: - Helpers

    private func centerCamera(on loc: CLLocation, in mapView: MKMapView,
                              heading: CLLocationDirection,
                              snapToStreetLevel: Bool = false) {
        if snapToStreetLevel {
            let cam = MKMapCamera(lookingAtCenter: loc.coordinate,
                                  fromDistance: 150, pitch: 0, heading: 0)
            mapView.setCamera(cam, animated: true)
        } else if trackingMode == .followWithHeading && heading >= 0 {
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

    private func buildingPolygon(center: CLLocationCoordinate2D,
                                  widthM: Double, heightM: Double,
                                  rotDeg: Double) -> BuildingBoundaryPolygon {
        let mPerLat = 111_000.0
        let mPerLon = 111_000.0 * cos(center.latitude * .pi / 180)
        let hw = widthM / 2, hh = heightM / 2
        let a = rotDeg * .pi / 180.0
        let ca = cos(a), sa = sin(a)
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

    // MARK: - Coordinator

    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: IndoorMapView

        // ── Existing overlay / annotation state ───────────────────────────────
        var userLocationAnnotation: UserLocationAnnotation?
        var floorPlanOverlay:       IndoorMapOverlay?
        weak var floorPlanRenderer: IndoorMapOverlayRenderer?
        var currentAccuracyCircle:  MKCircle?
        weak var currentRoute:      MKPolyline?
        var prevTrackingMode:       MKUserTrackingMode = .none
        var lastBoundaryParams:     (Double, Double, Double, Double, Double)?
        var hasInitiallyCentered    = false

        // ── Tap-to-navigate state ─────────────────────────────────────────────
        weak var tapRecognizer:      UITapGestureRecognizer?
        var destinationAnnotation:   DestinationAnnotation?
        /// The full UV path currently displayed.  Compared on each updateUIView
        /// so we only rebuild overlays when the path actually changes.
        var currentPathUVs:          [CGPoint] = []
        /// Index into `currentPathUVs` marking how much of the leading edge has
        /// been trimmed as the user advanced.
        var currentTrimIdx:          Int = 0

        // ── Floor-plan gesture recognizers (2-finger; editing only) ───────────
        private var fpPinch:    UIPinchGestureRecognizer?
        private var fpRotation: UIRotationGestureRecognizer?
        private var fpPan:      UIPanGestureRecognizer?
        private var prevScale       = CGFloat(1)
        private var prevRotation    = CGFloat(0)
        private var prevTranslation = CGPoint.zero

        init(_ parent: IndoorMapView) { self.parent = parent }

        // MARK: - Tap-to-navigate

        @objc func handleMapTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended,
                  !parent.isEditing,
                  let graph   = parent.navGraph,
                  let mapView = gr.view as? MKMapView else { return }

            let screen = gr.location(in: mapView)
            let geo    = mapView.convert(screen, toCoordinateFrom: mapView)
            let uv     = geoToUV(geo)

            guard let node = graph.nearestNode(to: uv) else { return }

            // Place or update the destination pin at the snapped node's geo position
            let pinCoord = uvToGeo(node.uv)
            if let existing = destinationAnnotation {
                existing.coordinate = pinCoord
                existing.title      = node.name
            } else {
                let ann = DestinationAnnotation(pinCoord, title: node.name, nodeID: node.id)
                destinationAnnotation = ann
                mapView.addAnnotation(ann)
            }

            parent.onTapDestination?(node)
        }

        // MARK: - Coordinate conversion

        /// Converts a geographic coordinate to a UV position on the floor plan.
        ///
        /// Math:
        ///   Forward map:  east  =  lx·cos(a) + ly·sin(a)
        ///                 north = −lx·sin(a) + ly·cos(a)
        ///   Inverse (R⁻¹ = Rᵀ):
        ///                 lx    =  east·cos(a) − north·sin(a)
        ///                 ly    =  east·sin(a) + north·cos(a)
        ///   UV:           u = 0.5 + lx / width
        ///                 v = 0.5 − ly / height   (v increases downward, ly increases north)
        func geoToUV(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let center = parent.overlayCenter
            let mPerLat = 111_000.0
            let mPerLon = 111_000.0 * cos(center.latitude * .pi / 180)

            let northM = (coord.latitude  - center.latitude)  * mPerLat
            let eastM  = (coord.longitude - center.longitude) * mPerLon

            let a  = parent.overlayRotationDegrees * .pi / 180.0
            let ca = cos(a), sa = sin(a)

            let lx = eastM * ca - northM * sa
            let ly = eastM * sa + northM * ca

            return CGPoint(x: 0.5 + lx / parent.overlayWidthMeters,
                           y: 0.5 - ly / parent.overlayHeightMeters)
        }

        /// Converts a UV position on the floor plan back to a geographic coordinate.
        func uvToGeo(_ uv: CGPoint) -> CLLocationCoordinate2D {
            let center = parent.overlayCenter
            let mPerLat = 111_000.0
            let mPerLon = 111_000.0 * cos(center.latitude * .pi / 180)

            let lx = (uv.x - 0.5) * parent.overlayWidthMeters
            let ly = (0.5 - uv.y) * parent.overlayHeightMeters

            let a  = parent.overlayRotationDegrees * .pi / 180.0
            let ca = cos(a), sa = sin(a)

            let east  =  lx * ca + ly * sa
            let north = -lx * sa + ly * ca

            return CLLocationCoordinate2D(
                latitude:  center.latitude  + north / mPerLat,
                longitude: center.longitude + east  / mPerLon)
        }

        // MARK: - Route overlay management

        /// Converts `currentPathUVs[startIdx...]` to geographic coordinates and
        /// replaces all three route overlay layers (glow / border / fill).
        func rebuildRoute(in mapView: MKMapView, from startIdx: Int) {
            clearRouteOverlays(in: mapView)
            let slice = Array(currentPathUVs.dropFirst(startIdx))
            guard slice.count >= 2 else { return }
            var coords = slice.map { uvToGeo($0) }
            // Add layers bottom-to-top so fill renders above border, border above glow.
            mapView.addOverlay(GlowRoutePolyline(coordinates:   &coords, count: coords.count))
            mapView.addOverlay(BorderRoutePolyline(coordinates: &coords, count: coords.count))
            mapView.addOverlay(FillRoutePolyline(coordinates:   &coords, count: coords.count))
        }

        func clearRouteOverlays(in mapView: MKMapView) {
            mapView.removeOverlays(mapView.overlays.compactMap { $0 as? GlowRoutePolyline   })
            mapView.removeOverlays(mapView.overlays.compactMap { $0 as? BorderRoutePolyline })
            mapView.removeOverlays(mapView.overlays.compactMap { $0 as? FillRoutePolyline   })
            currentRoute = nil
        }

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
            [fpPinch, fpRotation, fpPan].forEach { if let gr = $0 { mapView.removeGestureRecognizer(gr) } }
            fpPinch = nil; fpRotation = nil; fpPan = nil
        }

        // Our three custom floor-plan recognizers fire simultaneously with each
        // other, but not with MapKit's built-in recognizers (and not with the
        // tap recognizer).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let ours: [UIGestureRecognizer?] = [fpPinch, fpRotation, fpPan]
            return ours.contains { $0 === g } && ours.contains { $0 === other }
        }

        @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
            switch gr.state {
            case .began:   prevScale = 1
            case .changed:
                let factor = gr.scale / prevScale
                prevScale  = gr.scale
                parent.onScaleFloorPlan?(factor)
            default: prevScale = 1
            }
        }

        @objc private func handleRotation(_ gr: UIRotationGestureRecognizer) {
            switch gr.state {
            case .began:   prevRotation = 0
            case .changed:
                let delta    = gr.rotation - prevRotation
                prevRotation = gr.rotation
                parent.onRotateFloorPlan?(Double(delta * 180 / .pi))
            default: prevRotation = 0
            }
        }

        @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let mapView = gr.view as? MKMapView else { return }
            switch gr.state {
            case .began:   prevTranslation = .zero
            case .changed:
                let t  = gr.translation(in: mapView)
                let dx = t.x - prevTranslation.x
                let dy = t.y - prevTranslation.y
                prevTranslation = t
                let mid     = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
                let ref     = mapView.convert(mid, toCoordinateFrom: mapView)
                let shifted = mapView.convert(CGPoint(x: mid.x + dx, y: mid.y + dy),
                                              toCoordinateFrom: mapView)
                parent.onMoveFloorPlan?(shifted.latitude  - ref.latitude,
                                        shifted.longitude - ref.longitude)
            default: prevTranslation = .zero
            }
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            DispatchQueue.main.async {
                self.parent.currentMapCenter = mapView.centerCoordinate
                self.parent.currentMapSpan   = mapView.region.span
            }
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
            if let dest = annotation as? DestinationAnnotation {
                let id = "DestinationPin"
                let v  = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation        = annotation
                v.markerTintColor   = UIColor(red: 0.26, green: 0.58, blue: 0.97, alpha: 1)
                v.glyphImage        = UIImage(systemName: "flag.fill")
                v.titleVisibility   = .visible
                v.canShowCallout    = true
                // Bounce in when first placed
                v.animatesWhenAdded = (dest.coordinate.latitude == destinationAnnotation?.coordinate.latitude)
                return v
            }
            if annotation is UserLocationAnnotation {
                let id = "GoogleStyleUserDot"
                let v  = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? GoogleStyleUserDot)
                    ?? GoogleStyleUserDot(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.heading    = parent.userHeading >= 0 ? parent.userHeading : nil
                return v
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {

            if let floor = overlay as? IndoorMapOverlay {
                let r = IndoorMapOverlayRenderer(overlay: floor, overlayImage: floor.image)
                floorPlanRenderer = r
                return r
            }

            if let boundary = overlay as? BuildingBoundaryPolygon {
                let r = MKPolygonRenderer(polygon: boundary)
                r.strokeColor     = UIColor.systemIndigo.withAlphaComponent(0.85)
                r.fillColor       = UIColor.systemIndigo.withAlphaComponent(0.06)
                r.lineWidth       = 2.5
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

            // ── Google Maps–style three-layer path ────────────────────────────
            //
            // Layer 1 (bottom): wide, low-opacity blue glow → ambient halo effect
            // Layer 2 (middle): white border               → crisp edge definition
            // Layer 3 (top):    narrow, vibrant blue fill  → primary route colour
            //
            // lineWidth values are in map points and stay constant regardless of
            // zoom because MKPolylineRenderer re-rasterises at each zoom level.

            if let glow = overlay as? GlowRoutePolyline {
                let r = MKPolylineRenderer(polyline: glow)
                r.strokeColor = UIColor(red: 0.26, green: 0.58, blue: 0.97, alpha: 0.22)
                r.lineWidth   = 22
                r.lineCap     = .round
                r.lineJoin    = .round
                return r
            }

            if let border = overlay as? BorderRoutePolyline {
                let r = MKPolylineRenderer(polyline: border)
                r.strokeColor = .white
                r.lineWidth   = 14
                r.lineCap     = .round
                r.lineJoin    = .round
                return r
            }

            if let fill = overlay as? FillRoutePolyline {
                let r = MKPolylineRenderer(polyline: fill)
                r.strokeColor = UIColor(red: 0.26, green: 0.58, blue: 0.97, alpha: 1)
                r.lineWidth   = 9
                r.lineCap     = .round
                r.lineJoin    = .round
                return r
            }

            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - CGPoint UV helpers

private extension CGPoint {
    /// Euclidean distance in UV space.  Used for path-trim index lookup.
    func uvDist(to other: CGPoint) -> Double {
        let dx = Double(x - other.x)
        let dy = Double(y - other.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
