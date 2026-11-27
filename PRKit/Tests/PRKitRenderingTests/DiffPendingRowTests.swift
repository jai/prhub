import Foundation
@testable import PRKit
import PRKitCore
import SwiftUI
import Testing
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// A pending comment in the diff's real table, the phone's and the Mac's, over the sample PR (acme/web#412): its card
/// is the row under its line, and a card that grew or shrank is brought whole into view with its foot above the room
/// the table keeps for the key line stepper and the panel button that float over it (`DiffStyle.controlsClearance`).
/// That GitHub's refusal and a closed box ask for this is `PRPendingRevealTests`'.
@MainActor
struct DiffPendingRowTests {
    /// The sample PR opened with no diff to draw.
    private struct NoDiff: Error {}

    /// The sample PR's diff in a table a phone wide and `height` tall.
    private static func table(height: CGFloat = 800) throws -> (DiffTableContainer, DiffRows, DiffDocument) {
        let session = try SamplePR.session()
        guard case let .document(document, rows) = session.content?.diff else {
            throw NoDiff()
        }
        let actions = DiffActions(
            folds: FoldSet(), setViewed: { _, _ in }, openURL: OpenURLAction { _ in .handled },
            text: { _ in .constant("") }, replyText: { _ in .constant(nil) }, compose: { _ in }, closeNote: {},
            isReviewed: { _ in false }, setReviewed: { _, _ in }, explain: nil, setBarsHidden: { _ in },
            setKeyboardUp: { _ in }, pending: .none, reply: { _, _ in }, setResolved: { _, _ in },
            showsFileOnTop: { _ in }
        )
        let container = DiffTableContainer(
            document: document, rows: rows, viewed: [], font: DiffFont(face: .menlo, size: 12), onContent: {},
            actions: actions
        )
        container.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        #if os(iOS)
            container.layoutIfNeeded()
        #else
            container.tile()
            container.layoutSubtreeIfNeeded()
        #endif
        return (container, rows, document)
    }

    @Test func theCommentOnALineIsACardInTheRowUnderItAndTheFilesHasNoRow() throws {
        let (container, rows, document) = try Self.table()
        let place = try #require(rows.place(ofPending: SamplePR.onLineID), "the comment on line 13 has a row")
        #expect(rows.files[place.file].path == SamplePR.path)
        #expect(rows.files[place.file].rows[place.row - 1].codeLine.map { document.lines[$0].newLine } == 13)
        #if os(iOS)
            let cell = container.tableView(container.table, cellForRowAt: IndexPath(row: place.row, section: place.file))
            #expect(cell is DiffHostedCell, "the card, drawn by SwiftUI")
            #expect(cell.contentConfiguration != nil)
        #else
            #expect(container.hostedID(section: place.file, row: place.row) == SamplePR.onLineID)
            #expect(container.hostedRow(section: place.file, row: place.row) != nil, "the card, drawn by SwiftUI")
        #endif
        #expect(rows.place(ofPending: SamplePR.onFileID) == nil, "the comment on the whole file is the page's")
        #expect(rows.placed == [SamplePR.onLineID])
    }

    /// Where the card is in the table, and what of the table can be seen above the floating controls.
    private static func card(in container: DiffTableContainer, at place: (file: Int, row: Int)) throws -> (card: CGRect, clear: CGRect) {
        #if os(iOS)
            let table = container.table
            let card = table.rectForRow(at: IndexPath(row: place.row, section: place.file))
            var clear = table.bounds
            clear.size.height -= table.contentInset.bottom
            return (card, clear)
        #else
            let index = try #require(container.items.firstIndex(of: .row(section: place.file, row: place.row)))
            var clear = container.contentView.bounds
            clear.size.height -= DiffStyle.controlsClearance
            return (container.table.rect(ofRow: index), clear)
        #endif
    }

    /// Scrolls the table so the card's lower half is under the floating controls, as a card is whose foot has just
    /// grown GitHub's reason and its buttons.
    private static func putTheCardsFootUnderTheControls(in container: DiffTableContainer, at place: (file: Int, row: Int)) throws {
        #if os(iOS)
            let table = container.table
            let path = IndexPath(row: place.row, section: place.file)
            // On screen first, so the card has its own height and not the table's guess.
            table.scrollToRow(at: path, at: .bottom, animated: false)
            table.layoutIfNeeded()
            let card = table.rectForRow(at: path)
            table.contentOffset.y = card.midY - table.bounds.height + table.contentInset.bottom
            table.layoutIfNeeded()
        #else
            let card = try card(in: container, at: place).card
            let top = card.midY - container.contentView.bounds.height + DiffStyle.controlsClearance
            container.contentView.scroll(to: NSPoint(x: 0, y: top))
            container.reflectScrolledClipView(container.contentView)
        #endif
    }

    /// A card whose foot is under the floating controls, on a short screen. Asked to show the card, as a refusal that
    /// grew it asks, the table scrolls just far enough: all of it, Try again and Add to the file instead included, is
    /// above the controls, and its top is still in view.
    @Test func aCardAskedForIsBroughtWholeAboveTheFloatingControls() async throws {
        let (container, rows, _) = try Self.table(height: 320)
        #if os(iOS)
            // In a window: a table scrolls with animation only on a screen.
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 320)
            window.rootViewController = controller
            window.isHidden = false
            controller.view.addSubview(container)
            container.frame = controller.view.bounds
            container.layoutIfNeeded()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                window.windowScene = nil
            }
            #expect(container.table.contentInset.bottom == DiffStyle.controlsClearance, "the room the controls float in")
        #endif
        let place = try #require(rows.place(ofPending: SamplePR.onLineID))
        try Self.putTheCardsFootUnderTheControls(in: container, at: place)
        let before = try Self.card(in: container, at: place)
        #expect(before.card.height > 0)
        #expect(before.card.maxY > before.clear.maxY + 8, "the case this is for: its foot is under the controls: \(before)")
        #expect(before.card.minY < before.clear.maxY, "and its top is in view: \(before)")

        container.update(jump: DiffJump(path: SamplePR.path, pending: SamplePR.onLineID))
        let clock = ContinuousClock()
        let start = clock.now
        var now = try Self.card(in: container, at: place)
        while !(now.card.maxY <= now.clear.maxY + 0.5 && now.card.minY >= now.clear.minY - 0.5), clock.now - start < .seconds(5) {
            try await Task.sleep(for: .milliseconds(50))
            now = try Self.card(in: container, at: place)
        }
        #expect(now.card.maxY <= now.clear.maxY + 0.5, "its foot is above the floating controls: \(now)")
        #expect(now.card.minY >= now.clear.minY - 0.5, "and its top is in view: \(now)")
    }
}
