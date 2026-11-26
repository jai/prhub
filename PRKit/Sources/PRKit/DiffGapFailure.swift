import PRKitCore
import PRKitDesign
import SwiftUI

/// A gap whose file's text could not be read: why, and Try again, said as a pending comment's refusal is. The phone's
/// table and the Mac's both host it.
struct DiffGapFailure: View {
    let gap: DiffRows.Gap
    let words: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(words)
                .font(.appFootnote)
                .foregroundStyle(Color.toneBad)
                .accessibilityIdentifier("diff-gap-failure")
            Button(DiffRows.Gap.retryTitle, action: retry)
                .buttonStyle(PRButtonStyle(.secondary))
                .accessibilityIdentifier(gap.identifier("retry"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PRStyle.inset)
        .prCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(gap.identifier())
    }
}

extension DiffRows.Gap {
    /// What keeps a failed gap's hosted row its own.
    var failureID: String {
        "gap-failed:\(id.first):\(id.path)"
    }

    /// Said by VoiceOver for the row that offers the gap.
    var spokenValue: String? {
        state == .loading ? "Loading" : nil
    }
}

/// What a test finds a line of code by: `diff-line-<its place in the diff>`, and for a line the diff left out
/// `diff-hidden-line-<file>-<its number in the new file>`, which no other diff's order changes.
enum DiffLineNames {
    static func identifier(_ line: DiffDocument.Line, index: Int, piece: Int) -> String {
        let name = line.isOutsideDiff ? "diff-hidden-line-\(line.file)-\(line.newLine)" : "diff-line-\(index)"
        return piece == 0 ? name : "\(name)-piece-\(piece)"
    }
}
