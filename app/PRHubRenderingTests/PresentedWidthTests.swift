#if DEBUG && os(iOS)
    import Foundation
    @testable import PRHub
    @testable import PRKit
    import SwiftUI
    import Testing
    import UIKit

    /// The app's account sheet keeps its width over a screen constrained by PRKit's readable-content margins.
    @MainActor
    @Suite(.serialized)
    struct PresentedWidthTests {
        @Test func deleteAccountKeepsTheSheetsWidth() async throws {
            try await Self.check("delete-account") { DeleteAccountSheet(login: "octocat") {} }
        }

        /// Opens `content` over a readable-width screen, pictures the window, and checks the widest scroll view in it.
        private static func check(
            _ name: String, @ViewBuilder content: @escaping () -> some View
        ) async throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            if ProcessInfo.processInfo.isiOSAppOnMac {
                scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 0, y: 0, width: 1811, height: 1268)))
            }
            let screen = Color.clear.frame(width: 44, height: 44)
            let presenting = screen.sheet(isPresented: .constant(true), content: content)
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            // As the app has it: the screen under it keeps to a readable width.
            window.rootViewController = UIHostingController(
                rootView: presenting.frame(maxWidth: .infinity, maxHeight: .infinity).readableContentWidth()
            )
            window.makeKeyAndVisible()
            defer {
                window.rootViewController?.dismiss(animated: false)
                window.isHidden = true
                window.rootViewController = nil
                window.windowScene = nil
                previousKeyWindow?.makeKey()
            }
            let scroll = try await presentedScroll(in: window, name: name)

            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(drawn, "The presented window was drawn")
            try Attachment.record(#require(image.pngData()), named: "\(name)-\(Int(window.bounds.width)).png")
            let inset = scroll.adjustedContentInset
            #expect(scroll.contentSize.width >= scroll.bounds.width * 0.6,
                    "\(name)'s content is \(Int(scroll.contentSize.width)) pt of \(Int(scroll.bounds.width))")
            #expect(inset.left < 40 && inset.right < 40, "\(name)'s side margins are \(inset.left) and \(inset.right)")
        }

        private static func presentedScroll(in window: UIWindow, name: String) async throws -> UIScrollView {
            let deadline = ContinuousClock.now + .seconds(5)
            var previousBounds: CGRect?
            var previousContentSize: CGSize?
            while true {
                window.layoutIfNeeded()
                if let controller = window.rootViewController?.presentedViewController,
                   !controller.isBeingPresented, controller.transitionCoordinator == nil,
                   let presented = controller.viewIfLoaded
                {
                    presented.layoutIfNeeded()
                    if let scroll = scrollViews(in: presented).max(by: { $0.bounds.width < $1.bounds.width }),
                       scroll.bounds.width > 0, scroll.contentSize.width > 0
                    {
                        if scroll.bounds == previousBounds, scroll.contentSize == previousContentSize {
                            return scroll
                        }
                        previousBounds = scroll.bounds
                        previousContentSize = scroll.contentSize
                    }
                }
                try #require(ContinuousClock.now < deadline, "\(name) has a presented scroll view with settled layout")
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        private static func scrollViews(in view: UIView) -> [UIScrollView] {
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }
    }

#endif
