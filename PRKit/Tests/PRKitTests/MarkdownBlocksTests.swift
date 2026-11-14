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

    /// The 2026-11-10 bug bash: the box trimmed a comment's first indent, so GitHub's indented code block drew as one
    /// run-on paragraph.
    @Test func aCommentIndentedFourSpacesIsPostedAsTypedAndDrawsAsCode() {
        let posted = "\n  \n    indented review\n    second line  \n\n".asPosted
        #expect(posted == "    indented review\n    second line")
        let blocks = MarkdownBlocks.parse(posted)
        #expect(blocks.map(\.kind) == [.code])
        #expect(String(blocks[0].content.characters) == "indented review\nsecond line")
        #expect("  plain words \n".asPosted == "  plain words" && " \n ".asPosted.isEmpty)
    }
}

/// GitHub's flavour, as a PR's description has it: tables, task lists, images, strikethrough and `<details>`.
struct MarkdownGitHubTests {
    /// Every element a description can hold, with made-up content.
    static let everything = """
    ## What changed

    | User, on the test plans | Cycles | Today | This PR |
    | :--- | :---: | ---: | --- |
    | Step 8, **฿4,000** | Healthy, then manual | ฿6,500 | ~~฿7,500~~ ฿6,500 |
    | Step 1 | Healthy | `฿1,500` | [฿1,500](https://example.com/a) |

    - [x] Unit tests
    - [ ] Tried on a phone
      - nested under it

    > Quoted, as GitHub quotes.

    ```ts
    const limit = cap(total, plan.dtiCap) // a long line that runs past the edge of a phone's screen and scrolls
    ```

    ![The new screen](https://example.com/screen.png)

    <details>
    <summary>Workflow trace</summary>

    - [ ] Inside the fold
    <details><summary>Deeper</summary>

    Nested text.
    </details>
    </details>

    Last line.
    """

    @Test func aTableIsOneBlockWithItsAlignmentHeaderAndRows() throws {
        let blocks = MarkdownBlocks.parse(PRMarkdown.clean(Self.everything))
        let tables = blocks.compactMap { block -> MarkdownTable? in
            if case let .table(table) = block.kind { return table }
            return nil
        }
        let table = try #require(tables.first)
        #expect(tables.count == 1, "one block, not a line per cell")
        #expect(table.alignments == [.leading, .center, .trailing, .leading])
        #expect(table.header.map { String($0.characters) } == ["User, on the test plans", "Cycles", "Today", "This PR"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0].map { String($0.characters) } == [
            "Step 8, ฿4,000", "Healthy, then manual", "฿6,500", "฿7,500 ฿6,500",
        ])
        #expect(table.rows[0][0].runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(table.rows[0][3].runs.contains { $0.inlinePresentationIntent == .strikethrough })
        #expect(table.rows[1][3].runs.contains { $0.link?.absoluteString == "https://example.com/a" })
    }

    @Test func imagesCodeAndDetailsAreTheirOwnBlocks() throws {
        let blocks = MarkdownBlocks.parse(PRMarkdown.clean(Self.everything))
        #expect(blocks.contains { $0.kind == .image(URL(string: "https://example.com/screen.png")!) })
        #expect(blocks.contains { $0.kind == .code })
        #expect(blocks.contains { $0.kind == .quote })
        let details = try #require(blocks.first { if case .details = $0.kind { true } else { false } })
        #expect(String(details.content.characters) == "Workflow trace")
        guard case let .details(inner) = details.kind else {
            return
        }
        #expect(inner.first?.kind == .listItem(marker: "•", depth: 1))
        let deeper = try #require(inner.first { if case .details = $0.kind { true } else { false } })
        #expect(String(deeper.content.characters) == "Deeper")
        #expect(blocks.last.map { String($0.content.characters) } == "Last line.")
        let ids = blocks.flatMap(\.flattened).map(\.id)
        #expect(Set(ids).count == ids.count, "every block, folded or not, has its own id")
    }

    @Test func tasksInsideAFoldCountInOrder() {
        let tasks = MarkdownBlocks.parse(PRMarkdown.clean(Self.everything)).flatMap(\.flattened)
            .filter { $0.content.characters.first == "☐" || $0.content.characters.first == "☑︎" }
        #expect(tasks.map { String($0.content.characters.dropFirst(2)) } == [
            "Unit tests", "Tried on a phone", "Inside the fold",
        ])
        #expect(PRMarkdown.taskText(in: Self.everything, at: 2) == "Inside the fold", "as the Worker counts them")
    }

    @Test func anHTMLImageBecomesAMarkdownImageAndDetailsStay() {
        let cleaned = PRMarkdown.clean(#"<img width="300" alt="Screen" src="https://example.com/s.png"> <b>bold</b>"#)
        #expect(cleaned.contains("![Screen](https://example.com/s.png)"))
        #expect(!cleaned.contains("<b>"))
        #expect(PRMarkdown.clean("<details><summary>S</summary>x</details>").contains("<details>"))
    }
}
