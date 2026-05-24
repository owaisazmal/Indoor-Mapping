import SwiftUI
import ARKit
import SceneKit
import Combine

// MARK: - Destination model (derived from MappedPOI at runtime)

struct NavDestination: Identifiable {
    let id: Int
    let name: String
    let icon: String
    /// Direct UV on the floor plan image (0–1, origin top-left).
    let mapUV: CGPoint
    /// AR world position recorded during mapping — used for 3-D node placement.
    let worldX: Float
    let worldZ: Float
    let uiColor: UIColor
    var color: Color { Color(uiColor) }
}

extension MappedPOI {
    func toNavDestination(id: Int) -> NavDestination {
        NavDestination(
            id: id, name: name, icon: icon,
            mapUV: mapUV,
            worldX: worldX, worldZ: worldZ,
            uiColor: poiUIColors[colorIndex]
        )
    }
}

// MARK: - Store

final class ARNavStore: NSObject, ObservableObject {

    @Published var userUV      = CGPoint(x: 0.5, y: 0.85)
    @Published var activeNav:   NavDestination?
    @Published var pathUVs:    [CGPoint] = []
    @Published var distMeters: Float = 0

    let session = ARSession()
    let scene   = SCNScene()

    // Floor plan physical dimensions — set by ARNavigationView before start().
    var floorWidthMeters:  Double = 30
    var floorHeightMeters: Double = 20
    // UV at the user's assumed starting position (set from first POI or default).
    var originUV = CGPoint(x: 0.5, y: 0.85)

    private var sessionStartX: Float = 0
    private var sessionStartZ: Float = 0
    private var hasFirstFrame = false
    private var pathNodes: [SCNNode] = []

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        hasFirstFrame = false
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravityAndHeading  // consistent compass frame with MappingView
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session.pause() }

    func navigate(to dest: NavDestination) {
        activeNav = dest
        rebuildNodes(for: dest)
        pathUVs = [userUV, dest.mapUV]
    }

    func cancel() {
        activeNav = nil
        pathUVs   = []
        clearNodes()
    }

    // MARK: - AR node building

    private func rebuildNodes(for dest: NavDestination) {
        clearNodes()
        let dx = dest.worldX, dz = dest.worldZ
        let dist = sqrt(dx * dx + dz * dz)
        let steps = max(1, Int(dist / 2.5))

        for i in 1...steps {
            let t = Float(i) / Float(steps)
            let p = SCNVector3(dx * t, -0.4, dz * t)
            let crumb = makeCrumb(at: p, color: dest.uiColor, pulse: i == steps)
            scene.rootNode.addChildNode(crumb)
            pathNodes.append(crumb)
        }

        let sign = makeSign(dest.name, at: SCNVector3(dx, 0.45, dz), color: dest.uiColor)
        scene.rootNode.addChildNode(sign)
        pathNodes.append(sign)
    }

    private func clearNodes() {
        pathNodes.forEach { $0.removeFromParentNode() }
        pathNodes.removeAll()
    }

    private func makeCrumb(at p: SCNVector3, color: UIColor, pulse: Bool) -> SCNNode {
        let geo = SCNSphere(radius: pulse ? 0.20 : 0.11)
        geo.firstMaterial?.diffuse.contents  = color.withAlphaComponent(0.9)
        geo.firstMaterial?.emission.contents = color.withAlphaComponent(0.45)
        geo.firstMaterial?.lightingModel = .constant
        let n = SCNNode(geometry: geo)
        n.position = p
        if pulse {
            let a = CABasicAnimation(keyPath: "scale")
            a.fromValue = SCNVector3(1, 1, 1); a.toValue = SCNVector3(1.4, 1.4, 1.4)
            a.duration = 0.85; a.autoreverses = true; a.repeatCount = .infinity
            n.addAnimation(a, forKey: "pulse")
        }
        return n
    }

    private func makeSign(_ label: String, at p: SCNVector3, color: UIColor) -> SCNNode {
        let root = SCNNode()
        root.position = p
        let bb = SCNBillboardConstraint(); bb.freeAxes = .Y
        root.constraints = [bb]

        let texture = makeSignTexture(label, color: color)
        let aspectW: CGFloat = 2.2
        let aspectH: CGFloat = aspectW * (texture.size.height / texture.size.width)
        let bg = SCNPlane(width: aspectW, height: aspectH)
        bg.firstMaterial?.diffuse.contents = texture
        bg.firstMaterial?.isDoubleSided = true
        bg.firstMaterial?.lightingModel = .constant
        root.addChildNode(SCNNode(geometry: bg))

        let stemH = CGFloat(abs(p.y) + 0.6)
        let stem = SCNCylinder(radius: 0.028, height: stemH)
        stem.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.70)
        stem.firstMaterial?.lightingModel = .constant
        let sn = SCNNode(geometry: stem)
        sn.position = SCNVector3(0, -Float(stemH) / 2 - Float(aspectH) / 2, 0)
        root.addChildNode(sn)
        return root
    }

    private func makeSignTexture(_ label: String, color: UIColor) -> UIImage {
        let size = CGSize(width: 440, height: 110)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 22)
            color.withAlphaComponent(0.94).setFill(); path.fill()
            UIColor.white.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 3; path.stroke()
            let para = NSMutableParagraphStyle()
            para.alignment = .center; para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 34),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para
            ]
            ("→  \(label)" as NSString).draw(
                in: CGRect(x: 20, y: (size.height - 44) / 2, width: size.width - 40, height: 50),
                withAttributes: attrs)
        }
    }
}

// MARK: - ARSessionDelegate

extension ARNavStore: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let x = frame.camera.transform.columns.3.x
        let z = frame.camera.transform.columns.3.z
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Capture the session-start position on the very first frame
            if !self.hasFirstFrame {
                self.sessionStartX = x; self.sessionStartZ = z; self.hasFirstFrame = true
            }
            // Track user UV as origin + relative displacement / floor dimensions
            let dx = CGFloat(x - self.sessionStartX) / CGFloat(self.floorWidthMeters)
            let dz = CGFloat(z - self.sessionStartZ) / CGFloat(self.floorHeightMeters)
            self.userUV = CGPoint(x: self.originUV.x + dx, y: self.originUV.y + dz)
            // Distance to active nav destination (in AR world metres)
            if let nav = self.activeNav {
                let ex = x - nav.worldX, ez = z - nav.worldZ
                self.distMeters = sqrt(ex * ex + ez * ez)
            }
        }
    }
}

// MARK: - AR scene view wrapper

struct ARNavSceneView: UIViewRepresentable {
    let store: ARNavStore
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = store.session; v.scene = store.scene
        v.automaticallyUpdatesLighting = true
        v.antialiasingMode = .multisampling4X
        return v
    }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}

// MARK: - 2D floor-plan canvas

struct NavMapCanvas: View {
    let image: UIImage
    let userUV: CGPoint
    let pathUVs: [CGPoint]
    let destinations: [NavDestination]
    let selectedId: Int?
    let onTap: (NavDestination) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: w, height: h)
                    .clipped()
                    .overlay(Color.black.opacity(0.18))

                Canvas { ctx, size in
                    // Dashed path (white border + blue fill)
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

                    // Destination pins — use mapUV directly
                    for d in destinations {
                        let pt = CGPoint(x: d.mapUV.x * size.width, y: d.mapUV.y * size.height)
                        let sel = d.id == selectedId
                        let r: CGFloat = sel ? 11 : 7.5
                        ctx.fill(oval(center: pt, r: r + 2.5), with: .color(.white))
                        ctx.fill(oval(center: pt, r: r), with: .color(Color(d.uiColor)))
                        if sel {
                            ctx.stroke(oval(center: pt, r: r + 5),
                                       with: .color(Color(d.uiColor).opacity(0.35)), lineWidth: 3)
                        }
                    }

                    // User dot (Google-style: white ring + blue fill)
                    let up = CGPoint(x: userUV.x * size.width, y: userUV.y * size.height)
                    ctx.fill(oval(center: up, r: 10.5), with: .color(.white))
                    ctx.fill(oval(center: up, r: 7.5),  with: .color(.blue))
                }

                // Invisible tap targets for destination pins
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
    let onSelect: (NavDestination) -> Void

    var body: some View {
        NavigationView {
            List(destinations) { dest in
                Button { onSelect(dest) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: dest.icon)
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color(dest.uiColor))
                            .clipShape(Circle())
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

// MARK: - Main AR navigation view

struct ARNavigationView: View {
    /// The floor plan image the user aligned on the main map.
    let floorPlanImage: UIImage
    /// Result from a mapping session — nil if the user hasn't scanned yet.
    let mappingResult: MappingResult?
    /// Physical floor plan size in metres (passed from ContentView overlay sliders).
    var floorWidthMeters:  Double = 30
    var floorHeightMeters: Double = 20

    @StateObject private var store = ARNavStore()
    @Environment(\.dismiss) private var dismiss
    @State private var showList = false

    private var pois: [MappedPOI] { mappingResult?.pois ?? [] }
    private var destinations: [NavDestination] {
        pois.enumerated().map { i, poi in poi.toNavDestination(id: i) }
    }

    var body: some View {
        ZStack(alignment: .top) {

            if pois.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {

                    // ── TOP HALF: AR Camera ───────────────────────────────────
                    ZStack(alignment: .bottom) {
                        ARNavSceneView(store: store).ignoresSafeArea(edges: .top)

                        if let nav = store.activeNav {
                            HStack(spacing: 8) {
                                Image(systemName: nav.icon)
                                Text(store.distMeters < 1.5
                                     ? "You've arrived at \(nav.name)!"
                                     : String(format: "%.0f m · %@", store.distMeters, nav.name))
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Color(nav.uiColor).opacity(0.93))
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .frame(maxHeight: .infinity)

                    Rectangle().fill(Color(UIColor.separator)).frame(height: 1)

                    // ── BOTTOM HALF: 2D Floor Plan ────────────────────────────
                    ZStack(alignment: .bottomTrailing) {
                        NavMapCanvas(
                            image: floorPlanImage,
                            userUV: store.userUV,
                            pathUVs: store.pathUVs,
                            destinations: destinations,
                            selectedId: store.activeNav?.id,
                            onTap: { store.navigate(to: $0) }
                        )

                        if store.activeNav != nil {
                            Button { store.cancel() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.primary,
                                                     Color(UIColor.systemBackground).opacity(0.85))
                            }
                            .padding(14)
                            .transition(.opacity)
                        } else {
                            Button { showList = true } label: {
                                Label("Where to?", systemImage: "magnifyingglass")
                                    .font(.subheadline.bold()).foregroundColor(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(Color.blue).clipShape(Capsule())
                                    .shadow(color: .blue.opacity(0.35), radius: 6, y: 3)
                            }
                            .padding(14)
                            .transition(.opacity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .onAppear {
                    store.floorWidthMeters  = floorWidthMeters
                    store.floorHeightMeters = floorHeightMeters
                    // Seed the map origin from the first POI's UV if available
                    if let first = destinations.first {
                        store.originUV = first.mapUV
                    }
                    store.start()
                }
                .onDisappear { store.stop() }
                .sheet(isPresented: $showList) {
                    DestinationPicker(destinations: destinations) { dest in
                        store.navigate(to: dest)
                        showList = false
                    }
                    .presentationDetents([.medium])
                }
            }

            // ── TOP NAV BAR (always visible) ──────────────────────────────────
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial)
                        .clipShape(Circle())
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
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.activeNav?.id)
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mappin.slash")
                .font(.system(size: 56)).foregroundColor(.secondary)
            Text("No locations mapped yet")
                .font(.title3.bold())
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
    }
}
