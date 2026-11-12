import Testing
@testable import PRKit

/// Return in a message box with a hardware keyboard (`ReturnKey`): it sends, and so does Command-Return; Shift-Return
/// and Option-Return start a new line. On an iPad with a keyboard, Return only ever started a new line.
struct ReturnKeyTests {
    @Test func returnAndCommandReturnSend() {
        #expect(ReturnKey.action([]) == .send)
        #expect(ReturnKey.action(.command) == .send)
        #expect(ReturnKey.action(.control) == .send)
    }

    @Test func shiftReturnAndOptionReturnStartALine() {
        #expect(ReturnKey.action(.shift) == .newLine)
        #expect(ReturnKey.action(.option) == .newLine)
        #expect(ReturnKey.action([.shift, .command]) == .newLine)
    }
}
