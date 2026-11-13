#if DEBUG && os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PRHub
@testable import PRKit

/// Ask's sheet with a long answer, presented in the app's window: on "My Mac (Designed for iPad)" the window is first
/// made 1811×1268, as Jai's Mac had it for UI bug 015. The chat keeps the sheet's width: the screen's readable-width
/// margins (`readableContentWidth`) once reached into the sheet and left a strip. Records a picture of the window,
/// `ask-sheet-<width>.png`.
@MainActor
struct AskSheetWidthTests {
    @Test func picturesTheSheetWithALongAnswer() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 0, y: 0, width: 1811, height: 1268)))
        }
        var samples = PRSampleSet.prHub
        samples.askChat = PRHubScreenshots.askChat(["-PRHubAskAnswered"])
        let environment = PRHubEnvironment.offline(
            config: DeviceConfig(features: [.askAI], login: PRSampleSet.prHubLogin), samples: samples,
            worker: URL(string: "https://pr-review.octocat.workers.dev")!, defaultsSuite: "ask-width-\(UUID())",
            isSample: false
        )
        let session = environment.prs.model.session(for: PullRequestRef(repo: "acme/web", number: 412))
        session.askChat = samples.askChat
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            // As the app has it: the PR's screen keeps to a readable width (`readableContentWidth`), and Ask opens over it.
            rootView: Color.clear.sheet(isPresented: .constant(true)) { PRAskSheet(session: session) }
                .readableContentWidth()
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(3))

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(try #require(image.pngData()), named: "ask-sheet-\(Int(window.bounds.width)).png")

        let sheet = try #require(window.rootViewController?.presentedViewController?.view, "the sheet is up")
        let chat = try #require(Self.scrollViews(in: sheet).max { $0.bounds.width < $1.bounds.width }, "the chat")
        let inset = chat.adjustedContentInset
        #expect(chat.contentSize.width >= chat.bounds.width * 0.6,
                "the chat's content is \(Int(chat.contentSize.width)) pt of \(Int(chat.bounds.width))")
        #expect(inset.left < 40 && inset.right < 40, "the chat's side margins are \(inset.left) and \(inset.right)")
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews)
    }
}
#endif
