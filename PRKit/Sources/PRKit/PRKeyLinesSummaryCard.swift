import PRKitDesign
import SwiftUI

extension PRKeyLines {
    /// The PR at a glance, made with the key lines: its risk, the bugs found and what it does.
    public struct Summary: Decodable, Sendable {
        public struct Bug: Decodable, Identifiable, Sendable {
            public let path: String
            public let line: Int
            public let side: String
            public let why: String

            public var id: String { "\(path):\(side):\(line)" }
            /// The bug as a key line, so a tap shows it in the diff as one does.
            var asItem: Item { Item(path: path, line: line, side: side, kind: "risk", why: why) }
        }

        /// `low`, `medium` or `high`.
        public let risk: String
        public let riskWhy: String
        /// 3 to 5 short bullets: what the PR does.
        public let points: [String]
        public let bugs: [Bug]

        var riskMark: String {
            switch risk {
            case "high": "🔴"
            case "medium": "🟡"
            default: "🟢"
            }
        }
    }
}

/// The PR at a glance, above its key lines: its risk and why, the bugs found (each a tap to its line), and what it does.
struct PRKeyLinesSummaryCard: View {
    let summary: PRKeyLines.Summary
    let session: PRSession

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(verbatim: "\(summary.riskMark) PR risk: \(summary.risk)")
                .font(.appSubheadline.weight(.semibold))
                .accessibilityIdentifier("key-lines-summary-risk")
            if !summary.riskWhy.isEmpty {
                Text(summary.riskWhy)
                    .font(.appFootnote)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: summary.bugs.isEmpty ? "✅ Bugs found: none" : "🐞 Bugs found: \(summary.bugs.count)")
                .font(.appSubheadline.weight(.semibold))
                .accessibilityIdentifier("key-lines-summary-bugs")
            ForEach(summary.bugs) { bug in
                Button { session.show(bug.asItem) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "\(bug.path):\(bug.line)")
                            .font(.appCaption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(bug.why)
                            .font(.appFootnote)
                            .foregroundStyle(Color.toneBad)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("key-lines-summary-bug-\(bug.id)")
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(summary.points.enumerated()), id: \.offset) { _, point in
                    Text(verbatim: "• \(point)")
                        .font(.appFootnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, Space.xs)
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.groundFill, in: .rect(cornerRadius: PRStyle.controlRadius, style: .continuous))
        .textSelection(.enabled)
        .accessibilityIdentifier("key-lines-summary")
    }
}
