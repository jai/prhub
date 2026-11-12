import Testing
@testable import PRKit

/// The message field moves the keyboard only when the screen's `focused` changes (`ChatFieldFocus`). Agent Pager's
/// chat box, a composer with no attachments, kept one letter on iOS 26.5: its screen's focus state never turned on,
/// and the field gave up the keyboard on the update the first letter caused.
struct ChatFieldFocusTests {
    @Test func aFieldBeingTypedInKeepsTheKeyboardWhileTheFocusStateStaysOff() {
        #expect(ChatFieldFocus.move(wants: false, last: false, isFirstResponder: true) == nil)
    }

    @Test func nothingMovesAtTheFirstUpdateUnlessTheScreenAsksForTheKeyboard() {
        #expect(ChatFieldFocus.move(wants: false, last: nil, isFirstResponder: false) == nil)
        #expect(ChatFieldFocus.move(wants: true, last: nil, isFirstResponder: false) == .take)
    }

    @Test func turningFocusOnTakesTheKeyboardOnce() {
        #expect(ChatFieldFocus.move(wants: true, last: false, isFirstResponder: false) == .take)
        #expect(ChatFieldFocus.move(wants: true, last: true, isFirstResponder: false) == nil)
        #expect(ChatFieldFocus.move(wants: true, last: false, isFirstResponder: true) == nil)
    }

    @Test func turningFocusOffPutsTheKeyboardAway() {
        #expect(ChatFieldFocus.move(wants: false, last: true, isFirstResponder: true) == .give)
        #expect(ChatFieldFocus.move(wants: false, last: true, isFirstResponder: false) == nil)
    }
}
