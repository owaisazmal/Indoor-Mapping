// GraphBuilderView.swift
// One-time developer tool: place NavNodes (POIs), draw NavEdges (routes),
// and define walkable zones — all exported as a single JSON file.

import SwiftUI
import UIKit

// MARK: - Private builder models

private struct BuilderNode: Identifiable {
    let id:   String
    let name: String
    let uv:   CGPoint
    var icon: String = "mappin.fill"
}

private struct BuilderEdge: Identifiable {
    let id          = UUID()
    let fromID:     String
    let toID:       String
    let accessible: Bool
}

private enum BuilderMode { case addNodes, addEdges, defineBounds }

private enum UndoAction {
    case addedNode(id: String)
    case addedEdge(id: UUID)
    case addedZone
}

// MARK: - GraphBuilderView

struct GraphBuilderView: View {

    let floorPlanImage: UIImage
    var onExport: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var nodes:         [BuilderNode] = []
    @State private var edges:         [BuilderEdge] = []
    @State private var walkableRects: [CGRect]      = []
    @State private var mode:          BuilderMode   = .addNodes
    @State private var undoStack:     [UndoAction]  = []

    // Node-add flow
    @State private var pendingTapUV:    CGPoint?
    @State private var showNodeSheet    = false
    @State private var draftNodeID      = ""
    @State private var draftNodeName    = ""
    @State private var draftNodeIcon    = "mappin.fill"
    @State private var duplicateIDError = false

    // Edge-add flow
    @State private var edgeSourceID:  String?
    @State private var edgeTargetID:  String?
    @State private var showEdgeDialog = false

    // Bounds-draw flow
    @State private var dragStartUV:   CGPoint? = nil
    @State private var dragCurrentUV: CGPoint? = nil

    // Export
    @State private var exportedJSON    = ""
    @State private var showExportSheet = false

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                mapCanvas
                controlChrome
            }
            .navigationTitle("Graph Builder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { performUndo() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(undoStack.isEmpty)

                    Button { runExport() } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(nodes.isEmpty)
                }
            }
        }
        .onChange(of: mode) { _ in
            edgeSourceID = nil; dragStartUV = nil; dragCurrentUV = nil
        }
        .sheet(isPresented: $showNodeSheet, onDismiss: { pendingTapUV = nil }) {
            nodeEntrySheet.presentationDetents([.large])
        }
        .confirmationDialog(edgeDialogTitle, isPresented: $showEdgeDialog, titleVisibility: .visible) {
            Button("Accessible  (elevator / ramp / corridor)") { commitEdge(accessible: true)  }
            Button("Stairs only", role: .destructive)          { commitEdge(accessible: false) }
            Button("Cancel",      role: .cancel)               { cancelEdge()                  }
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheet.presentationDetents([.large])
        }
    }

    // MARK: - Canvas

    private var mapCanvas: some View {
        GeometryReader { geo in
            let layout = ImageLayout.fit(
                container: geo.size,
                image: CGSize(width: floorPlanImage.size.width,
                               height: floorPlanImage.size.height))
            ZStack {
                Color(UIColor.secondarySystemBackground).edgesIgnoringSafeArea(.all)

                Image(uiImage: floorPlanImage)
                    .resizable().scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .overlay(Color.black.opacity(0.08))

                Canvas { ctx, _ in
                    drawBounds(ctx: ctx, layout: layout)
                    drawEdges(ctx: ctx, layout: layout)
                    drawNodes(ctx: ctx, layout: layout)
                }
                .allowsHitTesting(false)

                ForEach(nodes) { node in
                    let pt = layout.point(uv: node.uv)
                    Text(node.id)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                        .position(x: pt.x, y: pt.y - 20)
                        .allowsHitTesting(false)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        guard mode != .defineBounds else { return }
                        handleTap(at: location, layout: layout)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .local)
                            .onChanged { v in
                                guard mode == .defineBounds else { return }
                                dragStartUV   = layout.clampedUV(point: v.startLocation)
                                dragCurrentUV = layout.clampedUV(point: v.location)
                            }
                            .onEnded { v in
                                guard mode == .defineBounds else { return }
                                commitZone(start: layout.clampedUV(point: v.startLocation),
                                           end:   layout.clampedUV(point: v.location))
                            }
                    )
            }
        }
        .edgesIgnoringSafeArea(.all)
    }

    // MARK: - Canvas draw helpers

    private func drawBounds(ctx: GraphicsContext, layout: ImageLayout) {
        for r in walkableRects {
            let sr = layout.screenRect(uvRect: r)
            ctx.fill(Path(sr), with: .color(.green.opacity(0.12)))
            ctx.stroke(Path(sr), with: .color(.green.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2.5, dash: [8, 4]))
        }
        if let s = dragStartUV, let e = dragCurrentUV {
            let uv = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                            width: abs(e.x - s.x), height: abs(e.y - s.y))
            let sr = layout.screenRect(uvRect: uv)
            ctx.fill(Path(sr), with: .color(.green.opacity(0.08)))
            ctx.stroke(Path(sr), with: .color(.green.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
    }

    private func drawEdges(ctx: GraphicsContext, layout: ImageLayout) {
        for edge in edges {
            guard let a = nodes.first(where: { $0.id == edge.fromID }),
                  let b = nodes.first(where: { $0.id == edge.toID }) else { continue }
            var line = Path()
            line.move(to: layout.point(uv: a.uv))
            line.addLine(to: layout.point(uv: b.uv))
            ctx.stroke(line,
                       with: .color((edge.accessible ? Color.green : Color.orange).opacity(0.9)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    private func drawNodes(ctx: GraphicsContext, layout: ImageLayout) {
        for node in nodes {
            let c        = layout.point(uv: node.uv)
            let isSource = node.id == edgeSourceID
            let color    = poiColors[abs(node.id.hashValue) % poiColors.count]
            if isSource {
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: c.x-17, y: c.y-17, width: 34, height: 34)),
                    with: .color(.yellow), style: StrokeStyle(lineWidth: 2.5))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x-10, y: c.y-10, width: 20, height: 20)),
                     with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x-7, y: c.y-7, width: 14, height: 14)),
                     with: isSource ? .color(.yellow) : .color(color))
        }
    }

    // MARK: - Chrome

    private var controlChrome: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                Text("Nodes").tag(BuilderMode.addNodes)
                Text("Edges").tag(BuilderMode.addEdges)
                Text("Zones").tag(BuilderMode.defineBounds)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
            .background(.ultraThinMaterial)

            Text(hintText)
                .font(.caption.bold()).foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.black.opacity(0.58))
                .clipShape(Capsule())
                .padding(.top, 6)

            Spacer()

            HStack(spacing: 12) {
                Label("\(nodes.count) nodes",  systemImage: "mappin.circle")
                Label("\(edges.count) edges",  systemImage: "arrow.left.and.right")
                let zc = walkableRects.count
                Label(zc == 0 ? "No zones" : "\(zc) zone\(zc == 1 ? "" : "s")",
                      systemImage: "rectangle.dashed")
                    .foregroundColor(zc > 0 ? .green : .white)
            }
            .font(.caption.bold()).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.black.opacity(0.58))
            .clipShape(Capsule())
            .padding(.bottom, 24)
        }
    }

    private var hintText: String {
        switch mode {
        case .addNodes: return "Tap the floor plan to place a node"
        case .addEdges:
            guard let src = edgeSourceID else { return "Tap a node to start an edge" }
            return "Tap another node  ·  tap \(src) again to cancel"
        case .defineBounds:
            return walkableRects.isEmpty ? "Drag to draw a walkable zone"
                                         : "Drag to add more  ·  undo to remove last"
        }
    }

    // MARK: - Node entry sheet

    private var nodeEntrySheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("e.g. ROOM_101, ELEVATOR_A", text: $draftNodeID)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                } header: {
                    Text("Node ID  (unique, no spaces)")
                } footer: {
                    if duplicateIDError {
                        Text("That ID already exists.").foregroundColor(.red)
                    }
                }

                Section("Display Name") {
                    TextField("e.g. Room 101, Elevator A", text: $draftNodeName)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 12) {
                        ForEach(poiIconOptions, id: \.self) { icon in
                            Button { draftNodeIcon = icon } label: {
                                Image(systemName: icon).font(.title3)
                                    .foregroundColor(draftNodeIcon == icon ? .white : .primary)
                                    .frame(width: 52, height: 52)
                                    .background(draftNodeIcon == icon
                                                ? Color.blue
                                                : Color.primary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Add Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNodeSheet = false; duplicateIDError = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { commitNode() }.bold()
                        .disabled(draftNodeID.trimmingCharacters(in: .whitespaces).isEmpty
                               || draftNodeName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Export sheet

    private var exportSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    Text(exportedJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                Divider()
                VStack(spacing: 12) {
                    if let save = onExport {
                        Button { save(exportedJSON) } label: {
                            Label("Save to App & Continue",
                                  systemImage: "tray.and.arrow.down.fill")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.indigo).cornerRadius(14)
                        }
                    }
                    Button { UIPasteboard.general.string = exportedJSON } label: {
                        Label("Copy JSON", systemImage: "doc.on.doc")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(14)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .navigationTitle("\(nodes.count) nodes · \(edges.count) edges · \(walkableRects.count) zones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showExportSheet = false }
                }
            }
        }
    }

    // MARK: - Tap handling

    private func handleTap(at point: CGPoint, layout: ImageLayout) {
        switch mode {
        case .addNodes:
            guard layout.contains(point) else { return }
            pendingTapUV     = layout.uv(point: point)
            draftNodeID      = ""
            draftNodeName    = ""
            draftNodeIcon    = "mappin.fill"
            duplicateIDError = false
            showNodeSheet    = true

        case .addEdges:
            guard let hit = nearestNode(to: point, layout: layout) else { return }
            if let sourceID = edgeSourceID {
                if hit.id == sourceID { edgeSourceID = nil }
                else { edgeTargetID = hit.id; showEdgeDialog = true }
            } else {
                edgeSourceID = hit.id
                UISelectionFeedbackGenerator().selectionChanged()
            }

        case .defineBounds:
            break
        }
    }

    private func nearestNode(to point: CGPoint, layout: ImageLayout) -> BuilderNode? {
        nodes.first { hypot(layout.point(uv: $0.uv).x - point.x,
                            layout.point(uv: $0.uv).y - point.y) < 24 }
    }

    // MARK: - Commit helpers

    private func commitNode() {
        let id   = draftNodeID.trimmingCharacters(in: .whitespaces)
        let name = draftNodeName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, let uv = pendingTapUV else { return }
        if nodes.contains(where: { $0.id == id }) { duplicateIDError = true; return }
        nodes.append(BuilderNode(id: id, name: name, uv: uv, icon: draftNodeIcon))
        undoStack.append(.addedNode(id: id))
        duplicateIDError = false; showNodeSheet = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func commitEdge(accessible: Bool) {
        guard let from = edgeSourceID, let to = edgeTargetID else { return }
        let edge = BuilderEdge(fromID: from, toID: to, accessible: accessible)
        edges.append(edge)
        undoStack.append(.addedEdge(id: edge.id))
        edgeSourceID = nil; edgeTargetID = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func cancelEdge() { edgeSourceID = nil; edgeTargetID = nil }

    private func commitZone(start: CGPoint, end: CGPoint) {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard rect.width > 0.01, rect.height > 0.01 else { return }
        walkableRects.append(rect)
        undoStack.append(.addedZone)
        dragStartUV = nil; dragCurrentUV = nil
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private var edgeDialogTitle: String {
        guard let f = edgeSourceID, let t = edgeTargetID else { return "Select Edge Type" }
        return "\(f)  →  \(t)"
    }

    // MARK: - Undo

    private func performUndo() {
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .addedNode(let id):
            nodes.removeAll { $0.id == id }
            edges.removeAll { $0.fromID == id || $0.toID == id }
        case .addedEdge(let id):
            edges.removeAll { $0.id == id }
        case .addedZone:
            if !walkableRects.isEmpty { walkableRects.removeLast() }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Export

    private func runExport() {
        let nodeRecords = nodes.map { n in
            NavGraphPayload.NodeRecord(id: n.id, name: n.name,
                                       u: Double(n.uv.x), v: Double(n.uv.y),
                                       icon: n.icon)
        }
        let edgeRecords = edges.map { e in
            NavGraphPayload.EdgeRecord(from: e.fromID, to: e.toID,
                                       weight: nil, accessible: e.accessible)
        }
        let rectRecords = walkableRects.map { r in
            NavGraphPayload.WalkableRectRecord(
                minU: Double(r.minX), minV: Double(r.minY),
                maxU: Double(r.maxX), maxV: Double(r.maxY))
        }
        exportedJSON = NavGraphFactory.encode(
            NavGraphPayload(nodes: nodeRecords, edges: edgeRecords, walkableRects: rectRecords))
        showExportSheet = true
    }
}

// MARK: - ImageLayout

private struct ImageLayout {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    func point(uv: CGPoint) -> CGPoint { CGPoint(x: x + uv.x * w, y: y + uv.y * h) }
    func uv(point: CGPoint) -> CGPoint { CGPoint(x: (point.x - x) / w, y: (point.y - y) / h) }
    func clampedUV(point: CGPoint) -> CGPoint {
        let r = uv(point: point)
        return CGPoint(x: max(0, min(1, r.x)), y: max(0, min(1, r.y)))
    }
    func contains(_ p: CGPoint) -> Bool { p.x >= x && p.y >= y && p.x <= x+w && p.y <= y+h }
    func screenRect(uvRect: CGRect) -> CGRect {
        CGRect(x: x + uvRect.minX * w, y: y + uvRect.minY * h,
               width: uvRect.width * w, height: uvRect.height * h)
    }
    static func fit(container: CGSize, image: CGSize) -> ImageLayout {
        let ia = image.width / max(image.height, 1)
        let ca = container.width / max(container.height, 1)
        let (iw, ih): (CGFloat, CGFloat) = ia > ca
            ? (container.width,  container.width / ia)
            : (container.height * ia, container.height)
        return ImageLayout(x: (container.width  - iw) / 2,
                            y: (container.height - ih) / 2,
                            w: iw, h: ih)
    }
}

#Preview {
    GraphBuilderView(floorPlanImage: UIImage(systemName: "map")!)
}
