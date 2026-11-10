import SwiftUI
import UIKit

/// An image that pinches to zoom.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView(); scroll.delegate = context.coordinator; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        let view = UIImageView(image: image); view.contentMode = .scaleAspectFit; view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view); context.coordinator.image = view
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)])
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) { context.coordinator.image?.image = image }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIScrollViewDelegate { weak var image: UIImageView?; func viewForZooming(in scrollView: UIScrollView) -> UIView? { image } }
}
