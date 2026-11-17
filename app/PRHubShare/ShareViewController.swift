import PRKitCore
import UIKit

/// PRHub in the share sheet: a shared GitHub PR link opens in PRHub through its `prhub-pr://open` handoff
/// (docs/api.md, "Opening a pull request in PRHub"). Any other link gets a short note and changes nothing.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handOff() }
    }

    private func handOff() async {
        guard let shared = await sharedURL(), let handoff = PRHubOpenLink.handoff(for: shared) else {
            finish(note: "PRHub opens GitHub pull request links.")
            return
        }
        guard openContainingApp(handoff) else {
            finish(note: "Open PRHub to see this pull request.")
            return
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The first web URL the share sheet holds.
    private func sharedURL() async -> URL? {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) where provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
            }
            if let url {
                return url
            }
        }
        return nil
    }

    /// An extension may not open URLs itself; the app it runs in can. `UIApplication.open` is unavailable to
    /// extension code at compile time, so it is called by its selector on the UIApplication in the responder chain.
    private func openContainingApp(_ url: URL) -> Bool {
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func finish(note: String) {
        let alert = UIAlertController(title: "PRHub", message: note, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }
}
