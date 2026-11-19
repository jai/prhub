import Foundation
@testable import PRKit
import SwiftUI
import Testing
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

@MainActor
struct DiffLineNumberTests {
    @Test(arguments: [CGFloat(9), 12, 20])
    func rowsShowBothFileVersionsWithoutCoveringCode(size: CGFloat) throws {
        let document = DiffDocument(data: Data("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -99999,2 +999999,2 @@
         context
        -old
        +new
        \\ No newline at end of file
        @@ -0,0 +1 @@
        +first

        """.utf8))
        let container = DiffTableContainer(
            document: document, rows: DiffRows(document: document, threads: []), viewed: [],
            font: DiffFont(face: .menlo, size: size), onContent: {}, actions: actions
        )
        let expected = [("", ""), ("99999", "999999"), ("100000", ""), ("", "1000000"), ("", ""), ("", ""), ("", "1")]
        var codePositions: [CGFloat] = []
        for (row, numbers) in expected.enumerated() {
            let index = row + 3
            #if os(iOS)
                let cell = try #require(container.lineCell(index, at: IndexPath(row: row, section: 0)) as? DiffLineCell)
                cell.frame = CGRect(x: 0, y: 0, width: 500, height: 60)
                cell.layoutIfNeeded()
                #expect(cell.oldNumber.text == numbers.0)
                #expect(cell.newNumber.text == numbers.1)
                #expect(cell.label.text == document.text(of: document.lines[index]))
                #expect(cell.oldNumber.sizeThatFits(.zero).width <= cell.oldNumber.frame.width)
                #expect(cell.newNumber.sizeThatFits(.zero).width <= cell.newNumber.frame.width)
            #else
                let cell = try #require(container.lineView(index) as? DiffLineView)
                cell.frame = NSRect(x: 0, y: 0, width: 500, height: 60)
                cell.layoutSubtreeIfNeeded()
                #expect(cell.oldNumber.stringValue == numbers.0)
                #expect(cell.newNumber.stringValue == numbers.1)
                #expect(cell.label.stringValue == document.text(of: document.lines[index]))
                #expect(cell.oldNumber.fittingSize.width <= cell.oldNumber.frame.width)
                #expect(cell.newNumber.fittingSize.width <= cell.newNumber.frame.width)
            #endif
            #expect(cell.oldNumber.frame.maxX < cell.newNumber.frame.minX)
            #expect(cell.newNumber.frame.maxX < cell.label.frame.minX)
            #expect(cell.oldNumber.font == cell.label.font)
            #expect(cell.newNumber.font == cell.label.font)
            codePositions.append(cell.label.frame.minX)
        }
        #expect(Set(codePositions).count == 1)
    }

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
