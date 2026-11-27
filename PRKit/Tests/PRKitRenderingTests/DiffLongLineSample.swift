import Foundation

/// The long lines of the app's sample PR for wrapping (`-PRHubLongLines`, acme/infra#33 in `PRHubLongLineSamples`),
/// which the package's tests can't import: a dashboard saved as one minified line, changed; a README of paragraphs
/// written as one line each; code with a long comment, a long string and a long call; a tab-indented command; and a
/// minified script. All of it is made up. Each long line ends in a word of its own (`END-OF-…`).
enum LongLineSample {
    /// A dashboard's JSON on one line of about `bytes`, ending in `END-OF-JSON`.
    static func dashboardLine(bytes: Int, threshold: Int) -> String {
        var line = #"{"title":"Checkout","schemaVersion":41,"refresh":"30s","panels":["#
        var panel = 1
        let tail = #"],"tags":["checkout","payments"],"note":"END-OF-JSON"}"#
        while line.utf8.count + tail.utf8.count < bytes {
            if panel > 1 {
                line += ","
            }
            line += #"{"id":\#(panel),"type":"timeseries","title":"Checkout requests, region \#(panel)","#
                + #""fieldConfig":{"defaults":{"unit":"reqps","thresholds":{"mode":"absolute","steps":"#
                + #"[{"color":"green","value":null},{"color":"red","value":\#(threshold)}]}}},"#
                + #""targets":[{"refId":"A","expr":"sum(rate(http_requests_total{service=\"checkout\","#
                + #"region=\"r\#(panel)\",code=~\"5..\"}[5m]))","legendFormat":"errors in region \#(panel)"}]}"#
            panel += 1
        }
        return line + tail
    }

    static let dashboard = """
    diff --git a/dashboards/checkout.json b/dashboards/checkout.json
    --- a/dashboards/checkout.json
    +++ b/dashboards/checkout.json
    @@ -1 +1 @@
    -\(dashboardLine(bytes: 5000, threshold: 80))
    +\(dashboardLine(bytes: 5000, threshold: 120))

    """

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

    static let readme = """
    diff --git a/dashboards/README.md b/dashboards/README.md
    --- a/dashboards/README.md
    +++ b/dashboards/README.md
    @@ -1,5 +1,7 @@
     # Dashboards
    \u{20}
    -\(paragraph(prose, about: 300, end: "END-OF-OLD-PARAGRAPH"))
    +\(paragraph(prose, about: 520, end: "END-OF-SHORT-PARAGRAPH"))
    +
    +\(paragraph(prose.reversed(), about: 1900, end: "END-OF-LONG-PARAGRAPH"))
    \u{20}
     ## Editing a dashboard
    \u{20}

    """

    private static let comment = "        /// Retries a failed payment at most three times, waiting twice as long before each try, "
        + "and gives up at once when the card was declined, because a declined card stays declined however often "
        + "it is asked again and each ask can cost the customer a hold on their account. END-OF-COMMENT"

    private static let message = "        static let declinedMessage = \"Your card was declined. Nothing was taken "
        + "from your account, and trying again will not help: please use another card or ask your bank why it said "
        + "no. END-OF-STRING\""

    private static let call = "            guard number < RetryPolicy.maximumAttempts, failure.kind != .declined, "
        + "failure.kind != .cancelled, !failure.isPermanent, "
        + "clock.now < deadline.addingTimeInterval(-RetryPolicy.minimumRoomBeforeDeadline) else { return nil } "
        + "// END-OF-CALL"

    static let code = """
    diff --git a/Sources/Checkout/RetryPolicy.swift b/Sources/Checkout/RetryPolicy.swift
    --- a/Sources/Checkout/RetryPolicy.swift
    +++ b/Sources/Checkout/RetryPolicy.swift
    @@ -10,6 +10,9 @@ struct RetryPolicy {
         struct Attempt {
             let number: Int
    +\(comment)
    +\(message)
             func next(after failure: PaymentFailure) -> Attempt? {
    -            guard number < 3 else { return nil }
    +\(call)
                 return Attempt(number: number + 1)
             }
         }

    """

    private static let download = "\t\tcurl --fail --silent --show-error --retry 3 --header \"Accept: application/json\" "
        + "\"https://dashboards.example.com/api/dashboards/uid/checkout\" --output build/checkout.json # END-OF-TABS"

    static let makefile = """
    diff --git a/Makefile b/Makefile
    --- a/Makefile
    +++ b/Makefile
    @@ -4,3 +4,4 @@ export:
     export:
     \tmkdir -p build
    +\(download)
     \tjq -c . build/checkout.json > dashboards/checkout.json

    """

    /// 12,000 characters with hardly a space.
    private static let minified: String = {
        var text = "!function(){"
        var index = 0
        while text.count < 12000 {
            text += "function r\(index)(t,e){return t.retries<e.max&&!t.declined?r\(index + 1)(t,e):null}"
            index += 1
        }
        return text + "}();END_OF_SCRIPT()"
    }()

    static let script = """
    diff --git a/vendor/retry.min.js b/vendor/retry.min.js
    --- /dev/null
    +++ b/vendor/retry.min.js
    @@ -0,0 +1 @@
    +\(minified)

    """

    /// The PR's diff: every file above.
    static let diff = dashboard + readme + code + makefile + script

    /// Each file's diff by a short name, with the word its last long line ends in: for a picture of each.
    static let files: [String: (diff: String, tail: String)] = [
        "json": (dashboard, "END-OF-JSON"), "readme": (readme, "END-OF-LONG-PARAGRAPH"), "code": (code, "END-OF-CALL"),
        "tabs": (makefile, "END-OF-TABS"), "minified": (script, "END_OF_SCRIPT()"),
    ]

    /// The start of the PR's description: a long paragraph, and a link with no break in it.
    static let description = [
        paragraph(prose, about: 900, end: "END-OF-DESCRIPTION-PARAGRAPH"),
        "The export: https://dashboards.example.com/api/dashboards/uid/checkout?orgId=1&from=now-6h&to=now"
            + "&var-region=all&var-service=checkout&var-status=5xx&refresh=30s&kiosk=tv&theme=light&END-OF-LINK",
    ].joined(separator: "\n\n")

    /// The rest of it: a wide table and wide code, which scroll sideways in their own room (DESIGN.md, Markdown).
    static let wideBlocks = """
    | Panel | Before | After | Why it changed in this pull request |
    | --- | --- | --- | --- |
    | Errors | 80 | 120 | The old threshold paged on every deploy, END-OF-TABLE |

    ```
    jq -c . build/checkout.json > dashboards/checkout.json && git diff --stat dashboards/ # END-OF-CODE-BLOCK
    ```
    """
}
