import UIKit

/// The remote desktop takes swipes from the left edge for itself: no edge swipe back while it shows.
enum InteractivePopGesture {
    @MainActor static var blocked = false
}

/// SwiftUI turns the edge swipe back off on pages that hide the navigation bar, such as the terminal.
/// Keep it on for every pushed page, and let it win over the terminal's own pans that start near the edge.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        return viewControllers.count > 1 && transitionCoordinator == nil && !InteractivePopGesture.blocked
    }
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === interactivePopGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer
            && !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
    }
}
