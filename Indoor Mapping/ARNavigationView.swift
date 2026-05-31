import SwiftUI
import ARKit
import SceneKit

// MARK: - AR Scene View wrapper

struct ARNavSceneView: UIViewRepresentable {
    let store: ARNavStore
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = store.arKitSession
        v.scene   = store.scene
        v.automaticallyUpdatesLighting = true
        v.antialiasingMode = .multisampling4X
        return v
    }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}

// MARK: - 2D floor-plan canvas

struct NavMapCanvas: View {
    let image:        UIImage
    let userUV:       CGPoint
    let pathUVs:      [CGPoint]
    let destinations: [NavDestination]
    let selectedId:   Int?
    let onTap:        (NavDestination) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: w, height: h).clipped()
                    .overlay(Color.black.opacity(0.18))

                Canvas { ctx, size in
                    if pathUVs.count >= 2 {
                        var p = Path()
                        for (i, uv) in pathUVs.enumerated() {
                            let pt = CGPoint(x: uv.x * size.width, y: uv.y * size.height)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        ctx.stroke(p, with: .color(.white.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [9, 6]))
                        ctx.stroke(p, with: .color(.blue.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [9, 6]))
                    }

                    for d in destinations {
                        let pt  = CGPoint(x: d.mapUV.x * size.width, y: d.mapUV.y * size.height)
                        let sel = d.id == selectedId
                        let r:  CGFloat = sel ? 11 : 7.5
                        ctx.fill(oval(center: pt, r: r + 2.5), with: .color(.white))
                        ctx.fill(oval(center: pt, r: r),       with: .color(Color(d.uiColor)))
                        if sel {
                            ctx.stroke(oval(center: pt, r: r + 5),
                                       with: .color(Color(d.uiColor).opacity(0.35)), lineWidth: 3)
                        }
                    }

                    let up = CGPoint(x: userUV.x * size.width, y: userUV.y * size.height)
                    ctx.fill(oval(center: up, r: 10.5), with: .color(.white))
                    ctx.fill(oval(center: up, r: 7.5),  with: .color(.blue))
                }

                ForEach(destinations) { d in
                    Button { onTap(d) } label: { Color.clear.frame(width: 48, height: 48) }
                        .position(x: d.mapUV.x * w, y: d.mapUV.y * h)
                }
            }
            .clipShape(Rectangle())
        }
    }

    private func oval(center: CGPoint, r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }
}

// MARK: - Destination picker sheet

struct DestinationPicker: View {
    let destinations: [NavDestination]
    let onSelect:     (NavDestination) -> Void

    var body: some View {
        NavigationView {
            List(destinations) { dest in
                Button { onSelect(dest) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: dest.icon)
                            .font(.title3).foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color(dest.uiColor)).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(dest.name).font(.body).foregroundColor(.primary)
                            Text("Tap to start AR navigation")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Where to?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Calibration pin annotation view
// A glowing blue ring with a solid dot — used by CalibrationMapView to mark
// the user's tapped starting position on the floor plan.

private class CalibrationPinView: MKAnnotationView {

    private let outerRing = CAShapeLayer()
    private let innerDot  = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let size: CGFloat = 60
        bounds          = CGRect(x: 0, y: 0, width: size, height: size)
        centerOffset    = .zero
        backgroundColor = .clear
        let c = CGPoint(x: size / 2, y: size / 2)

        // Outer pulsing ring
        let outerPath = UIBezierPath(arcCenter: c, radius: 23,
                                     startAngle: 0, endAngle: .pi * 2, clockwise: true)
        outerRing.path        = outerPath.cgPath
        outerRing.fillColor   = UIColor.systemBlue.withAlphaComponent(0.18).cgColor
        outerRing.strokeColor = UIColor.systemBlue.withAlphaComponent(0.60).cgColor
        outerRing.lineWidth   = 2
        layer.addSublayer(outerRing)

        let pulse          = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue    = 0.35
        pulse.toValue      = 1.0
        pulse.duration     = 1.0
        pulse.autoreverses = true
        pulse.repeatCount  = .infinity
        outerRing.add(pulse, forKey: "pulse")

        // Solid centre dot with white halo
        let haloPath = UIBezierPath(arcCenter: c, radius: 12,
                                    startAngle: 0, endAngle: .pi * 2, clockwise: true)
        let halo = CAShapeLayer()
        halo.path      = haloPath.cgPath
        halo.fillColor = UIColor.white.cgColor
        halo.shadowColor   = UIColor.black.cgColor
        halo.shadowOpacity = 0.22
        halo.shadowRadius  = 4
        halo.shadowOffset  = CGSize(width: 0, height: 2)
        layer.addSublayer(halo)

        let dotPath = UIBezierPath(arcCenter: c, radius: 9,
                                   startAngle: 0, endAngle: .pi * 2, clockwise: true)
        innerDot.path        = dotPath.cgPath
        innerDot.fillColor   = UIColor(red: 0.26, green: 0.58, blue: 0.97, alpha: 1).cgColor
        innerDot.strokeColor = UIColor.white.cgColor
        innerDot.lineWidth   = 2
        layer.addSublayer(innerDot)
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - CalibrationMapView
// Lightweight UIViewRepresentable used inside OriginCalibrationView.
//   • Renders the floor plan overlay on a standard MKMapView.
//   • Auto-fits the camera to the floor plan bounding box (+ 15 % padding)
//     exactly once when the view first appears.
//   • Converts single taps to UV coordinates and writes them back via
//     the `pendingUV` binding.
//   • All GPS / tracking modes are disabled — the camera never snaps away.

private struct CalibrationMapView: UIViewRepresentable {

    let floorPlanImage:         UIImage
    let overlayCenter:          CLLocationCoordinate2D
    let overlayWidthMeters:     Double
    let overlayHeightMeters:    Double
    let overlayRotationDegrees: Double
    @Binding var pendingUV:     CGPoint?

    // MARK: UIViewRepresentable

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate           = context.coordinator
        mv.mapType            = .standard
        mv.showsUserLocation  = false   // GPS dot deliberately hidden
        mv.isRotateEnabled    = false   // keep map north-up for clarity
        mv.isPitchEnabled     = false
        mv.showsCompass       = false
        mv.showsScale         = true

        let overlay = IndoorMapOverlay(image:           floorPlanImage,
                                       coordinate:      overlayCenter,
                                       widthMeters:     overlayWidthMeters,
                                       heightMeters:    overlayHeightMeters,
                                       rotationDegrees: overlayRotationDegrees,
                                       alpha:           0.92)
        mv.addOverlay(overlay)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap(_:)))
        mv.addGestureRecognizer(tap)
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        // Fit to floor plan bounding box exactly once — never again so that
        // subsequent SwiftUI re-renders (e.g. pendingUV changes) don't reset
        // the camera while the user is panning or zooming.
        if !coord.hasFitted {
            coord.hasFitted = true
            mv.setVisibleMapRect(floorPlanMapRect(),
                                  edgePadding: UIEdgeInsets(top: 60, left: 40,
                                                            bottom: 120, right: 40),
                                  animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Fit rect

    /// Builds an MKMapRect that encloses the rotated floor plan + 15 % padding.
    func floorPlanMapRect() -> MKMapRect {
        let mPerLat = 111_000.0
        let mPerLon = 111_000.0 * cos(overlayCenter.latitude * .pi / 180)
        let hw = overlayWidthMeters  / 2
        let hh = overlayHeightMeters / 2
        let a  = overlayRotationDegrees * .pi / 180.0
        let ca = cos(a), sa = sin(a)

        // Four corners using the same rotation as buildingPolygon / IndoorMapOverlayRenderer
        let corners: [(Double, Double)] = [(-hw,-hh), (hw,-hh), (hw,hh), (-hw,hh)]
        let pts = corners.map { (lx, ly) -> MKMapPoint in
            let east  =  lx * ca + ly * sa
            let north = -lx * sa + ly * ca
            return MKMapPoint(CLLocationCoordinate2D(
                latitude:  overlayCenter.latitude  + north / mPerLat,
                longitude: overlayCenter.longitude + east  / mPerLon))
        }

        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let w = maxX - minX, h = maxY - minY
        let p = 0.15
        return MKMapRect(x: minX - w * p, y: minY - h * p,
                          width: w * (1 + 2 * p), height: h * (1 + 2 * p))
    }

    // MARK: Coordinator

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent:      CalibrationMapView
        var hasFitted    = false
        var pinAnnotation: CalibrationPinAnnotation?

        init(_ p: CalibrationMapView) { parent = p }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended, let mv = gr.view as? MKMapView else { return }
            let geo = mv.convert(gr.location(in: mv), toCoordinateFrom: mv)
            let uv  = geoToUV(geo)
            parent.pendingUV = uv
            UISelectionFeedbackGenerator().selectionChanged()

            let pinCoord = uvToGeo(uv)
            if let pin = pinAnnotation {
                pin.coordinate = pinCoord
            } else {
                let pin = CalibrationPinAnnotation(pinCoord)
                pinAnnotation = pin
                mv.addAnnotation(pin)
            }
        }

        // Inverse-rotation formula — identical to geoToUV in IndoorMapView.Coordinator.
        func geoToUV(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let c = parent.overlayCenter
            let mPerLat = 111_000.0
            let mPerLon = 111_000.0 * cos(c.latitude * .pi / 180)
            let northM  = (coord.latitude  - c.latitude)  * mPerLat
            let eastM   = (coord.longitude - c.longitude) * mPerLon
            let a  = parent.overlayRotationDegrees * .pi / 180.0
            let ca = cos(a), sa = sin(a)
            return CGPoint(x: 0.5 + (eastM * ca - northM * sa) / parent.overlayWidthMeters,
                           y: 0.5 - (eastM * sa + northM * ca) / parent.overlayHeightMeters)
        }

        func uvToGeo(_ uv: CGPoint) -> CLLocationCoordinate2D {
            let c = parent.overlayCenter
            let mPerLat = 111_000.0
            let mPerLon = 111_000.0 * cos(c.latitude * .pi / 180)
            let lx  = (uv.x - 0.5) * parent.overlayWidthMeters
            let ly  = (0.5 - uv.y) * parent.overlayHeightMeters
            let a   = parent.overlayRotationDegrees * .pi / 180.0
            let ca  = cos(a), sa = sin(a)
            return CLLocationCoordinate2D(
                latitude:  c.latitude  + (-lx * sa + ly * ca) / mPerLat,
                longitude: c.longitude + ( lx * ca + ly * sa) / mPerLon)
        }

        func mapView(_ mv: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let floor = overlay as? IndoorMapOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            return IndoorMapOverlayRenderer(overlay: floor, overlayImage: floor.image)
        }

        func mapView(_ mv: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is CalibrationPinAnnotation else { return nil }
            let id = "CalibPin"
            let v  = (mv.dequeueReusableAnnotationView(withIdentifier: id) as? CalibrationPinView)
                ?? CalibrationPinView(annotation: annotation, reuseIdentifier: id)
            v.annotation        = annotation
            v.animatesWhenAdded = true
            return v
        }
    }
}

/// Lightweight annotation class so `CalibrationMapView` can distinguish its own
/// pin from any other annotations that might be added in the future.
private class CalibrationPinAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ coord: CLLocationCoordinate2D) { coordinate = coord }
}

// MARK: - Origin Calibration View
// Shown before the AR session starts. The user taps their current physical
// position on the floor plan overlaid on a real map; that UV becomes originUV.

private struct OriginCalibrationView: View {
    let floorPlanImage: UIImage
    let onConfirm:      (CGPoint) -> Void
    let onDismiss:      () -> Void

    @State private var pendingUV: CGPoint?

    var body: some View {
        ZStack(alignment: .top) {

            // ── Floor plan + tap capture ──────────────────────────────────────
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Image(uiImage: floorPlanImage)
                        .resizable().scaledToFill()
                        .frame(width: w, height: h)
                        .clipped()

                    if let uv = pendingUV {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.22))
                                .frame(width: 46, height: 46)
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                        }
                        .position(x: uv.x * w, y: uv.y * h)
                        .allowsHitTesting(false)
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { v in
                                    pendingUV = CGPoint(x: v.location.x / w,
                                                        y: v.location.y / h)
                                }
                        )
                }
            }
            .edgesIgnoringSafeArea(.all)

            // ── Overlaid UI chrome ────────────────────────────────────────────
            VStack(spacing: 0) {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 38, height: 38)
                            .background(.regularMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.12), radius: 4)
                    }
                    Spacer()
                    Text("Set Starting Point")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial).clipShape(Capsule())
                        .shadow(color: .black.opacity(0.10), radius: 4)
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.horizontal, 16).padding(.top, 8)

                HStack(spacing: 7) {
                    Image(systemName: pendingUV == nil
                          ? "hand.tap.fill" : "checkmark.circle.fill")
                    Text(pendingUV == nil
                         ? "Tap your current position on the map"
                         : "Tap elsewhere to adjust")
                }
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color.black.opacity(0.62)).clipShape(Capsule())
                .padding(.top, 12)

                Spacer()

                if let uv = pendingUV {
                    Button { onConfirm(uv) } label: {
                        Label("Confirm & Start Navigation",
                              systemImage: "arrow.right.circle.fill")
                            .font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.indigo).cornerRadius(14)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: pendingUV != nil)
        }
    }
}

// MARK: - Tracking lost overlay
// Shown over the full AR view whenever trackingStatus is not .active.
// .interrupted → translucent banner prompting the user to restore the camera.
// .lost        → opaque blocker that forces re-calibration before any
//                position updates can resume.

private struct TrackingLostOverlay: View {
    let status:        TrackingStatus
    let onRecalibrate: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .opacity(status == .lost ? 0.75 : 0.50)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: iconName)
                    .font(.system(size: 50))
                    .foregroundColor(iconColor)

                Text(title)
                    .font(.title2.bold())
                    .foregroundColor(.white)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)

                if status == .lost {
                    Button(action: onRecalibrate) {
                        Label("Re-calibrate Position", systemImage: "scope")
                            .font(.headline).foregroundColor(.white)
                            .padding(.horizontal, 28).padding(.vertical, 14)
                            .background(Color.indigo).clipShape(Capsule())
                            .shadow(color: .indigo.opacity(0.4), radius: 8, y: 4)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(32)
        }
    }

    private var iconName: String {
        switch status {
        case .degraded:    return "camera.metering.unknown"
        case .interrupted: return "eye.slash.fill"
        case .lost:        return "exclamationmark.triangle.fill"
        case .active:      return ""
        }
    }

    private var iconColor: Color {
        switch status {
        case .degraded:    return .yellow
        case .interrupted: return .orange
        case .lost:        return .red
        case .active:      return .clear
        }
    }

    private var title: String {
        switch status {
        case .degraded:    return "Poor Tracking"
        case .interrupted: return "Tracking Paused"
        case .lost:        return "Tracking Lost"
        case .active:      return ""
        }
    }

    private var message: String {
        switch status {
        case .degraded:
            return "Not enough visual features to track your position.\nPoint the camera at a textured surface or look around slowly."
        case .interrupted:
            return "Camera or app was interrupted.\nReturn the camera to the room to resume."
        case .lost:
            return "AR drift is unrecoverable without physical anchors.\nRe-drop your starting pin to continue."
        case .active:
            return ""
        }
    }
}

// MARK: - AR Navigation Active View
// Only instantiated after the user confirms their starting position. Creates
// ARNavStore with the calibrated originUV so the blue dot is correct from the
// very first AR frame.

private struct ARNavActiveView: View {
    let floorPlanImage:        UIImage
    let destinations:          [NavDestination]
    let floorWidthMeters:      Double
    let floorHeightMeters:     Double
    /// Called when the user taps "Re-calibrate" in the tracking-lost overlay.
    /// The parent responds by resetting `confirmedOriginUV` to nil, which destroys
    /// this view (and its ARNavStore) and re-presents OriginCalibrationView.
    let onRecalibrationNeeded: () -> Void

    @StateObject private var store: ARNavStore
    @Environment(\.dismiss) private var dismiss
    @State private var showList = false

    init(floorPlanImage:        UIImage,
         destinations:          [NavDestination],
         floorWidthMeters:      Double,
         floorHeightMeters:     Double,
         originUV:              CGPoint,
         headingOffsetDegrees:  Double,
         onRecalibrationNeeded: @escaping () -> Void) {
        self.floorPlanImage        = floorPlanImage
        self.destinations          = destinations
        self.floorWidthMeters      = floorWidthMeters
        self.floorHeightMeters     = floorHeightMeters
        self.onRecalibrationNeeded = onRecalibrationNeeded
        // StateObject(wrappedValue:) is the correct SwiftUI pattern for passing
        // runtime values into a @StateObject initialiser.
        _store = StateObject(wrappedValue: ARNavStore(originUV: originUV,
                                                      headingOffsetDegrees: headingOffsetDegrees))
    }

    var body: some View {
        ZStack(alignment: .top) {

            VStack(spacing: 0) {

                // ── TOP HALF: AR Camera ───────────────────────────────────────
                ZStack(alignment: .bottom) {
                    ARNavSceneView(store: store).ignoresSafeArea(edges: .top)

                    if let nav = store.activeNav {
                        HStack(spacing: 8) {
                            Image(systemName: nav.icon)
                            Text(store.distMeters < 1.5
                                 ? "You've arrived at \(nav.name)!"
                                 : String(format: "%.0f m · %@", store.distMeters, nav.name))
                        }
                        .font(.subheadline.bold()).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Color(nav.uiColor).opacity(0.93)).clipShape(Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)

                Rectangle().fill(Color(UIColor.separator)).frame(height: 1)

                // ── BOTTOM HALF: 2D Floor Plan ────────────────────────────────
                ZStack(alignment: .bottomTrailing) {
                    NavMapCanvas(
                        image:        floorPlanImage,
                        userUV:       store.userUV,
                        pathUVs:      store.pathUVs,
                        destinations: destinations,
                        selectedId:   store.activeNav?.id,
                        onTap:        { store.navigate(to: $0) }
                    )

                    if store.activeNav != nil {
                        Button { store.cancel() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2).symbolRenderingMode(.palette)
                                .foregroundStyle(Color.primary,
                                                 Color(UIColor.systemBackground).opacity(0.85))
                        }
                        .padding(14).transition(.opacity)
                    } else {
                        Button { showList = true } label: {
                            Label("Where to?", systemImage: "magnifyingglass")
                                .font(.subheadline.bold()).foregroundColor(.white)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Color.blue).clipShape(Capsule())
                                .shadow(color: .blue.opacity(0.35), radius: 6, y: 3)
                        }
                        .padding(14).transition(.opacity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .onAppear {
                store.floorWidthMeters  = floorWidthMeters
                store.floorHeightMeters = floorHeightMeters
                store.start()
            }
            .onDisappear { store.stop() }
            .sheet(isPresented: $showList) {
                DestinationPicker(destinations: destinations) { dest in
                    store.navigate(to: dest); showList = false
                }
                .presentationDetents([.medium])
            }

            // ── TOP NAV BAR ───────────────────────────────────────────────────
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial).clipShape(Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4)
                }
                Spacer()
                Text("AR Navigation")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial).clipShape(Capsule())
                    .shadow(color: .black.opacity(0.10), radius: 4)
                Spacer()
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        // ── Tracking interruption / loss overlay ─────────────────────────────
        // Rendered above everything else so no map or AR interaction is possible
        // while the session is in a degraded state.
        .overlay {
            if store.trackingStatus != .active {
                TrackingLostOverlay(
                    status:        store.trackingStatus,
                    onRecalibrate: onRecalibrationNeeded
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.trackingStatus)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.activeNav?.id)
    }
}

// MARK: - Main AR Navigation View
// Three-stage gate: empty state → calibration → active navigation.
// ARNavStore is only created after the user confirms their starting position,
// so originUV is always a real tap coordinate, never a hardcoded constant.

struct ARNavigationView: View {
    let floorPlanImage:       UIImage
    let mappingResult:        MappingResult?
    var floorWidthMeters:     Double = 30
    var floorHeightMeters:    Double = 20
    /// Compass heading of the device at calibration time minus the floor plan's
    /// visual rotation angle (floorPlan.rotationDegrees).  Pass 0 if the top of
    /// the floor plan image faces magnetic north.
    var headingOffsetDegrees: Double = 0

    @Environment(\.dismiss) private var dismiss
    @State private var confirmedOriginUV: CGPoint?

    private var destinations: [NavDestination] {
        (mappingResult?.pois ?? []).enumerated().map { i, poi in poi.toNavDestination(id: i) }
    }

    var body: some View {
        Group {
            if destinations.isEmpty {
                emptyStateView
            } else if let originUV = confirmedOriginUV {
                ARNavActiveView(
                    floorPlanImage:        floorPlanImage,
                    destinations:          destinations,
                    floorWidthMeters:      floorWidthMeters,
                    floorHeightMeters:     floorHeightMeters,
                    originUV:              originUV,
                    headingOffsetDegrees:  headingOffsetDegrees,
                    onRecalibrationNeeded: { confirmedOriginUV = nil }
                )
            } else {
                OriginCalibrationView(
                    floorPlanImage: floorPlanImage,
                    onConfirm: { confirmedOriginUV = $0 },
                    onDismiss: { dismiss() }
                )
            }
        }
    }

    private var emptyStateView: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "mappin.slash")
                    .font(.system(size: 56)).foregroundColor(.secondary)
                Text("No locations mapped yet").font(.title3.bold())
                Text("Scan your building first, then tap \"Mark Locations on Floor Plan\" to add points of interest. They'll appear here for AR navigation.")
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                Button { dismiss() } label: {
                    Label("Go back and scan", systemImage: "cube.transparent")
                        .font(.headline).foregroundColor(.white)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(Color.indigo).clipShape(Capsule())
                }
                Spacer()
            }

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial).clipShape(Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4)
                }
                Spacer()
                Text("AR Navigation")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial).clipShape(Capsule())
                    .shadow(color: .black.opacity(0.10), radius: 4)
                Spacer()
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
    }
}
