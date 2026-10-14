import AVFoundation
import SwiftUI
import UIKit

// UIKit owns layer layout; only the capture queue changes its session/connections.
nonisolated struct HandPreviewTarget: @unchecked Sendable {
    let layer: AVCaptureVideoPreviewLayer
}

struct HandCameraPreview: UIViewRepresentable {
    let showsPreview: Bool
    let preparationID: UUID?
    let onConnect: (HandPreviewTarget, Bool) -> Void
    let onDisconnect: (HandPreviewTarget) -> Void
    let onVisible: (UUID) -> Void

    func makeUIView(context: Context) -> HandPreviewUIView {
        let view = HandPreviewUIView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onVisible = onVisible
        view.onDisconnect = onDisconnect
        view.showsPreview = showsPreview
        view.preparationID = preparationID
        view.observePreview()
        onConnect(HandPreviewTarget(layer: view.previewLayer), showsPreview)
        return view
    }

    func updateUIView(_ uiView: HandPreviewUIView, context: Context) {
        let visibilityChanged = uiView.showsPreview != showsPreview
        let needsLayout = visibilityChanged || uiView.preparationID != preparationID
        uiView.onVisible = onVisible
        uiView.showsPreview = showsPreview
        uiView.preparationID = preparationID
        if visibilityChanged { onConnect(HandPreviewTarget(layer: uiView.previewLayer), showsPreview) }
        if needsLayout { uiView.setNeedsLayout() }
    }

    static func dismantleUIView(_ uiView: HandPreviewUIView, coordinator: ()) {
        uiView.releasePreview()
    }
}

final class HandPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onVisible: ((UUID) -> Void)?
    var onDisconnect: ((HandPreviewTarget) -> Void)?
    var showsPreview = false
    var preparationID: UUID?
    private var acknowledgedID: UUID?
    private var previewObserver: NSKeyValueObservation?

    func observePreview() {
        previewObserver = previewLayer.observe(\.isPreviewing, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reportVisiblePreview() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let preparationID, acknowledgedID != preparationID {
            DispatchQueue.main.async { [weak self] in self?.reportVisiblePreview() }
        }
    }

    func releasePreview() {
        previewObserver = nil
        onVisible = nil
        onDisconnect?(HandPreviewTarget(layer: previewLayer))
        onDisconnect = nil
    }

    private func reportVisiblePreview() {
        guard showsPreview, let id = preparationID, acknowledgedID != id,
              let window, bounds.width > 0, bounds.height > 0,
              window.bounds.intersects(convert(bounds, to: window)),
              previewLayer.isPreviewing, previewLayer.connection?.isEnabled == true else { return }
        acknowledgedID = id
        onVisible?(id)
    }
}
