import SwiftUI

#if os(iOS)
/// More's way back to its list, for a tab under More that brings its own navigation bar.
struct MoreNavigation {
    let back: () -> Void
}

/// Behind a tab's own `NavigationStack`: when More's navigation controller is over the tab (the phone, with more tabs
/// than the bar holds), hides More's bar while the tab shows, so the stack's bar is the only one, and hands the tab
/// More's way back. Gives `nil` where no controller is over the tab. More's bar comes back as the tab leaves More's
/// stack, by its back button or a tap on More.
struct MoreNavigationProbe: UIViewControllerRepresentable {
    let found: (MoreNavigation?) -> Void

    func makeUIViewController(context: Context) -> Probe { Probe(found: found) }

    func updateUIViewController(_ probe: Probe, context: Context) {}

    final class Probe: UIViewController {
        let found: (MoreNavigation?) -> Void

        init(found: @escaping (MoreNavigation?) -> Void) {
            self.found = found
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// More's controller, kept for the way out: by then the probe may be off its stack.
        private weak var more: UINavigationController?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let more = navigationController else {
                Task { @MainActor in found(nil) }
                return
            }
            self.more = more
            more.setNavigationBarHidden(true, animated: animated)
            let back = MoreNavigation { [weak more] in more?.popToRootViewController(animated: true) }
            Task { @MainActor in found(back) }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Covered by a picker the tab stays More's top screen; leaving, More's list is on top already.
            if let more, more.topViewController !== screen(in: more) {
                more.setNavigationBarHidden(false, animated: animated)
            }
        }

        /// The screen on `more`'s stack this probe is part of.
        private func screen(in more: UINavigationController) -> UIViewController {
            var screen: UIViewController = self
            while let parent = screen.parent, parent !== more {
                screen = parent
            }
            return screen
        }
    }
}
#endif
