@testable import PRKit
import Testing

struct DiffFontValueTests {
    @Test func aSizeIsHeldToTheRangeInWholePoints() {
        #expect(DiffFont(face: .menlo, size: 4).size == 9)
        #expect(DiffFont(face: .menlo, size: 40).size == 20)
        #expect(DiffFont(face: .menlo, size: 13.4).size == 13)
    }

    /// What `AppStorage(diffFontIn:)` reads as `standard`: a stored value that is no font.
    @Test(arguments: ["", "menlo", "menlo:", "comicSans:12", "menlo:big", "menlo:8", "menlo:21", "menlo:12:1"])
    func aBadStoredValueIsNoFont(stored: String) {
        #expect(DiffFont(rawValue: stored) == nil)
    }

    @Test func textSizeScalesTheCodeAndTheHeader() {
        let large = DiffMetrics.pointSizes(.standard, scale: 1.5)
        #expect(large.code == 18)
        #expect(large.header == 21)
    }
}
