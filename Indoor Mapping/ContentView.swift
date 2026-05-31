import SwiftUI

// MARK: - ContentView
//
// Root view — owns AppController and routes to the correct screen based on
// the strict linear gate: uploadRequired → mappingRequired → ready.
// No navigation or AR feature is reachable until all prerequisites are met.

struct ContentView: View {

    @StateObject private var app = AppController()

    var body: some View {
        Group {
            switch app.state {

            case .checkingData:
                // Momentary — just a spinner while we read from disk on launch.
                ZStack {
                    Color(UIColor.systemBackground).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.4)
                            .tint(.indigo)
                        Text("Loading…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

            case .uploadRequired:
                UploadView { image, width, height in
                    app.saveFloorPlan(image: image,
                                      widthMeters: width,
                                      heightMeters: height)
                }

            case .mappingRequired:
                MappingRequiredView(
                    floorPlanImage: app.floorPlanImage ?? UIImage(),
                    onGraphSaved:   { json in app.saveGraph(json: json) }
                )

            case .ready:
                ReadyView(
                    floorPlanImage:    app.floorPlanImage!,
                    navGraph:          app.navGraph!,
                    floorWidthMeters:  app.settings.widthMeters,
                    floorHeightMeters: app.settings.heightMeters,
                    onReset:           { app.resetAll() }
                )
            }
        }
        .onAppear { app.checkData() }
        .animation(.easeInOut(duration: 0.25), value: app.state)
    }
}

#Preview {
    ContentView()
}
