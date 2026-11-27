import Foundation
@testable import PRKit
import SwiftUI
import Testing

/// The top of a PR's page, drawn in a phone's window on a made-up PR: the line under the title says when the PR was
/// opened, and each of its tickets is a line a finger can hit. The words for when are `PRDetailOpenedTests`'.
@MainActor
@Suite(.serialized)
struct PRPageHeaderRenderingTests {
    private static let size = CGSize(width: 393, height: 852)

    /// The PR's page under its title, as `PRScreen` shows it.
    private func page(_ detail: PullRequestDetail) async throws -> DrawnWindow {
        let (session, _) = try await PRSamplePage.session(detail)
        let view = NavigationStack {
            PRDescriptionView(session: session, detail: detail, showDiff: {}, reviewChanges: {})
                .navigationTitle(session.label)
                .inlineNavigationTitle()
        }
        .environment(\.loadsAuthorAvatars, false)
        return try DrawnWindow(view, size: Self.size, in: .light)
    }

    /// Jai's feedback, 2026-11-26: the PR did not say when it was opened. A PR that has the date says more on the
    /// line that says which PR it is, after those words, on the page's first screen; nothing else on the page moves.
    @Test func theLineUnderTheTitleSaysWhenThePRWasOpened() async throws {
        let silent = try await page(PRSamplePage.detail())
        defer { silent.close() }
        let dated = try await page(PRSamplePage.detail(opened: .now.addingTimeInterval(-3 * 86400)))
        defer { dated.close() }
        let before = try await silent.picture(named: "pr-page-not-dated")
        let after = try await dated.picture(named: "pr-page-opened")
        try #require(before.width == after.width && before.height == after.height)

        var rows: [Int] = [], columns: [Int] = []
        for row in 0 ..< after.height {
            let changed = (0 ..< after.width).filter { after[$0, row].distance(to: before[$0, row]) >= 24 }
            if let first = changed.first {
                rows.append(row)
                columns.append(first)
            }
        }
        let scale = dated.scale(of: after)
        let top = try #require(rows.first, "a PR that says when it was opened shows it") / Int(scale)
        let bottom = try #require(rows.last) / Int(scale)
        #expect(bottom - top <= 24, "one line of small words, and nothing under it moved: \(top) to \(bottom)")
        #expect(CGFloat(bottom) < Self.size.height - dated.footInset, "on screen as the page opens")
        // "acme/web#412" stays where it was: the date comes after it.
        let start = try #require(columns.min()) / Int(scale)
        #expect(start >= 60, "the date follows which PR it is: it starts at \(start)")
    }

    /// Jai's feedback, 2026-11-24: "I can't tap on the Linear ticket on a PR view." The line was as tall as its words,
    /// 16 pt. Each ticket on the page is a row high: a second ticket makes the page that much longer.
    @Test func eachTicketOnThePageIsARowHigh() async throws {
        let one = try await page(PRSamplePage.detail(tickets: [PRSamplePage.ticket]))
        defer { one.close() }
        let two = try await page(PRSamplePage.detail(tickets: [PRSamplePage.ticket, PRSamplePage.secondTicket]))
        defer { two.close() }
        _ = try await one.picture()
        _ = try await two.picture(named: "pr-page-tickets")
        let line = try two.pageHeight() - one.pageHeight()
        #expect(line >= PRStyle.rowHeight, "a ticket's line is \(line) pt tall, a finger's height at least")
    }
}
