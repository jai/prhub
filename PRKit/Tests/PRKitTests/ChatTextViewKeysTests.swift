#if os(iOS)
import Testing
import UIKit
@testable import PRKit

/// The phone's and iPad's text view with a hardware keyboard: Return and Command-Return are its key commands, ahead of
/// its own Return, and send; nothing else is taken (Shift-Return is its own new line); a word being composed keeps
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
        let commands = returns(view)
        #expect(commands.map(\.modifierFlags) == [[], .command])
        #expect(commands.allSatisfy(\.wantsPriorityOverSystemBehavior))
        #expect(view.canPerformAction(#selector(PictureTextView.returnPressed(_:)), withSender: nil))
        for command in commands {
            view.returnPressed(command)
        }
        #expect(sent == 2)
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
