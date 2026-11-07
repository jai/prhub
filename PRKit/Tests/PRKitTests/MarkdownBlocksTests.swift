import Foundation
import Testing
@testable import PRKit

/// An agent's Markdown as the thread screen draws it (`MarkdownText`), and as one-line previews read it.
struct MarkdownBlocksTests {
    private static let reply = """
    The session says #666 and #673 are two halves of the same engine fix:

    - **Engine fix (ENG-3368):** split in two.
      - [#673 (finds the pre-cut limit)](https://github.com/acme/limits/pull/673) looks it up.
      - [#666 (restores the limit)](https://github.com/acme/limits/pull/666) uses it.
    - **Recovery (CORE-334):** not in either PR.

    ## Your call

    1. Stack #666 on #673.
    2. Override the size gate with `/pr-size-override`.

    ```
    gh pr merge 666
    ```
    """

    private static func plain(_ block: MarkdownBlock) -> String {
        String(block.content.characters)
    }

    @Test func listsNestHeadingsAndCodeAreTheirOwnBlocks() {
        let blocks = MarkdownBlocks.parse(Self.reply)

        #expect(blocks.map(\.kind) == [
            .paragraph,
            .listItem(marker: "•", depth: 1), .listItem(marker: "•", depth: 2), .listItem(marker: "•", depth: 2),
            .listItem(marker: "•", depth: 1),
            .heading(level: 2),
            .listItem(marker: "1.", depth: 1), .listItem(marker: "2.", depth: 1),
            .code,
        ])
        #expect(blocks.map(\.id) == Array(0..<blocks.count))
        #expect(Self.plain(blocks[1]) == "Engine fix (ENG-3368): split in two.")
        #expect(Self.plain(blocks[5]) == "Your call")
        #expect(Self.plain(blocks[8]).trimmingCharacters(in: .newlines) == "gh pr merge 666")
    }

    @Test func boldLinksAndCodeKeepTheirInlineStyling() throws {
        let blocks = MarkdownBlocks.parse(Self.reply)
        let engine = blocks[1].content
        let bold = try #require(engine.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(String(engine[bold.range].characters) == "Engine fix (ENG-3368):")
        let link = try #require(blocks[2].content.runs.first { $0.link != nil })
        #expect(link.link?.absoluteString == "https://github.com/acme/limits/pull/673")
        #expect(String(blocks[2].content[link.range].characters) == "#673 (finds the pre-cut limit)")
        #expect(blocks[7].content.runs.contains { $0.inlinePresentationIntent == .code })
    }

    @Test func plainTextIsOneParagraphAndPreviewsDropTheSyntax() {
        #expect(MarkdownBlocks.parse("QA passed on staging.").map(\.kind) == [.paragraph])
        #expect("**OK** the [prod deploy](https://example.com) for `NM-692`".withoutMarkdown
            == "OK the prod deploy for NM-692")
        #expect("- one\n- two".withoutMarkdown == "- one\n- two")
    }
}
