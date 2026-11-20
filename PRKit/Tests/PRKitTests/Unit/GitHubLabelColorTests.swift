@testable import PRKit
import Testing

/// A label in any colour GitHub allows reads on the card: Jai's feedback (build 306), an `ededed` automerge chip
/// vanished on the light page and left a gap between the labels beside it.
struct GitHubLabelColorTests {
    /// WCAG contrast of words on a ground of the given luminance.
    private func contrast(_ color: GitHubLabelColor, on ground: Double) -> Double {
        let (high, low) = (max(color.luminance, ground), min(color.luminance, ground))
        return (high + 0.05) / (low + 0.05)
    }

    @Test(arguments: ["ededed", "ffffff", "fbca04", "c2e0c6", "0e8a16"])
    func aLabelReadsOnALightCard(hex: String) {
        #expect(contrast(GitHubLabelColor(hex: hex).readable(dark: false), on: 1) >= 4.5)
    }

    @Test(arguments: ["000000", "1d1d1d", "5319e7", "b60205", "ededed"])
    func aLabelReadsOnADarkCard(hex: String) {
        let card = GitHubLabelColor(hex: "1c1c1e").luminance
        #expect(contrast(GitHubLabelColor(hex: hex).readable(dark: true), on: card) >= 4.5)
    }

    @Test func aLabelThatAlreadyReadsKeepsItsColour() {
        let purple = GitHubLabelColor(hex: "5319e7")
        #expect(purple.readable(dark: false) == purple)
        #expect(GitHubLabelColor(hex: "ededed").readable(dark: true) == GitHubLabelColor(hex: "ededed"))
    }

    @Test func aColourThatIsNotSixHexDigitsIsAMidGrey() {
        #expect(GitHubLabelColor(hex: "#fff") == GitHubLabelColor(hex: "808080"))
        #expect(GitHubLabelColor(hex: "zzzzzz") == GitHubLabelColor(hex: "808080"))
    }
}
