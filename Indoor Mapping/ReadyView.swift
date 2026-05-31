import SwiftUI

struct ReadyView: View {

    let floorPlanImage:    UIImage
    let navGraph:          NavGraph
    let floorWidthMeters:  Double
    let floorHeightMeters: Double
    let onReset:           () -> Void

    @State private var showingARNav     = false
    @State private var showResetConfirm = false

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {

                FloorPlanScrollView(image: floorPlanImage)
                    .edgesIgnoringSafeArea([.bottom, .horizontal])

                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, Color(UIColor.systemBackground).opacity(0.92)],
                        startPoint: .top, endPoint: .bottom)
                        .frame(height: 60)
                        .allowsHitTesting(false)

                    VStack(spacing: 12) {
                        Button { showingARNav = true } label: {
                            Label("Start AR Navigation", systemImage: "scope")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(Color.indigo).cornerRadius(14)
                        }

                        HStack(spacing: 12) {
                            infoChip(icon: "ruler",
                                     text: "\(Int(floorWidthMeters))×\(Int(floorHeightMeters)) m")
                            let nc = navGraph.nodes.count
                            infoChip(icon: "mappin.circle",
                                     text: "\(nc) node\(nc == 1 ? "" : "s")")
                            let zc = navGraph.walkableRects.count
                            infoChip(icon: "rectangle.dashed",
                                     text: zc == 0 ? "No zones"
                                         : "\(zc) zone\(zc == 1 ? "" : "s")")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 34)
                    .background(Color(UIColor.systemBackground).opacity(0.92))
                }
            }
            .navigationTitle("Floor Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) { showResetConfirm = true } label: {
                            Label("Reset App Data", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingARNav) {
            ARNavigationView(
                floorPlanImage:    floorPlanImage,
                floorWidthMeters:  floorWidthMeters,
                floorHeightMeters: floorHeightMeters,
                navGraph:          navGraph
            )
        }
        .confirmationDialog("Reset all app data?",
                            isPresented: $showResetConfirm,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) { onReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The floor plan image and navigation graph will be permanently deleted.")
        }
    }

    private func infoChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2.bold())
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(Capsule())
    }
}
