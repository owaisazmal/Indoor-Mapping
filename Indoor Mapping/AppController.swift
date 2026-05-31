import SwiftUI
import Combine

// MARK: - Persistent settings

struct FloorPlanSettings: Codable {
    var widthMeters:  Double = 50
    var heightMeters: Double = 30
}

// MARK: - AppState

/// Linear gate: each state requires the previous one to be satisfied.
/// No state can be skipped; no navigation view is reachable until `.ready`.
enum AppState: Equatable {
    case checkingData    // launching — loading from disk
    case uploadRequired  // no floor plan image on disk
    case mappingRequired // image exists but no NavGraph
    case ready           // image + graph both loaded — navigation available
}

// MARK: - AppController

@MainActor
final class AppController: ObservableObject {

    @Published private(set) var state:          AppState       = .checkingData
    @Published private(set) var floorPlanImage: UIImage?
    @Published private(set) var navGraph:       NavGraph?
    @Published private(set) var settings:       FloorPlanSettings = .init()

    // MARK: Disk paths

    private static let docs: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let imageURL:    URL = docs.appendingPathComponent("floorplan.jpg")
    static let graphURL:    URL = docs.appendingPathComponent("navgraph.json")
    private static let settingsKey = "com.indoormapping.settings.v1"

    // MARK: Initialization

    /// Called once on launch from ContentView.onAppear.
    /// Loads all persisted data and routes to the correct initial state.
    func checkData() {
        // Image
        let img = (try? Data(contentsOf: Self.imageURL)).flatMap { UIImage(data: $0) }
        floorPlanImage = img

        // Settings
        if let raw  = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(FloorPlanSettings.self, from: raw) {
            settings = saved
        }

        // Graph — documents directory first, bundle as read-only fallback
        navGraph = NavGraphFactory.loadFromDocuments() ?? NavGraphFactory.load(named: "building_1")

        transition()
    }

    // MARK: State transitions

    /// Persist the uploaded floor plan and move to the mapping step.
    func saveFloorPlan(image: UIImage, widthMeters: Double, heightMeters: Double) {
        floorPlanImage = image
        settings = FloorPlanSettings(widthMeters: widthMeters, heightMeters: heightMeters)

        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: Self.imageURL, options: .atomic)
        }
        if let raw = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(raw, forKey: Self.settingsKey)
        }
        transition()
    }

    /// Persist the exported graph JSON and, if valid, move to the ready state.
    func saveGraph(json: String) {
        try? json.write(to: Self.graphURL, atomically: true, encoding: .utf8)
        navGraph = NavGraphFactory.loadFromDocuments()
        transition()
    }

    /// Wipe all persisted data and return to the upload step.
    func resetAll() {
        try? FileManager.default.removeItem(at: Self.imageURL)
        try? FileManager.default.removeItem(at: Self.graphURL)
        UserDefaults.standard.removeObject(forKey: Self.settingsKey)
        floorPlanImage = nil; navGraph = nil; settings = .init()
        transition()
    }

    // MARK: Private

    private func transition() {
        if floorPlanImage == nil {
            state = .uploadRequired
        } else if navGraph == nil {
            state = .mappingRequired
        } else {
            state = .ready
        }
    }
}
