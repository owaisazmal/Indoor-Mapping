import SwiftUI
import MapKit
import PhotosUI

struct ContentView: View {
    // ----------------------------------------------------
    // STATE: MAP OVERLAY & ALIGNMENT
    // ----------------------------------------------------
    @State private var floorPlanImage: UIImage = {
        let config = UIImage.SymbolConfiguration(pointSize: 500)
        return UIImage(systemName: "photo.artframe", withConfiguration: config) ?? UIImage()
    }()
    
    // Dynamic properties controlling the image on the map
    @State private var overlayCenter = CLLocationCoordinate2D(latitude: 37.334800, longitude: -122.009000)
    @State private var overlayWidthMeters: Double = 150
    @State private var overlayHeightMeters: Double = 150
    @State private var overlayRotationDegrees: Double = 0
    @State private var overlayAlpha: Double = 1.0
    
    // The exact GPS coordinate currently in the center of the user's screen
    @State private var currentMapCenter = CLLocationCoordinate2D(latitude: 37.334800, longitude: -122.009000)
    
    // UI Modes
    @State private var isEditingMap: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    
    // ----------------------------------------------------
    // STATE: ROUTING & LOCATION
    // ----------------------------------------------------
    @State private var showingDirectionsSheet = false
    @State private var activeRoute: MKPolyline? = nil
    @State private var selectedDestination: String? = nil
    
    @StateObject private var locationManager = LocationManager()
    @State private var trackingMode: MKUserTrackingMode = .follow
    @State private var showingMappingView = false
    @State private var showBuildingBoundary = false
    
    var body: some View {
        ZStack(alignment: .top) {
            
            // 1. MAP LAYER
            IndoorMapView(
                floorPlanImage: floorPlanImage,
                overlayCenter: overlayCenter,
                overlayWidthMeters: overlayWidthMeters,
                overlayHeightMeters: overlayHeightMeters,
                overlayRotationDegrees: overlayRotationDegrees,
                overlayAlpha: overlayAlpha,
                route: activeRoute,
                userLocation: locationManager.userLocation,
                userHeading: locationManager.userHeading,
                showBuildingBoundary: showBuildingBoundary,
                trackingMode: $trackingMode,
                currentMapCenter: $currentMapCenter
            )
            .edgesIgnoringSafeArea(.all)
            
            // 2. CROSSHAIR (Only visible when editing)
            if isEditingMap {
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundColor(.blue)
                    .background(Circle().fill(Color.white.opacity(0.5)).frame(width: 30, height: 30))
                    .position(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
            
            // 3. UI OVERLAYS
            VStack(spacing: 0) {
                
                // --- TOP BAR AREA ---
                if !isEditingMap {
                    // Standard Search Bar
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        
                        Text("Search building...")
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        // Upload Custom Map Button
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                            Image(systemName: "map.badge.plus")
                                .font(.title3)
                                .foregroundColor(.blue)
                                .padding(8)
                                .background(Color.blue.opacity(0.1))
                                .clipShape(Circle())
                        }
                        .onChange(of: selectedPhotoItem) { newItem in
                            Task {
                                if let data = try? await newItem?.loadTransferable(type: Data.self),
                                   let uiImage = UIImage(data: data) {
                                    floorPlanImage = uiImage
                                    let aspect = uiImage.size.height / uiImage.size.width
                                    overlayHeightMeters = overlayWidthMeters * aspect
                                    overlayCenter = currentMapCenter
                                    overlayAlpha = 0.6
                                    withAnimation(.spring()) {
                                        isEditingMap = true
                                    }
                                }
                            }
                        }
                        
                        Button(action: {}) {
                            Image(systemName: "mic.fill")
                                .font(.title3)
                                .foregroundColor(.secondary)
                                .padding(8)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    
                } else {
                    // Alignment Mode Header
                    Text("Alignment Mode")
                        .font(.subheadline).bold()
                        .foregroundColor(.primary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
                
                // --- BOTTOM UI AREA ---
                if isEditingMap {
                    // Alignment Editor Panel
                    VStack(spacing: 20) {
                        Button(action: {
                            withAnimation(.spring()) {
                                overlayCenter = currentMapCenter
                            }
                        }) {
                            Label("Snap Image to Crosshair", systemImage: "scope")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.blue)
                                .cornerRadius(14)
                        }
                        
                        VStack(spacing: 16) {
                            // Size Slider
                            HStack(spacing: 15) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .foregroundColor(.secondary)
                                    .frame(width: 24)
                                Slider(value: Binding(get: {
                                    overlayWidthMeters
                                }, set: { newValue in
                                    overlayWidthMeters = newValue
                                    let aspect = floorPlanImage.size.height / floorPlanImage.size.width
                                    overlayHeightMeters = newValue * aspect
                                }), in: 10...500)
                            }
                            
                            // Rotate Slider
                            HStack(spacing: 15) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundColor(.secondary)
                                    .frame(width: 24)
                                Slider(value: $overlayRotationDegrees, in: 0...360)
                            }
                            
                            // Opacity Slider
                            HStack(spacing: 15) {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundColor(.secondary)
                                    .frame(width: 24)
                                Slider(value: $overlayAlpha, in: 0.2...1.0)
                            }
                        }
                        
                        Button(action: {
                            withAnimation(.spring()) {
                                overlayAlpha = 1.0
                                isEditingMap = false
                            }
                            // Lock the dot to the placed floor plan footprint
                            locationManager.buildingBounds = LocationManager.BuildingBounds(
                                center:          overlayCenter,
                                widthMeters:     overlayWidthMeters,
                                heightMeters:    overlayHeightMeters,
                                rotationDegrees: overlayRotationDegrees
                            )
                            showBuildingBoundary = true
                        }) {
                            Text("Save Alignment")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.green)
                                .cornerRadius(14)
                        }
                    }
                    .padding(24)
                    .background(.regularMaterial)
                    .cornerRadius(24)
                    .shadow(color: .black.opacity(0.15), radius: 15, x: 0, y: 10)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    
                } else {
                    // Standard Navigation Controls
                    HStack(alignment: .bottom) {
                        Spacer()
                        
                        VStack(spacing: 12) {
                            // Recenter/Tracking Button
                            Button(action: {
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
                                    .foregroundColor(trackingMode == .none ? .secondary : .blue)
                                    .frame(width: 54, height: 54)
                                    .background(.regularMaterial)
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                            }

                            // Building Boundary Toggle (only shown after a floor plan is placed)
                            if locationManager.buildingBounds != nil {
                                Button(action: {
                                    showBuildingBoundary.toggle()
                                }) {
                                    Image(systemName: showBuildingBoundary ? "building.2.fill" : "building.2")
                                        .font(.system(size: 20))
                                        .foregroundColor(showBuildingBoundary ? .white : .secondary)
                                        .frame(width: 54, height: 54)
                                        .background(showBuildingBoundary ? Color.indigo : Color(UIColor.systemBackground).opacity(0.9))
                                        .clipShape(Circle())
                                        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                                }
                            }

                            // Scan Space Button
                            Button(action: {
                                showingMappingView = true
                            }) {
                                Image(systemName: "cube.transparent")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                                    .frame(width: 54, height: 54)
                                    .background(Color.indigo)
                                    .clipShape(Circle())
                                    .shadow(color: Color.indigo.opacity(0.35), radius: 8, x: 0, y: 4)
                            }

                            // Get Directions Button
                            Button(action: {
                                showingDirectionsSheet = true
                            }) {
                                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                                    .frame(width: 54, height: 54)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                                    .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                            }
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 30)
                    }
                    .transition(.opacity)
                    
                    // Active Route Card
                    if let destination = selectedDestination {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Navigating to")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .textCase(.uppercase)
                                    Text(destination)
                                        .font(.headline)
                                }
                                Spacer()
                                Button(action: {
                                    withAnimation(.spring()) {
                                        activeRoute = nil
                                        selectedDestination = nil
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.title)
                                }
                            }
                            
                            Divider()
                            
                            HStack {
                                Image(systemName: "figure.walk")
                                    .foregroundColor(.blue)
                                Text("2 mins")
                                    .bold()
                                    .foregroundColor(.blue)
                                Text("• 150 ft")
                                    .foregroundColor(.secondary)
                            }
                            .font(.subheadline)
                        }
                        .padding(20)
                        .background(.regularMaterial)
                        .cornerRadius(20)
                        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: -5)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isEditingMap)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selectedDestination != nil)
        .sheet(isPresented: $showingDirectionsSheet) {
            DirectionsSheet(onSelectDestination: { destination, route in
                withAnimation(.spring()) {
                    self.selectedDestination = destination
                    self.activeRoute = route
                    self.showingDirectionsSheet = false
                }
            })
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showingMappingView) {
            MappingView()
        }
        .onAppear {
            locationManager.requestPermission()
        }
    }
}

// MARK: - Directions Sheet View
struct DirectionsSheet: View {
    var onSelectDestination: (String, MKPolyline) -> Void
    
    let destinations = ["Conference Room A", "Cafeteria", "Restrooms", "Exit"]
    
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
