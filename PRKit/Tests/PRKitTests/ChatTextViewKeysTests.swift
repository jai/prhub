#if os(iOS)
import Testing
import UIKit
@testable import PRKit

/// The phone's and iPad's text view with a hardware keyboard: Return and Command-Return are its key commands, ahead of
/// its own Return, and send; Shift-Return and Option-Return start a new line at the cursor; a word being composed keeps
/// Return for itself. Run in PRHub's scheme on a Simulator: `swift test` on the Mac has no UIKit.
@MainActor
struct ChatTextViewKeysTests {
    private func returns(_ view: PictureTextView) -> [UIKeyCommand] {
        (view.keyCommands ?? []).filter { $0.input == "\r" }
    }

    @Test func returnAndCommandReturnSendAheadOfTheTextViewsOwnReturn() {
        let view = PictureTextView()
        var sent = 0
        view.send = { sent += 1 }
        let commands = returns(view).filter { $0.action == #selector(PictureTextView.returnPressed(_:)) }
        #expect(commands.map { $0.modifierFlags } == [[], .command])
        #expect(commands.allSatisfy { $0.wantsPriorityOverSystemBehavior })
        #expect(view.canPerformAction(#selector(PictureTextView.returnPressed(_:)), withSender: nil))
        for command in commands {
            view.returnPressed(command)
        }
        #expect(sent == 2)
    }

    @Test func shiftReturnAndOptionReturnStartALineAtTheCursorInPlaceOfTheSelection() {
        let view = PictureTextView()
        var sent = 0
        view.send = { sent += 1 }
        let lines = returns(view).filter { $0.action == #selector(PictureTextView.newLinePressed(_:)) }
        #expect(lines.map { $0.modifierFlags } == [.shift, .alternate])
        #expect(lines.allSatisfy { $0.wantsPriorityOverSystemBehavior })
        #expect(view.canPerformAction(#selector(PictureTextView.newLinePressed(_:)), withSender: nil))

        view.text = "Merge it."
        view.selectedRange = NSRange(location: 9, length: 0)
        view.newLinePressed(lines[0])
        #expect(view.text == "Merge it.\n")
        view.text = "Merge it now."
        // "now" selected: the line takes its place.
        view.selectedRange = NSRange(location: 9, length: 3)
        view.newLinePressed(lines[1])
        #expect(view.text == "Merge it \n.")
        #expect(sent == 0, "a new line sends nothing")
    }

    @Test func aWordBeingComposedKeepsReturn() {
        let view = PictureTextView()
        var sent = 0
        view.send = { sent += 1 }
        let command = returns(view)[0]
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        #expect(view.markedTextRange != nil)
        #expect(returns(view).isEmpty)
        view.returnPressed(command)
        #expect(sent == 0)
    }
}
#endif
