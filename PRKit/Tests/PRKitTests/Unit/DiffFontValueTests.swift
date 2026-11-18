@testable import PRKit
import Testing

struct DiffFontValueTests {
    @Test func aSizeIsHeldToTheRangeInWholePoints() {
        #expect(DiffFont(face: .menlo, size: 4).size == 9)
        #expect(DiffFont(face: .menlo, size: 40).size == 20)
        #expect(DiffFont(face: .menlo, size: 13.4).size == 13)
    }
}
