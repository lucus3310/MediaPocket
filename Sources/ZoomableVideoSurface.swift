import AVFoundation
import SwiftUI
import UIKit

// UIKit owns the pinch focal point, panning and content offsets. Only the
// renderer's layer is transformed: no full-resolution UIImage copies at 8x.
struct ZoomableVideoSurface: UIViewRepresentable {
    @Binding var scale: Double
    let requestedScale: Double
    let requestID: Int
    let makeCanvas: @MainActor () -> UIView
    let cleanup: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(scale: $scale, cleanup: cleanup) }

    func makeUIView(context: Context) -> VideoViewport {
        let scroll = VideoViewport(canvas: makeCanvas())
        scroll.delegate = context.coordinator
        context.coordinator.viewport = scroll
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.resetZoom))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ view: VideoViewport, context: Context) {
        context.coordinator.scale = $scale
        if context.coordinator.lastRequestID != requestID {
            context.coordinator.lastRequestID = requestID
            view.setZoomScale(CGFloat(min(max(requestedScale, 1), 8)), animated: true)
        }
    }

    static func dismantleUIView(_ view: VideoViewport, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.cleanup()
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var scale: Binding<Double>
        let cleanup: @MainActor () -> Void
        weak var viewport: VideoViewport?
        var lastRequestID = 0

        init(scale: Binding<Double>, cleanup: @escaping @MainActor () -> Void) {
            self.scale = scale
            self.cleanup = cleanup
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { viewport?.canvas }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let value = Double(scrollView.zoomScale)
            Task { @MainActor [weak self] in self?.scale.wrappedValue = value }
        }
        @objc func resetZoom() { viewport?.setZoomScale(1, animated: true) }
    }
}

@MainActor
final class VideoViewport: UIScrollView {
    let canvas: UIView
    private var viewportSize = CGSize.zero

    init(canvas: UIView) {
        self.canvas = canvas
        super.init(frame: .zero)
        backgroundColor = .black
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = false
        bounces = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        clipsToBounds = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, viewportSize != bounds.size else { return }
        // A rotation changes the fit rectangle. Reset instead of retaining a
        // content offset from an incompatible orientation.
        viewportSize = bounds.size
        setZoomScale(1, animated: false)
        canvas.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
        contentOffset = .zero
    }
}

@MainActor
final class SystemVideoCanvas: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
