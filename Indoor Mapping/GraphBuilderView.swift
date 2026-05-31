// GraphBuilderView.swift
// Developer-only tool — wrap call-sites in #if DEBUG to exclude from release builds.

import SwiftUI

// MARK: - Local model types

private struct BuilderNode: Identifiable {
    /// Same string used as the NavNode.id — must be unique in the builder.
    let id:   String
    let name: String
    let uv:   CGPoint      // normalised 0-1 on the floor-plan image
}

private struct BuilderEdge: Identifiable {
    let id         = UUID()
    let fromID:    String
    let toID:      String
    let accessible: Bool   // true = elevator/ramp/corridor, false = stairs only
}

private enum BuilderMode {
    case addNodes
    case addEdges
}

// MARK: - GraphBuilderView

struct GraphBuilderView: View {

    let floorPlanImage: UIImage

    @Environment(\.dismiss) private var dismiss

    // ── Graph state ───────────────────────────────────────────────────────────
    @State private var nodes: [BuilderNode] = []
    @State private var edges: [BuilderEdge] = []

    // ── Mode ──────────────────────────────────────────────────────────────────
    @State private var mode: BuilderMode = .addNodes

    // ── Node-add flow ─────────────────────────────────────────────────────────
    @State private var pendingTapUV:  CGPoint?   // UV of the tap that triggered the sheet
    @State private var showNodeSheet  = false
    @State private var draftNodeID    = ""
    @State private var draftNodeName  = ""
    @State private var duplicateIDError = false

    // ── Edge-add flow ─────────────────────────────────────────────────────────
    @State private var edgeSourceID:   String?   // first tapped node
    @State private var edgeTargetID:   String?   // second tapped node (pending dialog)
    @State private var showEdgeDialog  = false

    // ── Export flow ───────────────────────────────────────────────────────────
    @State private var exportedJSON   = ""
    @State private var showExportSheet = false

    // MARK: Body

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
                ToolbarItem(placement: .primaryAction) {
                    Button { runExport() } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(nodes.isEmpty)
                }
            }
        }
        .onChange(of: mode) { _ in
            // Clear edge-selection state when the user changes modes.
            edgeSourceID = nil; edgeTargetID = nil
        }
        // ── Node entry sheet ──────────────────────────────────────────────────
        .sheet(isPresented: $showNodeSheet, onDismiss: { pendingTapUV = nil }) {
            nodeEntrySheet
                .presentationDetents([.medium])
        }
        // ── Edge accessibility dialog ─────────────────────────────────────────
        .confirmationDialog(
            edgeDialogTitle,
            isPresented: $showEdgeDialog,
            titleVisibility: .visible
        ) {
            Button("Accessible  (elevator / ramp / corridor)") {
                commitEdge(accessible: true)
            }
            Button("Stairs only", role: .destructive) {
                commitEdge(accessible: false)
            }
            Button("Cancel", role: .cancel) { cancelEdge() }
        }
        // ── Export sheet ──────────────────────────────────────────────────────
        .sheet(isPresented: $showExportSheet) {
            exportSheet
                .presentationDetents([.large])
        }
    }

    // MARK: - Map canvas

    private var mapCanvas: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Floor plan
                Image(uiImage: floorPlanImage)
                    .resizable().scaledToFill()
                    .frame(width: w, height: h)
                    .clipped()
                    .overlay(Color.black.opacity(0.10))

                // Edges + node circles drawn on a SwiftUI Canvas
                Canvas { ctx, size in
                    drawEdges(ctx: ctx, size: size)
                    drawNodes(ctx: ctx, size: size)
                }
                // The Canvas has no explicit frame so it inherits (w, h) from ZStack.

                // Node ID labels — SwiftUI Text so they stay crisp at all sizes
                ForEach(nodes) { node in
                    Text(node.id)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                        .position(x: node.uv.x * w,
                                  y: node.uv.y * h - 20)
                        .allowsHitTesting(false)
                }

                // Transparent tap capture layer (must be last so it's on top)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { val in
                                handleTap(at: val.location,
                                          canvasSize: CGSize(width: w, height: h))
                            }
                    )
            }
        }
        .edgesIgnoringSafeArea(.all)
    }

    // MARK: - Canvas draw helpers

    private func drawEdges(ctx: GraphicsContext, size: CGSize) {
        for edge in edges {
            guard
                let a = nodes.first(where: { $0.id == edge.fromID }),
                let b = nodes.first(where: { $0.id == edge.toID })
            else { continue }

            let p1 = CGPoint(x: a.uv.x * size.width,  y: a.uv.y * size.height)
            let p2 = CGPoint(x: b.uv.x * size.width,  y: b.uv.y * size.height)

            var line = Path()
            line.move(to: p1)
            line.addLine(to: p2)

            // Green = accessible, red = stairs
            let edgeColor: Color = edge.accessible ? .green : .red
            ctx.stroke(line, with: .color(edgeColor.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    private func drawNodes(ctx: GraphicsContext, size: CGSize) {
        for node in nodes {
            let cx = node.uv.x * size.width
            let cy = node.uv.y * size.height
            let isSource = node.id == edgeSourceID

            // Yellow pulsing ring for the selected edge-source node
            if isSource {
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: cx - 17, y: cy - 17, width: 34, height: 34)),
                    with: .color(.yellow),
                    style: StrokeStyle(lineWidth: 2.5)
                )
            }

            // White halo (improves contrast on any background)
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - 10, y: cy - 10, width: 20, height: 20)),
                with: .color(.white)
            )

            // Filled node circle
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - 7, y: cy - 7, width: 14, height: 14)),
                with: .color(isSource ? .yellow : .blue)
            )
        }
    }

    // MARK: - Control chrome (mode picker + hint + stats)

    private var controlChrome: some View {
        VStack(spacing: 0) {
            // Mode picker
            Picker("Mode", selection: $mode) {
                Text("Add Nodes").tag(BuilderMode.addNodes)
                Text("Add Edges").tag(BuilderMode.addEdges)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.top, 8)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial)

            // Context hint
            Text(hintText)
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.black.opacity(0.58))
                .clipShape(Capsule())
                .padding(.top, 6)

            Spacer()

            // Node / edge counters
            HStack(spacing: 20) {
                Label("\(nodes.count) nodes", systemImage: "mappin.circle")
                Label("\(edges.count) edges", systemImage: "arrow.left.and.right")
            }
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Color.black.opacity(0.58))
            .clipShape(Capsule())
            .padding(.bottom, 24)
        }
    }

    private var hintText: String {
        switch mode {
        case .addNodes:
            return "Tap anywhere to place a node"
        case .addEdges:
            guard let src = edgeSourceID else {
                return "Tap a node to begin an edge"
            }
            return "Tap another node to connect  ·  tap \(src) again to cancel"
        }
    }

    // MARK: - Node entry sheet

    private var nodeEntrySheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("e.g. ROOM_101, ELEVATOR_A, JUNCTION_3",
                              text: $draftNodeID)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                } header: {
                    Text("Node ID (unique, no spaces)")
                } footer: {
                    if duplicateIDError {
                        Text("That ID already exists — choose a different one.")
                            .foregroundColor(.red)
                    }
                }

                Section("Display Name") {
                    TextField("e.g. Room 101, Elevator A, West Corridor",
                              text: $draftNodeName)
                }
            }
            .navigationTitle("Add Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showNodeSheet = false
                        duplicateIDError = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { commitNode() }
                        .bold()
                        .disabled(draftNodeID.trimmingCharacters(in: .whitespaces).isEmpty
                               || draftNodeName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Export sheet

    private var exportSheet: some View {
        NavigationView {
            ScrollView {
                Text(exportedJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Exported JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showExportSheet = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = exportedJSON
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    // MARK: - Tap handling

    private func handleTap(at point: CGPoint, canvasSize: CGSize) {
        let uv = CGPoint(x: point.x / canvasSize.width,
                         y: point.y / canvasSize.height)

        switch mode {

        case .addNodes:
            pendingTapUV     = uv
            draftNodeID      = ""
            draftNodeName    = ""
            duplicateIDError = false
            showNodeSheet    = true

        case .addEdges:
            guard let hit = nearestNode(to: point, canvasSize: canvasSize) else { return }

            if let sourceID = edgeSourceID {
                if hit.id == sourceID {
                    // Tap the same node again → cancel selection
                    edgeSourceID = nil
                } else {
                    // Second node tapped → show accessibility dialog
                    edgeTargetID    = hit.id
                    showEdgeDialog  = true
                }
            } else {
                // First node tapped → set as source
                edgeSourceID = hit.id
            }
        }
    }

    /// Returns the node whose screen position is within 24 pt of `point`, or nil.
    private func nearestNode(to point: CGPoint, canvasSize: CGSize) -> BuilderNode? {
        nodes.first { node in
            let nx = node.uv.x * canvasSize.width
            let ny = node.uv.y * canvasSize.height
            let dx = nx - point.x
            let dy = ny - point.y
            return (dx * dx + dy * dy).squareRoot() < 24
        }
    }

    // MARK: - Commit helpers

    private func commitNode() {
        let id   = draftNodeID.trimmingCharacters(in: .whitespaces)
        let name = draftNodeName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty, let uv = pendingTapUV else { return }

        if nodes.contains(where: { $0.id == id }) {
            duplicateIDError = true
            return
        }
        nodes.append(BuilderNode(id: id, name: name, uv: uv))
        duplicateIDError = false
        showNodeSheet    = false
    }

    private func commitEdge(accessible: Bool) {
        guard let from = edgeSourceID, let to = edgeTargetID else { return }
        edges.append(BuilderEdge(fromID: from, toID: to, accessible: accessible))
        edgeSourceID = nil
        edgeTargetID = nil
    }

    private func cancelEdge() {
        edgeSourceID = nil
        edgeTargetID = nil
    }

    // MARK: - Export

    private var edgeDialogTitle: String {
        guard let from = edgeSourceID, let to = edgeTargetID else {
            return "Select Edge Type"
        }
        return "\(from)  →  \(to)"
    }

    private func runExport() {
        let payload = NavGraphPayload(
            nodes: nodes.map {
                NavGraphPayload.NodeRecord(id: $0.id, name: $0.name,
                                           u: Double($0.uv.x),
                                           v: Double($0.uv.y))
            },
            edges: edges.map {
                NavGraphPayload.EdgeRecord(from: $0.fromID, to: $0.toID,
                                           weight: nil,
                                           accessible: $0.accessible)
            }
        )

        exportedJSON = NavGraphFactory.encode(payload)

        // Primary output: Xcode console (copy/paste into a .json bundle file)
        print("── NavGraph Export (\(nodes.count) nodes, \(edges.count) edges) ──")
        print(exportedJSON)
        print("──────────────────────────────────────────────────────────────────")

        showExportSheet = true
    }
}

// MARK: - Preview

#Preview {
    GraphBuilderView(floorPlanImage: UIImage(systemName: "map")!)
}
