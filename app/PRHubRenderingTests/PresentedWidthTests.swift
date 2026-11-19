#if DEBUG && os(iOS)
    import DurableNetworking
    import Foundation
    @testable import PRHub
    @testable import PRHubCore
    @testable import PRKit
    import SwiftUI
    import Testing
    import UIKit

    /// What opens over a screen kept to a readable width (`readableContentWidth`) keeps its own width: that screen's scroll
    /// margins reached into Ask's sheet and, on a Mac's wide window, left its chat a strip (UI bug 015). On "My Mac
    /// (Designed for iPad)" the window is first made 1811×1268, as Jai's Mac had it. Each records a picture,
    /// `<name>-<width>.png`.
    @MainActor
    @Suite(.serialized)
    struct PresentedWidthTests {
        @Test func askKeepsTheSheetsWidth() async throws {
            let name = "ask-width-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: name))
            let directory = URL.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                defaults.removePersistentDomain(forName: name)
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    Issue.record(error, "Removing the rendering test's storage")
                }
            }
            var samples = PRSampleSet.prHub
            samples.askChat = PRHubScreenshotEnvironment.askChat(["-PRHubAskAnswered"])
            let environment = try PRHubEnvironment.offline(
                config: DeviceConfig(features: [.askAI], login: PRSampleSet.prHubLogin), samples: samples,
                worker: #require(URL(string: "https://rendering.invalid")), isSample: false,
                usage: UsageAnalytics(hasProject: false, sink: nil, defaults: defaults),
                transport: UnexpectedRenderingRequest(),
                storage: .onDisk(directory: directory, defaults: defaults, sampleConfiguration: defaults), build: .current,
                alertPermission: PRHubAlertPermission(center: .init(status: { .denied }, request: { false }), defaults: defaults),
                network: PRNetwork(isOnline: true)
            )
            let session = environment.prs.model.session(for: PullRequestRef(repo: "acme/web", number: 412))
            session.askChat = samples.askChat
            try await Self.check("ask-sheet", .sheet) { PRAskSheet(session: session) }
        }

        @Test func deleteAccountKeepsTheSheetsWidth() async throws {
            try await Self.check("delete-account", .sheet) { DeleteAccountSheet(login: "octocat") {} }
        }

        @Test func theFilterKeepsThePopoversWidth() async throws {
            try await Self.check("pr-filter", .popover) {
                PRFilterPanel(
                    orgs: ["acme", "octocat"], repoCounts: ["acme/web": 3, "acme/api": 2, "octocat/hello": 1],
                    filter: .constant(PROrgFilter(selected: [])), showsMerged: nil, order: nil, grouping: .constant(.repo)
                )
            }
        }

        enum Presentation {
            case sheet, popover
        }

        /// Opens `content` over a readable-width screen, pictures the window, and checks the widest scroll view in it.
        private static func check(
            _ name: String, _ presentation: Presentation, @ViewBuilder content: @escaping () -> some View
        ) async throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            if ProcessInfo.processInfo.isiOSAppOnMac {
                scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 0, y: 0, width: 1811, height: 1268)))
            }
            let screen = Color.clear.frame(width: 44, height: 44)
            let presenting = switch presentation {
            case .sheet: AnyView(screen.sheet(isPresented: .constant(true), content: content))
            case .popover: AnyView(screen.popover(isPresented: .constant(true), content: content))
            }
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

    private struct UnexpectedRenderingRequest: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            Issue.record("Unexpected rendering request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
            throw URLError(.unsupportedURL)
        }
    }
#endif
