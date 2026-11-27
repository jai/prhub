#if DEBUG
    import Foundation
    import PRKit

    /// `-PRHubLongLines`: For review starts with a PR whose lines are too long for any screen, for the diff's wrapping.
    /// All of it is made up here. A dashboard saved as one minified line, changed (`-PRHubLongLineBytes`, 54,000 unless
    /// given; its start is shown over "Show full line"), and a README of paragraphs written as one line each. Each long
    /// line ends in a word of its own (`END-OF-…`), so a test can tell that its end is on screen. The other kinds of
    /// long line (a comment, a string, a call, a tab-indented command, a minified script, a long description) are drawn
    /// by PRKit's rendering tests, from `LongLineSample` there.
    extension PRSampleSet {
        static func prHubLongLines(bytes: Int) -> PRSampleSet {
            PRSampleSet(
                samples: [PRHubLongLineSamples.sample(bytes: bytes)] + prHub.samples, mergedReviewed: [],
                mergedMine: [], answersOnPhone: true
            )
        }
    }

    enum PRHubLongLineSamples {
        static let defaultBytes = 54000

        static func sample(bytes: Int) -> PRSampleSet.Sample {
            PRHubSample(
                repo: "acme/infra", number: 33, title: "Move the checkout dashboard to the new panels", list: "review",
                author: "mona", checks: "passing", review: "required", merge: "clean",
                body: "Moves the checkout dashboard to the new panels.",
                diff: dashboard(bytes: bytes) + readme,
                keyLines: #"{"items": [], "context": 100, "leftOut": []}"#, comment: nil
            ).sample
        }

        // MARK: - The dashboard: one minified line, changed

        /// A dashboard's JSON on one line of about `bytes`, ending in `END-OF-JSON`.
        private static func dashboardLine(bytes: Int, threshold: Int) -> String {
            var line = #"{"title":"Checkout","schemaVersion":41,"refresh":"30s","panels":["#
            var panel = 1
            let tail = #"],"tags":["checkout","payments"],"note":"END-OF-JSON"}"#
            while line.utf8.count + tail.utf8.count < bytes {
                if panel > 1 {
                    line += ","
                }
                line += #"{"id":\#(panel),"type":"timeseries","title":"Checkout requests, region \#(panel)","#
                    + #""gridPos":{"h":8,"w":12,"x":\#(panel % 2 * 12),"y":\#(panel / 2 * 8)},"#
                    + #""fieldConfig":{"defaults":{"unit":"reqps","thresholds":{"mode":"absolute","steps":"#
                    + #"[{"color":"green","value":null},{"color":"red","value":\#(threshold)}]}}},"#
                    + #""targets":[{"refId":"A","expr":"sum(rate(http_requests_total{service=\"checkout\","#
                    + #"region=\"r\#(panel)\",code=~\"5..\"}[5m]))","legendFormat":"errors in region \#(panel)"}]}"#
                panel += 1
            }
            return line + tail
        }

        private static func dashboard(bytes: Int) -> String {
            """
            diff --git a/dashboards/checkout.json b/dashboards/checkout.json
            --- a/dashboards/checkout.json
            +++ b/dashboards/checkout.json
            @@ -1 +1 @@
            -\(dashboardLine(bytes: bytes, threshold: 80))
            +\(dashboardLine(bytes: bytes, threshold: 120))

            """
        }

        // MARK: - Prose: a paragraph a line

        private static func paragraph(_ sentences: [String], about count: Int, end: String) -> String {
            var text = ""
            var next = 0
            while text.count < count {
                text += sentences[next % sentences.count] + " "
                next += 1
            }
            return text + end
        }

        private static let prose = [
            "The checkout dashboard shows how many payments start, how many finish and how long each step takes.",
            "Each region has a panel of its own, so a slow region is seen without opening the others.",
            "A panel turns red when more than one request in a hundred fails for five minutes.",
            "Whoever is on call reads the top row first: it is the only row that pages anyone.",
            "The dashboard is saved as one line of JSON, because the tool that exports it writes it that way.",
        ]

        private static let shortParagraph = paragraph(prose, about: 520, end: "END-OF-SHORT-PARAGRAPH")
        private static let longParagraph = paragraph(prose.reversed(), about: 1900, end: "END-OF-LONG-PARAGRAPH")

        private static let readme = """
        diff --git a/dashboards/README.md b/dashboards/README.md
        --- a/dashboards/README.md
        +++ b/dashboards/README.md
        @@ -1,5 +1,7 @@
         # Dashboards
        \u{20}
        -\(paragraph(prose, about: 300, end: "END-OF-OLD-PARAGRAPH"))
        +\(shortParagraph)
        +
        +\(longParagraph)
        \u{20}
         ## Editing a dashboard
        \u{20}

        """
    }
#endif
