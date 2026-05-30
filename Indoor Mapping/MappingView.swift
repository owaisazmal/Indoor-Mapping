import SwiftUI
import ARKit

// MARK: - AR Camera Feed

struct ARCameraView: UIViewRepresentable {
    let mapper: IndoorMapper
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = mapper.arKitSession
        v.automaticallyUpdatesLighting = false
        v.showsStatistics = false
        return v
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Mini-map canvas (feature points + path, shown while scanning)

struct MapCanvas: View {
    @ObservedObject var mapper: IndoorMapper

    var body: some View {
        Canvas { ctx, size in
            guard !mapper.cameraPath.isEmpty,
                  let t = mapper.makeTransform(size: size) else { return }

            for p in mapper.featurePoints {
                let sp = t.canvas(worldX: p.x, worldZ: p.z)
                ctx.fill(Path(ellipseIn: CGRect(x: sp.x-1.5, y: sp.y-1.5, width: 3, height: 3)),
                         with: .color(.gray.opacity(0.55)))
            }
            if mapper.cameraPath.count > 1 {
                var shape = Path()
                shape.move(to: t.canvas(worldX: mapper.cameraPath[0].x, worldZ: mapper.cameraPath[0].z))
                for p in mapper.cameraPath.dropFirst() {
                    shape.addLine(to: t.canvas(worldX: p.x, worldZ: p.z))
                }
                ctx.stroke(shape, with: .color(.blue), lineWidth: 1.5)
            }
            if let last = mapper.cameraPath.last {
                let lp = t.canvas(worldX: last.x, worldZ: last.z)
                ctx.fill(Path(ellipseIn: CGRect(x: lp.x-5, y: lp.y-5, width: 10, height: 10)),
                         with: .color(.red))
            }
        }
    }
}

// MARK: - Floor plan canvas with tappable POI pins

struct FloorPlanPOICanvas: View {
    let floorPlanImage: UIImage
    let pois:           [MappedPOI]
    var onTap:          ((CGPoint) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Image(uiImage: floorPlanImage)
                    .resizable().scaledToFill()
                    .frame(width: w, height: h).clipped()

                ForEach(pois) { poi in
                    POIPin(poi: poi)
                        .position(x: poi.mapUV.x * w, y: poi.mapUV.y * h)
                        .allowsHitTesting(false)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { val in
                            onTap?(CGPoint(x: val.location.x / w, y: val.location.y / h))
                        }
                    )
            }
        }
    }
}

struct POIPin: View {
    let poi: MappedPOI
    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Circle().fill(poiColors[poi.colorIndex]).frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                Image(systemName: poi.icon).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
            }
            Text(poi.name).font(.system(size: 9, weight: .semibold)).foregroundColor(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.black.opacity(0.55)).clipShape(Capsule())
        }
    }
}

// MARK: - Shared mapping UI components

struct SensorBadge: View {
    let icon: String; let label: String; let active: Bool
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 13))
            Text(label).font(.system(size: 8, weight: .semibold))
        }
        .foregroundColor(active ? .green : Color.white.opacity(0.35))
        .frame(width: 44, height: 38).background(Color.black.opacity(0.55)).cornerRadius(8)
    }
}

struct MappingStatChip: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold())
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06)).cornerRadius(10)
    }
}

// MARK: - View modifiers

struct MappingRoundedCorner: Shape {
    var radius: CGFloat; var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

extension View {
    func mappingCornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(MappingRoundedCorner(radius: radius, corners: corners))
    }
    func actionButtonStyle(color: Color) -> some View {
        self.font(.headline).foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(color).cornerRadius(14)
    }
}

// MARK: - POI name entry sheet

private struct AddPOISheet: View {
    let onAdd:    (String, String) -> Void
    let onCancel: () -> Void

    @State private var name         = ""
    @State private var selectedIcon = "mappin"
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                TextField("e.g. Exit B, Lab 203, Cafeteria", text: $name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .submitLabel(.done).padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Icon").font(.subheadline).foregroundColor(.secondary).padding(.horizontal)
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 12) {
                        ForEach(poiIconOptions, id: \.self) { icon in
                            Button { selectedIcon = icon } label: {
                                Image(systemName: icon).font(.title3)
                                    .foregroundColor(selectedIcon == icon ? .white : .primary)
                                    .frame(width: 52, height: 52)
                                    .background(selectedIcon == icon ? Color.blue : Color.primary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Name this Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let t = name.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        onAdd(t, selectedIcon)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).bold()
                }
            }
        }
        .onAppear { nameFocused = true }
    }
}

// MARK: - Main Mapping View

struct MappingView: View {
    var floorPlanImage:    UIImage
    var floorWidthMeters:  Double = 30
    var floorHeightMeters: Double = 20
    var onComplete:        ((MappingResult) -> Void)? = nil

    @StateObject private var mapper = IndoorMapper()

    @State private var showScanView  = false
    @State private var pendingUV:    CGPoint?
    @State private var showPOISheet  = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if showScanView {
                scanModeView
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                floorPlanModeView
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showScanView)
        .sheet(isPresented: $showPOISheet) {
            AddPOISheet { name, icon in
                if let uv = pendingUV {
                    mapper.addPOI(mapUV: uv, name: name, icon: icon,
                                  floorWidthM: floorWidthMeters,
                                  floorHeightM: floorHeightMeters)
                }
                showPOISheet = false; pendingUV = nil
            } onCancel: {
                showPOISheet = false; pendingUV = nil
            }
            .presentationDetents([.medium])
        }
        .onDisappear { mapper.pauseSession() }
    }

    // MARK: - Floor plan mode

    private var floorPlanModeView: some View {
        ZStack {
            FloorPlanPOICanvas(floorPlanImage: floorPlanImage, pois: mapper.pois) { uv in
                pendingUV = uv; showPOISheet = true
            }
            .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                HStack {
                    Button {
                        onComplete?(mapper.makeMappingResult())
                        mapper.pauseSession(); dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 32))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("Mark Locations").font(.subheadline.bold()).foregroundColor(.white)
                        Text("on your floor plan").font(.caption2).foregroundColor(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.45)).clipShape(Capsule())
                    Spacer()
                    Color.clear.frame(width: 32, height: 32)
                }
                .padding(.horizontal, 16).padding(.top, 12)

                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                    Text(mapper.pois.isEmpty
                         ? "Tap your floor plan to add a navigation point"
                         : "Tap to add more, or press Done below")
                }
                .font(.caption.bold()).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color.indigo.opacity(0.92)).clipShape(Capsule())
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .padding(.top, 10)

                Spacer()

                VStack(spacing: 14) {
                    if !mapper.pois.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(mapper.pois) { poi in
                                    HStack(spacing: 6) {
                                        Image(systemName: poi.icon)
                                            .font(.caption.bold()).foregroundColor(.white)
                                            .frame(width: 26, height: 26)
                                            .background(poiColors[poi.colorIndex]).clipShape(Circle())
                                        Text(poi.name).font(.caption.bold()).lineLimit(1)
                                        Button { mapper.removePOI(poi.id) } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.08)).clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.and.ellipse").foregroundColor(.secondary)
                            Text("Your locations will appear here")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }

                    Divider()

                    Button {
                        mapper.startPreview()
                        mapper.startMapping()
                        withAnimation { showScanView = true }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "camera.viewfinder").foregroundColor(.secondary)
                            Text("Optional: Walk & Scan with AR Camera").foregroundColor(.secondary)
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.primary.opacity(0.05)).cornerRadius(12)
                    }

                    Button {
                        onComplete?(mapper.makeMappingResult())
                        mapper.pauseSession(); dismiss()
                    } label: {
                        Label(
                            mapper.pois.isEmpty
                                ? "Done — No Locations Added"
                                : "Use \(mapper.pois.count) Location\(mapper.pois.count == 1 ? "" : "s") for AR Navigation",
                            systemImage: mapper.pois.isEmpty ? "checkmark" : "arkit"
                        )
                        .actionButtonStyle(color: mapper.pois.isEmpty ? .gray : .green)
                    }
                }
                .padding(20).background(.ultraThinMaterial)
                .mappingCornerRadius(24, corners: [.topLeft, .topRight])
            }
        }
    }

    // MARK: - AR Scan mode

    private var scanModeView: some View {
        ZStack {
            ARCameraView(mapper: mapper).edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        mapper.stopMapping()
                        mapper.pauseSession()
                        withAnimation { showScanView = false }
                    } label: {
                        Image(systemName: "chevron.left.circle.fill").font(.system(size: 32))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        SensorBadge(icon: "camera.fill",   label: "Camera", active: true)
                        SensorBadge(icon: "gyroscope",     label: "IMU",    active: mapper.hasGyro)
                        SensorBadge(icon: "barometer",     label: "Baro",   active: mapper.hasBarometer)
                        SensorBadge(icon: "location.fill", label: "GPS",    active: mapper.hasGPS)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12)

                Text(mapper.trackingState)
                    .font(.caption.bold()).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(trackingPillColor.opacity(0.9)).clipShape(Capsule())
                    .padding(.top, 8)

                Spacer()

                HStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.75))
                        if mapper.cameraPath.isEmpty {
                            VStack(spacing: 4) {
                                Image(systemName: "figure.walk").foregroundColor(.gray).font(.title3)
                                Text("Walk to build map").font(.caption2).foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(8)
                        } else {
                            MapCanvas(mapper: mapper).padding(6)
                        }
                    }
                    .frame(width: 158, height: 158)
                    .padding(.trailing, 16).padding(.bottom, 12)
                }

                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        MappingStatChip(label: "Points", value: "\(mapper.pointCount)")
                        MappingStatChip(label: "Area",   value: String(format: "%.0f m²", mapper.scannedAreaM2))
                        if mapper.hasBarometer {
                            MappingStatChip(label: "Floor Δ",
                                            value: String(format: "%.1f m", mapper.currentFloor))
                        }
                    }

                    Text("Walk through every room so the camera can capture the space.")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)

                    Button {
                        mapper.stopMapping()
                        mapper.pauseSession()
                        withAnimation { showScanView = false }
                    } label: {
                        Label("Finish Scanning — Back to Floor Plan",
                              systemImage: "checkmark.circle.fill")
                        .actionButtonStyle(color: .indigo)
                    }
                }
                .padding(20).background(.ultraThinMaterial)
                .mappingCornerRadius(24, corners: [.topLeft, .topRight])
            }
        }
    }

    private var trackingPillColor: Color {
        switch mapper.trackingState {
        case "Tracking":        return .green
        case "Initializing...": return .orange
        default:                return .red
        }
    }
}
