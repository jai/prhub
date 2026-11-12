import Foundation
import SwiftUI
import Testing
@testable import PRKit

/// The code stops at its sideways edges: a bounce would pull it off the screen's edge, with the file header cut where
/// the table ends. A finger's bounce can't be driven from a test, so this holds the setting that stops it, on the
/// phone and on the Mac; `PRHubDiffSidewaysUITests` and its recording show what the reader sees.
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

    private var actions: DiffActions {
        DiffActions(
            folds: FoldSet(), setViewed: { _, _ in }, openURL: OpenURLAction { _ in .handled },
            text: { _ in .constant("") }, replyText: { _ in .constant(nil) }, compose: { _ in }, closeNote: {},
            isReviewed: { _ in false }, setReviewed: { _, _ in }, setBarsHidden: { _ in }, setKeyboardUp: { _ in },
            removeDraft: { _ in }, reply: { _, _ in }, setResolved: { _, _ in }, showsFileOnTop: { _ in }
        )
    }
}
