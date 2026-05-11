import SwiftUI
import MapKit
import PhotosUI

struct ContentView: View {
    // Example coordinates pinning the image to a physical location.
    let floorPlanBounds = [
        CLLocationCoordinate2D(latitude: 37.334800, longitude: -122.009000), // Top Left
        CLLocationCoordinate2D(latitude: 37.333000, longitude: -122.007000)  // Bottom Right
    ]
    
    // The currently loaded floor plan image
    @State private var floorPlanImage: UIImage = {
        let config = UIImage.SymbolConfiguration(pointSize: 500)
        return UIImage(systemName: "photo.artframe", withConfiguration: config) ?? UIImage()
    }()
    
    // Photo Picker State
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    
    // Routing State
    @State private var showingDirectionsSheet = false
    @State private var activeRoute: MKPolyline? = nil
    @State private var selectedDestination: String? = nil
    
    // Location Tracking State
    @StateObject private var locationManager = LocationManager()
    @State private var trackingMode: MKUserTrackingMode = .none
    
    var body: some View {
        ZStack(alignment: .top) {
            
            // Map Layer
            IndoorMapView(floorPlanImage: floorPlanImage, bounds: floorPlanBounds, route: activeRoute, trackingMode: $trackingMode)
                .edgesIgnoringSafeArea(.all)
            
            // Top Search Bar (UI Mock) & Map Upload Button
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                Text("Search here")
                    .foregroundColor(.gray)
                Spacer()
                
                // Photo Picker to Upload Map
                PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "map.fill")
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                }
                .onChange(of: selectedPhotoItem) { newItem in
                    Task {
                        // Retrieve selected asset in the form of Data
                        if let data = try? await newItem?.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            // Update the map image
                            floorPlanImage = uiImage
                        }
                    }
                }
                
                Image(systemName: "mic.fill")
                    .foregroundColor(.blue)
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(25)
            .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 5)
            .padding(.horizontal)
            .padding(.top, 10)
            
            // Bottom UI
            VStack {
                Spacer()
                
                HStack(alignment: .bottom) {
                    Spacer()
                    
                    // Floating Action Buttons (like Google Maps)
                    VStack(spacing: 16) {
                        Button(action: {
                            // Toggle Tracking Mode: None -> Follow -> Follow with Heading
                            if trackingMode == .none {
                                trackingMode = .follow
                            } else if trackingMode == .follow {
                                trackingMode = .followWithHeading
                            } else {
                                trackingMode = .follow
                            }
                        }) {
                            Image(systemName: trackingMode == .followWithHeading ? "location.north.line.fill" : (trackingMode == .follow ? "location.fill" : "location"))
                                .font(.system(size: 20))
                                .foregroundColor(trackingMode == .none ? .gray : .blue)
                                .frame(width: 50, height: 50)
                                .background(Color(.systemBackground))
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 5)
                        }
                        
                        Button(action: {
                            showingDirectionsSheet = true
                        }) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.blue)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 5)
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 30)
                }
                
                // Active Route Info Card
                if let destination = selectedDestination {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Navigating to: \(destination)")
                                .font(.headline)
                            Spacer()
                            Button(action: {
                                // Cancel route
                                activeRoute = nil
                                selectedDestination = nil
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                                    .font(.title2)
                            }
                        }
                        Text("2 mins • 150 ft")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(15)
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: -5)
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
        }
        .sheet(isPresented: $showingDirectionsSheet) {
            DirectionsSheet(onSelectDestination: { destination, route in
                self.selectedDestination = destination
                self.activeRoute = route
                self.showingDirectionsSheet = false
            })
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            locationManager.requestPermission()
        }
    }
}

// MARK: - Directions Sheet View
struct DirectionsSheet: View {
    var onSelectDestination: (String, MKPolyline) -> Void
    
    // Mock Destinations
    let destinations = [
        "Conference Room A",
        "Cafeteria",
        "Restrooms",
        "Exit"
    ]
    
    var body: some View {
        NavigationView {
            List(destinations, id: \.self) { destination in
                Button(action: {
                    generateMockRoute(for: destination)
                }) {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundColor(.blue)
                        Text(destination)
                            .foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle("Get Directions")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func generateMockRoute(for destination: String) {
        // We create a mock MKPolyline over the bounds we defined earlier
        // Real implementation would use A* pathfinding via PathfindingService over MapNodes
        let mockCoordinates = [
            CLLocationCoordinate2D(latitude: 37.334000, longitude: -122.008000),
            CLLocationCoordinate2D(latitude: 37.334200, longitude: -122.008200),
            CLLocationCoordinate2D(latitude: 37.334500, longitude: -122.008500),
            CLLocationCoordinate2D(latitude: 37.334700, longitude: -122.008100)
        ]
        
        let route = MKPolyline(coordinates: mockCoordinates, count: mockCoordinates.count)
        onSelectDestination(destination, route)
    }
}

#Preview {
    ContentView()
}
