---
name: project-architecture
description: Indoor Mapping app architecture — file roles, orphaned code, refactoring decisions made in May 2026
metadata:
  type: project
---

SwiftUI/ARKit indoor mapping iOS app (Xcode 26.1, iOS 26.1, SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).

## Source file roles

| File | Role |
|------|------|
| `Models.swift` | Shared data models: `MappingResult`, `MappedPOI`, `poiUIColors/poiColors/poiIconOptions` |
| `FloorPlanState.swift` | `@MainActor ObservableObject` holding all floor plan overlay state (image, center, size, rotation, alpha, isEditing) |
| `ContentView.swift` | Main coordinator; uses `FloorPlanState` + `LocationManager`; private subviews: `CrosshairOverlay`, `MapSearchBar`, `AlignmentEditorView`, `MapControlsView`, `FloatingActionButton`, `RouteCardView`, `DirectionsSheet` |
| `LocationManager.swift` | GPS + CMMotion with EKF-lite smoothing; clamps position to `BuildingBounds` |
| `IndoorMapView.swift` | `UIViewRepresentable` for MKMapView with custom overlays (floor plan, boundary polygon, accuracy circle, route) |
| `IndoorMapOverlay.swift` | `MKOverlay` subclass with `boundingMapRect = .world` (dynamic overlay) |
| `IndoorMapOverlayRenderer.swift` | `MKOverlayRenderer` drawing rotated/scaled floor plan image |
| `MappingView.swift` | AR scanning + POI placement; `IndoorMapper` engine with 4fps-throttled `@Published` arrays |
| `ARNavigationView.swift` | Split-screen AR navigation; `ARNavStore` manages session + 3D path crumbs |
| `SensorFusionEngine.swift` | ES-EKF skeleton (Kalman gain omitted); currently unused |
| `NavigationController.swift` | RealityKit path renderer; currently orphaned (never instantiated) |
| `PathfindingService.swift` | A* over `MapNode` graph; currently orphaned (only used by NavigationController) |

## Key architectural decisions

**PBXFileSystemSynchronizedRootGroup**: any `.swift` file dropped in `Indoor Mapping/` is auto-compiled — no `.pbxproj` edits needed for new source files.

**Performance fix — MapCanvas throttle**: `IndoorMapper` accumulates AR feature points into private `_featureBuffer`/`_pathBuffer` (not `@Published`) and flushes to `@Published featurePoints`/`cameraPath` at ≤4fps via `CACurrentMediaTime()` comparison. Reduces Canvas redraws from 60fps → 4fps during scanning. Tracking state updates are deduplicated to avoid spurious `objectWillChange` fires.

**FloorPlanState**: extracted from ContentView to give the overlay alignment state a single source of truth. `setWidth()` maintains aspect ratio atomically.

**Why:** ContentView was a 400-line God View with 15+ `@State` vars, no separation of concerns.
**How to apply:** Keep overlay state in `FloorPlanState`, not ContentView. Pass as `@ObservedObject` to subviews.
