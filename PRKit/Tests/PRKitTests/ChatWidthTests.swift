#if os(iOS)
import PRKitDesign
import SwiftUI
import Testing
import UIKit
@testable import PRKit

/// A chat's bubbles follow the chat's width when it changes after they were laid out: a sheet that opens narrow and
/// grows, as Ask's does on a Mac (UI bug 015), or a window resized. An agent's answer then takes the chat's width from
/// its leading edge, not the width it was first given.
@MainActor
struct ChatWidthTests {
    private static let answer = """
        Partly. The retry path is covered, but two things are not:

        - **Reachability:** at this head, `recordOtpVerified` has no caller in `functions/src` outside tests, so the \
        recovery screen can never reach it. Either call it from `verifyOtp` or drop it from this PR.
        """

    @Observable
    final class Frames {
        var bubble: CGRect = .zero
    }

    /// The bubble's row in a window `first` wide, then `then` wide.
    private static func row(first: CGFloat, then: CGFloat) async throws -> (CGRect, CGFloat) {
        let frames = Frames()
        let chat = ChatScroll {
            LazyVStack(alignment: .leading, spacing: Space.sm) {
                SessionBubble(title: nil, text: "Is this change tested?", date: nil, isMine: true)
                SessionBubble(title: nil, text: answer, date: nil, isMine: false)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.bubble = $0 }
            }
            .padding(.horizontal, Space.md)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: first, height: 800))
        window.rootViewController = UIHostingController(rootView: chat)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await settle(window)
        window.frame.size.width = then
        try await settle(window)
        return (frames.bubble, then)
    }

    private static func settle(_ window: UIWindow) async throws {
        for _ in 0..<5 {
            window.rootViewController?.view.frame = window.bounds
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func anAnswersRowTakesTheChatsWidthWhenTheChatWidens() async throws {
        let (row, width) = try await Self.row(first: 350, then: 1150)
        #expect(row.width > width * 0.9, "the row is \(Int(row.width)) pt of \(Int(width))")
        #expect(row.minX < Space.md + 1, "the row starts at \(Int(row.minX))")
    }
}
#endif
