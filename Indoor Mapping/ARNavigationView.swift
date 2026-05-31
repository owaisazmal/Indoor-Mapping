import SwiftUI
import ARKit
import SceneKit
// MapKit removed: CalibrationMapView replaced by FloorPlanPinView (UIScrollView)

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

// MARK: - FloorPlanPinView
// UIScrollView-based floor plan viewer.  Replaces the previous MKMapView
// approach.  Advantages:
//   • No geographic constraints or camera-snap behaviour.
//   • Initialises to aspect-fit zoom so the entire floor plan is always visible.
//   • User can pinch/pan freely; tap drops a glowing UV pin.
//   • CalibrationScrollView subclass uses layoutSubviews for guaranteed fit
//     setup — reliable even when bounds are zero on first updateUIView call.

// CalibrationScrollView → replaced by FloorPlanScrollBase (FloorPlanScrollView.swift)
private typealias CalibrationScrollView = FloorPlanScrollBase

private struct FloorPlanPinView: UIViewRepresentable {
    let image:          UIImage
    @Binding var pendingUV: CGPoint?

    func makeUIView(context: Context) -> CalibrationScrollView {
        let sv              = CalibrationScrollView()
        sv.delegate         = context.coordinator
        sv.floorPlanImage   = image
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator   = false
        sv.bouncesZoom      = true
        sv.backgroundColor  = .systemBackground

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleToFill   // frame is set explicitly; contentMode irrelevant
        sv.addSubview(iv)
        sv.imageView = iv
        context.coordinator.imageView = iv

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap(_:)))
        sv.addGestureRecognizer(tap)
        return sv
    }

    func updateUIView(_ sv: CalibrationScrollView, context: Context) {
        // Keep binding reference current; all camera/zoom logic lives in
        // CalibrationScrollView.layoutSubviews so SwiftUI re-renders are harmless.
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent:     FloorPlanPinView
        weak var imageView: UIImageView?
        var pinLayer:   CALayer?

        init(_ p: FloorPlanPinView) { parent = p }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? CalibrationScrollView)?.centerContent()
        }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let iv = imageView else { return }
            let pt = gr.location(in: iv)
            let uv = CGPoint(
                x: max(0, min(1, pt.x / iv.bounds.width)),
                y: max(0, min(1, pt.y / iv.bounds.height))
            )
            parent.pendingUV = uv
            UISelectionFeedbackGenerator().selectionChanged()
            placePin(at: uv, on: iv)
        }

        private func placePin(at uv: CGPoint, on iv: UIImageView) {
            pinLayer?.removeFromSuperlayer()
            let cx = uv.x * iv.bounds.width
            let cy = uv.y * iv.bounds.height
            let sz: CGFloat = 60
            let c = CGPoint(x: sz / 2, y: sz / 2)

            let container   = CALayer()
            container.frame = CGRect(x: cx - sz/2, y: cy - sz/2, width: sz, height: sz)
            container.zPosition = 100

            let ring          = CAShapeLayer()
            ring.path         = UIBezierPath(arcCenter: c, radius: 23,
                                              startAngle: 0, endAngle: .pi*2, clockwise: true).cgPath
            ring.fillColor    = UIColor.systemBlue.withAlphaComponent(0.18).cgColor
            ring.strokeColor  = UIColor.systemBlue.withAlphaComponent(0.60).cgColor
            ring.lineWidth    = 2
            let pulse         = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue   = 0.35; pulse.toValue = 1.0
            pulse.duration    = 1.0;  pulse.autoreverses = true; pulse.repeatCount = .infinity
            ring.add(pulse, forKey: "pulse")
            container.addSublayer(ring)

            let halo          = CAShapeLayer()
            halo.path         = UIBezierPath(arcCenter: c, radius: 12,
                                              startAngle: 0, endAngle: .pi*2, clockwise: true).cgPath
            halo.fillColor    = UIColor.white.cgColor
            halo.shadowColor  = UIColor.black.cgColor
            halo.shadowOpacity = 0.22; halo.shadowRadius = 4
            halo.shadowOffset = CGSize(width: 0, height: 2)
            container.addSublayer(halo)

            let dot           = CAShapeLayer()
            dot.path          = UIBezierPath(arcCenter: c, radius: 9,
                                              startAngle: 0, endAngle: .pi*2, clockwise: true).cgPath
            dot.fillColor     = UIColor(red: 0.26, green: 0.58, blue: 0.97, alpha: 1).cgColor
            dot.strokeColor   = UIColor.white.cgColor; dot.lineWidth = 2
            container.addSublayer(dot)

            iv.layer.addSublayer(container)
            pinLayer = container
        }
    }
}

// MARK: - Origin Calibration View
// Shown before the AR session starts.  FloorPlanPinView (UIScrollView) replaces
// the previous MKMapView approach — no geographic dependencies, instant fit.

private struct OriginCalibrationView: View {
    let floorPlanImage: UIImage
    let onConfirm:      (CGPoint) -> Void
    let onDismiss:      () -> Void

    @State private var pendingUV: CGPoint?

    var body: some View {
        ZStack(alignment: .top) {
            FloorPlanPinView(image: floorPlanImage, pendingUV: $pendingUV)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 38, height: 38)
                            .background(.regularMaterial).clipShape(Circle())
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

                HStack(spacing: 8) {
                    Image(systemName: pendingUV == nil ? "hand.tap.fill" : "checkmark.circle.fill")
                        .font(.caption)
                    Text(pendingUV == nil
                         ? "Tap your current position on the floor plan"
                         : "Tap to adjust  ·  Pinch to zoom  ·  Drag to pan")
                        .font(.caption.bold())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color.black.opacity(0.62)).clipShape(Capsule())
                .padding(.top, 12)
                .animation(.easeInOut(duration: 0.2), value: pendingUV != nil)

                Spacer()

                if pendingUV != nil {
                    Button { onConfirm(pendingUV!) } label: {
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
    let navGraph:              NavGraph?
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
         navGraph:              NavGraph?,
         onRecalibrationNeeded: @escaping () -> Void) {
        self.floorPlanImage        = floorPlanImage
        self.destinations          = destinations
        self.floorWidthMeters      = floorWidthMeters
        self.floorHeightMeters     = floorHeightMeters
        self.navGraph              = navGraph
        self.onRecalibrationNeeded = onRecalibrationNeeded
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
                store.walkableRects     = navGraph?.walkableRects ?? []
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
    var floorWidthMeters:     Double   = 30
    var floorHeightMeters:    Double   = 20
    var headingOffsetDegrees: Double   = 0
    var navGraph:             NavGraph? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var confirmedOriginUV: CGPoint?

    /// Destinations are derived from persisted NavGraph nodes at session start.
    private var destinations: [NavDestination] {
        guard let graph = navGraph else { return [] }
        return graph.nodes.values
            .sorted { $0.id < $1.id }
            .enumerated()
            .map { i, node in
                node.toNavDestination(id: i,
                                      widthMeters:  floorWidthMeters,
                                      heightMeters: floorHeightMeters)
            }
    }

    var body: some View {
        Group {
            if let originUV = confirmedOriginUV {
                ARNavActiveView(
                    floorPlanImage:        floorPlanImage,
                    destinations:          destinations,
                    floorWidthMeters:      floorWidthMeters,
                    floorHeightMeters:     floorHeightMeters,
                    originUV:              originUV,
                    headingOffsetDegrees:  headingOffsetDegrees,
                    navGraph:              navGraph,
                    onRecalibrationNeeded: { confirmedOriginUV = nil }
                )
            } else {
                OriginCalibrationView(
                    floorPlanImage: floorPlanImage,
                    onConfirm:      { confirmedOriginUV = $0 },
                    onDismiss:      { dismiss() }
                )
            }
        }
    }
}
