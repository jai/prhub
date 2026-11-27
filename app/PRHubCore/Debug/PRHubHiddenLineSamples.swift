#if DEBUG
    import Foundation
    import PRKit

    /// `-PRHubHiddenLines`: For review starts with a PR whose diff leaves lines out, for "Show N hidden lines" and
    /// "Show whole file". All of it is made up here. `src/checkout/charge.ts` has two hunks, so lines are left out
    /// before the first (7), between the two (11) and after the second (11); `src/billing/money.ts` is renamed with
    /// nothing changed, so its diff shows none of it; `src/checkout/rates.json` has one hunk in its middle.
    extension PRSampleSet {
        static var prHubHiddenLines: PRSampleSet {
            PRSampleSet(
                samples: [PRHubHiddenLineSamples.sample] + prHub.samples, mergedReviewed: [], mergedMine: [],
                answersOnPhone: true
            )
        }
    }

    enum PRHubHiddenLineSamples {
        static let chargePath = "src/checkout/charge.ts"
        static let moneyPath = "src/billing/money.ts"
        static let ratesPath = "src/checkout/rates.json"

        static var sample: PRSampleSet.Sample {
            PRHubSample(
                repo: "acme/web", number: 431, title: "Charge a card once for each order", list: "review",
                author: "mona", checks: "passing", review: "required", merge: "clean",
                body: "A second tap on Pay no longer charges twice: each order's charge carries a key the bank "
                    + "remembers. Money helpers move to billing.",
                diff: chargeDiff + moneyDiff + ratesDiff,
                keyLines: #"{"items": [], "context": 100, "leftOut": []}"#, comment: nil,
                files: [
                    chargePath: text(charge), moneyPath: text(money), ratesPath: text(rates),
                ]
            ).sample
        }

        private static func text(_ lines: [String]) -> String {
            lines.map { $0 + "\n" }.joined()
        }

        /// Lines `range` of a file as a hunk's unchanged lines.
        private static func unchanged(_ lines: [String], _ range: ClosedRange<Int>) -> String {
            range.map { " " + lines[$0 - 1] + "\n" }.joined()
        }

        // MARK: - charge.ts: two hunks, with lines left out before, between and after

        /// `charge.ts` at the PR's head, 44 lines. Lines 11 and 12 replace one, and line 30 is new.
        static let charge: [String] = [
            #"import { api } from "../api";"#,
            #"import { track } from "../analytics";"#,
            #"import { cents } from "../billing/money";"#,
            "",
            "// Charging a card for an order. FIRST-LINE-OF-CHARGE",
            "",
            "const timeout = 15_000;",
            "",
            "// Asks the bank for the order's total.",
            "export async function charge(order) {",
            "  const key = `order-${order.id}`;",
            "  const answer = await api.post(`/orders/${order.id}/charge`, { amount: cents(order.total), key });",
            "  track(\"order_charged\", { id: order.id });",
            "  return answer;",
            "}",
            "",
            "// What the bank said, in words for the shopper. BETWEEN-THE-HUNKS",
            "export function reason(answer) {",
            "  switch (answer.code) {",
            "    case \"declined\": return \"Your bank declined the payment.\";",
            "    case \"expired\": return \"This card has expired.\";",
            "    case \"limit\": return \"This payment is over the card's limit.\";",
            "    default: return \"The payment did not go through.\";",
            "  }",
            "}",
            "",
            "// Gives the money back, in full.",
            "export async function refund(order) {",
            "  const key = `refund-${order.id}`;",
            "  track(\"order_refunded\", { id: order.id });",
            "  return api.post(`/orders/${order.id}/refund`, { key });",
            "}",
            "",
            "// How long a charge may take before the shopper is told to wait.",
            "export function patience(order) {",
            "  return order.total > 500 ? timeout * 2 : timeout;",
            "}",
            "",
            "// Whether an order can still be charged.",
            "export function chargeable(order) {",
            "  return order.state === \"open\" && order.total > 0;",
            "}",
            "",
            "// LAST-LINE-OF-CHARGE",
        ]

        private static let chargeDiff = """
        diff --git a/\(chargePath) b/\(chargePath)
        --- a/\(chargePath)
        +++ b/\(chargePath)
        @@ -8,7 +8,8 @@ const timeout = 15_000;

        """ + unchanged(charge, 8 ... 10)
            + "-  const answer = await api.post(`/orders/${order.id}/charge`, { amount: cents(order.total) });\n"
            + "+\(charge[10])\n+\(charge[11])\n"
            + unchanged(charge, 13 ... 15)
            + "@@ -26,6 +27,7 @@ export function reason(answer) {\n"
            + unchanged(charge, 27 ... 29)
            + "+\(charge[29])\n"
            + unchanged(charge, 31 ... 33)

        // MARK: - money.ts: renamed, nothing changed

        static let money: [String] = [
            "// Money as the bank counts it. FIRST-LINE-OF-MONEY",
            "export function cents(amount) {",
            "  return Math.round(amount * 100);",
            "}",
            "",
            "export function words(amount, currency = \"USD\") {",
            "  return new Intl.NumberFormat(\"en\", { style: \"currency\", currency }).format(amount);",
            "}",
        ]

        private static let moneyDiff = """
        diff --git a/src/checkout/money.ts b/\(moneyPath)
        similarity index 100%
        rename from src/checkout/money.ts
        rename to \(moneyPath)

        """

        // MARK: - rates.json: one hunk in its middle

        static let rates: [String] = [
            "{",
            "  \"updated\": \"2026-11-20\",",
            "  \"base\": \"USD\",",
            "  \"rates\": {",
            "    \"AUD\": 1.52,",
            "    \"CAD\": 1.38,",
            "    \"CHF\": 0.88,",
            "    \"EUR\": 0.93,",
            "    \"GBP\": 0.79,",
            "    \"JPY\": 151.2,",
            "    \"SGD\": 1.34,",
            "    \"THB\": 35.9",
            "  }",
            "}",
        ]

        private static let ratesDiff = """
        diff --git a/\(ratesPath) b/\(ratesPath)
        --- a/\(ratesPath)
        +++ b/\(ratesPath)
        @@ -5,7 +5,7 @@

        """ + unchanged(rates, 5 ... 7)
            + "-    \"EUR\": 0.91,\n+\(rates[7])\n"
            + unchanged(rates, 9 ... 11)
    }
#endif
