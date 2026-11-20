import Foundation
@testable import PRKit
import SwiftUI
import Testing

#if os(iOS)
    import UIKit
#endif

/// The code stops at its sideways edges: a bounce would pull it off the screen's edge, with the file header cut where
/// the table ends. A finger's bounce can't be driven from a test, so this holds the setting that stops it, on the
/// phone and on the Mac; `PRKitDiffSidewaysUITests` and its recording show what the reader sees.
@MainActor
struct DiffTableEdgeTests {
    @Test func theCodeDoesNotBounceSideways() {
        let line = "+" + String(repeating: "x", count: 200) + "\n"
        let document = DiffDocument(data: Data("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n\(line)".utf8))
        let container = DiffTableContainer(
            document: document, rows: DiffRows(document: document, threads: []), viewed: [], font: .standard,
            onContent: {}, actions: actions
        )
        #if os(iOS)
            #expect(!container.bounces)
        #else
            #expect(container.horizontalScrollElasticity == .none)
        #endif
    }

    /// A sync while the diff is open brings a longer diff: the table draws the new one, never the old one's lines at
    /// the new one's indexes (build 306's crash while scrolling).
    @Test func aNewDiffReplacesTheOneTheTableDraws() {
        let container = container(showing: diff(lines: 3))
        let longer = diff(lines: 40)
        container.update(document: longer, rows: DiffRows(document: longer, threads: []))

        #expect(container.document.lines.count == longer.lines.count)
        #if os(iOS)
            for (section, file) in container.rows.files.enumerated() {
                for row in file.rows.indices {
                    _ = container.tableView(container.table, cellForRowAt: IndexPath(row: row, section: section))
                }
            }
        #endif
    }

    /// A shorter diff drops the box whose line it no longer has.
    @Test func aShorterDiffClosesTheBoxOnALineItLacks() {
        let longer = diff(lines: 40)
        let container = container(showing: longer)
        container.composing = longer.lines.count - 1
        let shorter = diff(lines: 3)
        container.update(document: shorter, rows: DiffRows(document: shorter, threads: []))

        #expect(container.composing == nil)
    }

    private func container(showing document: DiffDocument) -> DiffTableContainer {
        DiffTableContainer(
            document: document, rows: DiffRows(document: document, threads: []), viewed: [], font: .standard,
            onContent: {}, actions: actions
        )
    }

    private func diff(lines count: Int) -> DiffDocument {
        let added = (1 ... count).map { "+line \($0)\n" }.joined()
        return DiffDocument(data: Data("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1,\(count) @@\n\(added)".utf8))
    }

    #if os(iOS)
        @Test(arguments: [true, false])
        func codePansKeepEdgeBackAndRestoreTheHostsContentGesture(wasEnabled: Bool) throws {
            let navigation = UINavigationController(rootViewController: UIViewController())
            navigation.pushViewController(UIViewController(), animated: false)
            navigation.loadViewIfNeeded()
            let content = try #require(navigation.interactiveContentPopGestureRecognizer)
            let edge = try #require(navigation.interactivePopGestureRecognizer)
            content.isEnabled = wasEnabled
            let previousDelegate = edge.delegate
            let keeper = BackSwipeKeeper()

            keeper.keep(on: navigation, over: [UIScrollView()])
            #expect(!content.isEnabled)
            #expect(edge.delegate === keeper)
            #expect(keeper.gestureRecognizerShouldBegin(edge))

            keeper.keep(on: nil, over: [])
            #expect(content.isEnabled == wasEnabled)
            #expect(edge.delegate === previousDelegate)
        }
    #endif

    private var actions: DiffActions {
        DiffActions(
            folds: FoldSet(), setViewed: { _, _ in }, openURL: OpenURLAction { _ in .handled },
            text: { _ in .constant("") }, replyText: { _ in .constant(nil) }, compose: { _ in }, closeNote: {},
            isReviewed: { _ in false }, setReviewed: { _, _ in }, explain: nil, setBarsHidden: { _ in },
            setKeyboardUp: { _ in }, removeDraft: { _ in }, reply: { _, _ in }, setResolved: { _, _ in },
            showsFileOnTop: { _ in }
        )
    }
}
