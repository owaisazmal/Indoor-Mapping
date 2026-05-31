import SwiftUI

struct MappingRequiredView: View {

    let floorPlanImage: UIImage
    let onGraphSaved:   (String) -> Void

    @State private var showingBuilder = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 28) {

                    ZStack {
                        Image(uiImage: floorPlanImage)
                            .resizable().scaledToFit()
                            .cornerRadius(14)
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.black.opacity(0.42))
                        VStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 32)).foregroundColor(.white)
                            Text("Navigation Locked")
                                .font(.headline.bold()).foregroundColor(.white)
                            Text("Navigation graph not yet built")
                                .font(.caption).foregroundColor(.white.opacity(0.75))
                        }
                    }
                    .frame(maxHeight: 260)
                    .padding(.horizontal)

                    VStack(spacing: 6) {
                        Text("Build the Navigation Graph")
                            .font(.title3.bold())
                        Text("Place destination nodes, connect them with edges, and draw walkable zones. All three are saved to disk and used by AR navigation.")
                            .font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 14) {
                        stepRow(n: "1", icon: "mappin.and.ellipse",
                                text: "Nodes tab — tap to place named destinations (rooms, exits, elevators)")
                        stepRow(n: "2", icon: "arrow.left.and.right",
                                text: "Edges tab — connect nodes; mark stairs-only edges as inaccessible")
                        stepRow(n: "3", icon: "rectangle.dashed",
                                text: "Zones tab — drag rectangles over walkable areas to constrain the AR dot")
                        stepRow(n: "4", icon: "tray.and.arrow.down.fill",
                                text: "Export → \"Save to App\" to unlock navigation")
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(14)
                    .padding(.horizontal)

                    Button { showingBuilder = true } label: {
                        Label("Open Graph Builder",
                              systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.indigo).cornerRadius(14)
                    }
                    .padding(.horizontal)

                    Spacer(minLength: 40)
                }
                .padding(.top)
            }
            .navigationTitle("Graph Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(isPresented: $showingBuilder) {
            GraphBuilderView(
                floorPlanImage: floorPlanImage,
                onExport: { json in
                    showingBuilder = false
                    onGraphSaved(json)
                }
            )
        }
    }

    private func stepRow(n: String, icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.indigo).frame(width: 28, height: 28)
                Text(n).font(.caption.bold()).foregroundColor(.white)
            }
            Image(systemName: icon).font(.subheadline).foregroundColor(.indigo).frame(width: 20)
            Text(text).font(.subheadline)
        }
    }
}
