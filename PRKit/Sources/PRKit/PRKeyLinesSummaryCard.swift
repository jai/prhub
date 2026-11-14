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

        /// "High risk": the heading's words. A level this build does not know is said as it came.
        var riskTitle: String {
            "\(risk.prefix(1).uppercased())\(risk.dropFirst()) risk"
        }

        /// "No bugs found", "1 bug found", "3 bugs found".
        var bugsTitle: String {
            switch bugs.count {
            case 0: "No bugs found"
            case 1: "1 bug found"
            default: "\(bugs.count) bugs found"
            }
        }
    }
}

/// The PR at a glance, above its key lines: its risk and why, the bugs found (each a tap to its line), and what it does.
/// Three parts, each under a heading of an icon and words (DESIGN.md, "A PR at a glance"): the icons share one column
/// and every word starts in the next, so a heading reads as a heading and a bullet's second line stays under its first.
/// Above the key lines it sits on the fill; on a PR's page it is one of the page's cards.
struct PRKeyLinesSummaryCard: View {
    let summary: PRKeyLines.Summary
    var onPage = false
    /// A bug was tapped: show its line in the diff.
    let showBug: (PRKeyLines.Item) -> Void

    var body: some View {
        if onPage {
            parts
                .padding(PRStyle.inset)
                .prCard()
                .textSelection(.enabled)
                .accessibilityIdentifier("pr-summary")
        } else {
            parts
                .padding(Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.groundFill, in: .rect(cornerRadius: PRStyle.controlRadius, style: .continuous))
                .textSelection(.enabled)
                .accessibilityIdentifier("key-lines-summary")
        }
    }

    private var parts: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            part(summary.riskTitle, icon: riskIcon, tone: riskTone, id: "key-lines-summary-risk") {
                if !summary.riskWhy.isEmpty {
                    line { Text(summary.riskWhy).foregroundStyle(Color.inkQuiet) }
                }
            }
            part(
                summary.bugsTitle, icon: summary.bugs.isEmpty ? .ok : .bugsFound,
                tone: summary.bugs.isEmpty ? .toneGood : .toneBad, id: "key-lines-summary-bugs"
            ) {
                ForEach(summary.bugs) { bug in
                    Button { showBug(bug.asItem) } label: {
                        line {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: "\(bug.path):\(bug.line)")
                                    .font(.appCaption.monospaced())
                                    .foregroundStyle(Color.inkQuiet)
                                Text(bug.why)
                                    .foregroundStyle(Color.toneBad)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("key-lines-summary-bug-\(bug.id)")
                }
            }
            if !summary.points.isEmpty {
                part("What this does", icon: .whatItDoes, tone: .inkQuiet, id: "key-lines-summary-points") {
                    ForEach(Array(summary.points.enumerated()), id: \.offset) { _, point in
                        line(mark: "•") { Text(verbatim: point) }
                    }
                }
            }
        }
    }

    private var riskIcon: AppIcon { summary.risk == "low" ? .riskLow : .risk }

    private var riskTone: Color {
        switch summary.risk {
        case "high": .toneBad
        case "medium": .toneWaiting
        default: .toneGood
        }
    }

    /// A heading, its icon in its tone, and what it holds under it.
    private func part(
        _ title: String, icon: AppIcon, tone: Color, id: String, @ViewBuilder holds: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label {
                Text(verbatim: title)
            } icon: {
                // At the body's size, so it fits the icons' column and the heading's words start where the lines' do.
                Image(icon).font(.appFootnote.weight(.semibold)).foregroundStyle(tone)
            }
            .labelStyle(.iconText)
            .font(.appSubheadline.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(id)
            holds()
        }
    }

    /// A line under a heading, in the words' column: `mark`, a bullet, sits in the icons' column.
    private func line(mark: String = "", @ViewBuilder words: () -> some View) -> some View {
        Label(title: words) {
            Text(verbatim: mark).foregroundStyle(Color.inkQuiet)
        }
        .labelStyle(.iconText)
        .font(.appFootnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
