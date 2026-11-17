import PRKitDesign
import SwiftUI

public extension PRKeyLines {
    /// The PR at a glance, made with the key lines: its risk, the bugs found and what it does.
    struct Summary: Decodable, Sendable {
        public struct Bug: Decodable, Identifiable, Sendable {
            public let path: String
            public let line: Int
            public let side: String
            public let why: String

            public var id: String {
                "\(path):\(side):\(line)"
            }

            /// The bug as a key line, so a tap shows it in the diff as one does.
            var asItem: Item {
                Item(path: path, line: line, side: side, kind: "risk", why: why)
            }
        }

        /// Whether the PR does what its Linear ticket asks (docs/api.md, "Requirements").
        public struct Requirements: Decodable, Sendable {
            /// `fits`, `mismatch` or `multiple`. A state this build does not know is not shown.
            public let state: String
            /// The ticket checked, or the tickets named when there are several.
            public let tickets: [String]
            /// A mismatch: what the PR misses, one short bullet each.
            public let gaps: [String]

            /// The heading's words, or nil for a state this build does not know.
            var title: String? {
                switch state {
                case "fits": "Requirements fit"
                case "mismatch": "Requirements mismatch"
                case "multiple": "Multiple ticket support not yet implemented"
                default: nil
                }
            }
        }

        /// Whether the PR's title and description read as unedited AI writing (docs/api.md, "AI slop").
        public struct Slop: Decodable, Sendable {
            public let isSlop: Bool
            /// What gave it away, one short bullet each; empty when it isn't slop.
            public let tells: [String]
        }

        /// `low`, `medium` or `high`.
        public let risk: String
        public let riskWhy: String
        /// 3 to 5 short bullets: what the PR does.
        public let points: [String]
        public let bugs: [Bug]
        /// None when the PR names no Linear ticket, or the answer was made before tickets were checked.
        public let requirements: Requirements?
        /// None on an answer made before the check existed.
        public let slop: Slop?

        /// The description reads as AI slop: the page's red AI trash chip.
        public var isSlop: Bool {
            slop?.isSlop == true
        }

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

/// The PR at a glance, above its key lines: its risk and why, the bugs found (each a tap to its line), whether it meets
/// its ticket, whether its description reads as AI slop, and what it does. Up to five parts, each under a heading of an icon and words (DESIGN.md, "A PR at a
/// glance"): the icons share one column
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
                // Its own element, holding the others: without this the name goes to every child, a bug's button too.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pr-summary")
        } else {
            parts
                .padding(Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.groundFill, in: .rect(cornerRadius: PRStyle.controlRadius, style: .continuous))
                .textSelection(.enabled)
                .accessibilityElement(children: .contain)
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
            if let requirements = summary.requirements, let title = requirements.title {
                part(
                    title, icon: requirementsIcon(requirements.state), tone: requirementsTone(requirements.state),
                    id: "key-lines-summary-requirements"
                ) {
                    ForEach(Array(requirements.gaps.enumerated()), id: \.offset) { _, gap in
                        line(mark: "•") { Text(verbatim: gap) }
                    }
                }
            }
            if let slop = summary.slop, slop.isSlop {
                part("Reads as AI slop", icon: .aiSlop, tone: .toneBad, id: "key-lines-summary-slop") {
                    ForEach(Array(slop.tells.enumerated()), id: \.offset) { _, tell in
                        line(mark: "•") { Text(verbatim: tell) }
                    }
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

    private func requirementsIcon(_ state: String) -> AppIcon {
        switch state {
        case "fits": .requirementsMet
        case "mismatch": .requirementsMismatch
        default: .requirementsUnchecked
        }
    }

    private func requirementsTone(_ state: String) -> Color {
        switch state {
        case "fits": .toneGood
        case "mismatch": .toneBad
        default: .inkQuiet
        }
    }

    private var riskIcon: AppIcon {
        summary.risk == "low" ? .riskLow : .risk
    }

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
                // A size under the body's, so the widest of them (the bug, the list) fits the icons' column and every
                // heading's words start where the lines' do: at the body's size those two pushed their words right.
                Image(icon).font(.appCaption.weight(.semibold)).foregroundStyle(tone)
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
