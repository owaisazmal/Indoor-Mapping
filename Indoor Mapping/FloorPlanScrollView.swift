import SwiftUI
import UIKit

// MARK: - FloorPlanScrollBase
//
// Shared UIScrollView subclass used by both FloorPlanScrollView (read-only,
// ReadyView) and FloorPlanPinView (tap-to-place pin, OriginCalibrationView).
//
// Initialises to aspect-fit zoom in layoutSubviews — guaranteed to fire
// after the view has a valid frame, unlike updateUIView which can be called
// while bounds are still zero.

class FloorPlanScrollBase: UIScrollView {
    var floorPlanImage: UIImage?
    weak var imageView: UIImageView?
    private var didConfigureZoom = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didConfigureZoom,
              bounds.size.width > 0, bounds.size.height > 0,
              let img = floorPlanImage, img.size.width > 0 else { return }
        didConfigureZoom = true

        let iv = imageView!
        iv.frame    = CGRect(origin: .zero, size: img.size)
        contentSize = img.size

        let scale        = min(bounds.width / img.size.width, bounds.height / img.size.height)
        minimumZoomScale = scale
        maximumZoomScale = max(scale * 5, 1.0)
        setZoomScale(scale, animated: false)
        centerContent()
    }

    func centerContent() {
        let x = max(0, (bounds.width  - contentSize.width)  / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
}

// MARK: - FloorPlanScrollView
//
// Read-only, zoomable floor plan viewer.  Used in ReadyView.
// No tap handler — just display + pinch/pan.

struct FloorPlanScrollView: UIViewRepresentable {

    let image: UIImage

    func makeUIView(context: Context) -> FloorPlanScrollBase {
        let sv              = FloorPlanScrollBase()
        sv.delegate         = context.coordinator
        sv.floorPlanImage   = image
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator   = false
        sv.bouncesZoom      = true
        sv.backgroundColor  = .systemBackground

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleToFill
        sv.addSubview(iv)
        sv.imageView = iv
        context.coordinator.imageView = iv
        return sv
    }

    func updateUIView(_ sv: FloorPlanScrollBase, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in sv: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ sv: UIScrollView) {
            (sv as? FloorPlanScrollBase)?.centerContent()
        }
    }
}
