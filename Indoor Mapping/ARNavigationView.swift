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

// MARK: - Main AR Navigation View

struct ARNavigationView: View {
    let floorPlanImage:    UIImage
    let mappingResult:     MappingResult?
    var floorWidthMeters:  Double = 30
    var floorHeightMeters: Double = 20

    @StateObject private var store = ARNavStore()
    @Environment(\.dismiss) private var dismiss
    @State private var showList = false

    private var destinations: [NavDestination] {
        (mappingResult?.pois ?? []).enumerated().map { i, poi in poi.toNavDestination(id: i) }
    }

    var body: some View {
        ZStack(alignment: .top) {

            if destinations.isEmpty {
                emptyStateView
            } else {
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
                    if let first = destinations.first { store.originUV = first.mapUV }
                    store.start()
                }
                .onDisappear { store.stop() }
                .sheet(isPresented: $showList) {
                    DestinationPicker(destinations: destinations) { dest in
                        store.navigate(to: dest); showList = false
                    }
                    .presentationDetents([.medium])
                }
            }

            // ── TOP NAV BAR ───────────────────────────────────────────────────────
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
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.activeNav?.id)
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mappin.slash").font(.system(size: 56)).foregroundColor(.secondary)
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
    }
}
