import SwiftUI

#if os(iOS)
/// Says whether a navigation controller is over the view it sits behind: More's, on the phone.
struct NavigationControllerProbe: UIViewControllerRepresentable {
    let found: (Bool) -> Void

    func makeUIViewController(context: Context) -> Probe { Probe(found: found) }

    func updateUIViewController(_ probe: Probe, context: Context) {}

    final class Probe: UIViewController {
        let found: (Bool) -> Void

        init(found: @escaping (Bool) -> Void) {
            self.found = found
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            let isUnder = navigationController != nil
            Task { @MainActor in found(isUnder) }
        }
    }
}
#endif
