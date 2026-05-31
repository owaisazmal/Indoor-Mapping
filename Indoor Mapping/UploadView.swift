import SwiftUI
import PhotosUI

// MARK: - UploadView
//
// State: .uploadRequired
// The user selects a floor plan image from Photos and enters the building's
// physical dimensions in meters. Both are required before proceeding.

struct UploadView: View {

    /// Called with (image, widthMeters, heightMeters) when the user taps Save.
    let onSave: (UIImage, Double, Double) -> Void

    @State private var pickerItem:  PhotosPickerItem?
    @State private var image:       UIImage?
    @State private var widthText    = "50"
    @State private var heightText   = "30"
    @State private var isLoading    = false

    private var canSave: Bool {
        image != nil && parsedWidth != nil && parsedHeight != nil
    }
    private var parsedWidth:  Double? { Double(widthText).flatMap  { $0 > 0 ? $0 : nil } }
    private var parsedHeight: Double? { Double(heightText).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationView {
            Form {

                // ── Image picker ──────────────────────────────────────────────
                Section("Floor Plan Image") {
                    if let img = image {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 200)
                            .cornerRadius(10)
                            .listRowInsets(.init())
                    }

                    PhotosPicker(selection: $pickerItem, matching: .images,
                                 photoLibrary: .shared()) {
                        HStack {
                            if isLoading {
                                ProgressView().tint(.blue)
                            } else {
                                Image(systemName: "photo.badge.plus")
                                    .foregroundColor(.blue)
                            }
                            Text(image == nil ? "Select Floor Plan" : "Change Image")
                                .foregroundColor(.blue)
                        }
                    }
                    .disabled(isLoading)
                }

                // ── Physical dimensions ───────────────────────────────────────
                Section {
                    HStack {
                        Text("Width")
                        Spacer()
                        TextField("50", text: $widthText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("m").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Height")
                        Spacer()
                        TextField("30", text: $heightText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("m").foregroundColor(.secondary)
                    }
                } header: {
                    Text("Building Dimensions")
                } footer: {
                    Text("Used to scale AR tracking to real-world metres. Measure the floor's longest edges.")
                }

                // ── Save ──────────────────────────────────────────────────────
                Section {
                    Button("Save & Continue") {
                        guard let img = image,
                              let w   = parsedWidth,
                              let h   = parsedHeight else { return }
                        onSave(img, w, h)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(!canSave)
                }
            }
            .navigationTitle("Set Up Floor Plan")
            .navigationBarTitleDisplayMode(.large)
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            isLoading = true
            Task {
                if let data  = try? await item.loadTransferable(type: Data.self),
                   let uiImg = UIImage(data: data) {
                    await MainActor.run { image = uiImg }
                }
                await MainActor.run { isLoading = false }
            }
        }
    }
}
