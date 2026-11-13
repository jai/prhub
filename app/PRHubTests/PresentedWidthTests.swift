#if DEBUG && os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PRHub
@testable import PRKit

/// What opens over a screen kept to a readable width (`readableContentWidth`) keeps its own width: that screen's scroll
/// margins reached into Ask's sheet and, on a Mac's wide window, left its chat a strip (UI bug 015). On "My Mac
/// (Designed for iPad)" the window is first made 1811×1268, as Jai's Mac had it. Each records a picture,
/// `<name>-<width>.png`.
@MainActor
@Suite(.serialized)
struct PresentedWidthTests {
    @Test func askKeepsTheSheetsWidth() async throws {
        var samples = PRSampleSet.prHub
        samples.askChat = PRHubScreenshots.askChat(["-PRHubAskAnswered"])
        let environment = PRHubEnvironment.offline(
            config: DeviceConfig(features: [.askAI], login: PRSampleSet.prHubLogin), samples: samples,
            worker: URL(string: "https://pr-review.octocat.workers.dev")!, defaultsSuite: "ask-width-\(UUID())",
            isSample: false
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
        let presenting: AnyView = switch presentation {
        case .sheet: AnyView(screen.sheet(isPresented: .constant(true), content: content))
        case .popover: AnyView(screen.popover(isPresented: .constant(true), content: content))
        }
        let window = UIWindow(windowScene: scene)
        // As the app has it: the screen under it keeps to a readable width.
        window.rootViewController = UIHostingController(
            rootView: presenting.frame(maxWidth: .infinity, maxHeight: .infinity).readableContentWidth()
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(3))

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(try #require(image.pngData()), named: "\(name)-\(Int(window.bounds.width)).png")

        let presented = try #require(window.rootViewController?.presentedViewController?.view, "\(name) is up")
        let widest = scrollViews(in: presented).max { $0.bounds.width < $1.bounds.width }
        let scroll = try #require(widest, "its scroll view")
        let inset = scroll.adjustedContentInset
        #expect(scroll.contentSize.width >= scroll.bounds.width * 0.6,
                "\(name)'s content is \(Int(scroll.contentSize.width)) pt of \(Int(scroll.bounds.width))")
        #expect(inset.left < 40 && inset.right < 40, "\(name)'s side margins are \(inset.left) and \(inset.right)")
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews)
    }
}
#endif
