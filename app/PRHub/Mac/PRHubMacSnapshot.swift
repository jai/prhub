#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `-PRHubSnapshot <file.png>` draws each of the app's own windows after `-PRHubSnapshotDelay`
/// seconds (default 4), as `<file>-1.png`, `<file>-2.png`…, then quits. The windows' own views draw them, so it needs no
/// Screen Recording permission (as Agent Pager's `MacSnapshot`).
@MainActor
enum PRHubMacSnapshot {
    private static var path: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-PRHubSnapshot"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// A Mac whose display sleeps, like the Mac mini, launches the app with no window: with `-PRHubSnapshot`, the app
    /// opens its own once launch is over.
    static func openWindowIfNoneOpened(_ root: @escaping () -> some View) {
        guard path != nil else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !NSApp.windows.contains(where: \.canBecomeMain) else {
                return
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: root()))
            window.setContentSize(NSSize(width: 1_200, height: 800))
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func runIfAsked() async {
        guard let path else {
            return
        }
        let arguments = ProcessInfo.processInfo.arguments
        let delay = arguments.firstIndex(of: "-PRHubSnapshotDelay")
            .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 4
        try? await Task.sleep(for: .seconds(delay))
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        let stem = path.hasSuffix(".png") ? String(path.dropLast(4)) : path
        for (number, window) in windows.enumerated() {
            guard let png = drawn(window) else {
                print("snapshot not drawn: \(window.title)")
                continue
            }
            let file = "\(stem)-\(number + 1).png"
            do {
                try png.write(to: URL(fileURLWithPath: file))
                print("snapshot written: \(file) (\(window.title))")
            } catch {
                print("snapshot not written: \(error)")
            }
        }
        NSApp.terminate(nil)
    }

    private static func drawn(_ window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
