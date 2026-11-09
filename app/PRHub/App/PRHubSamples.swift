import Foundation

/// "Try with sample PRs": PRHub with no pr-worker, for anyone who has not deployed one yet, App Review included. The
/// repos and people are made up (`acme/*`, `octocat`); nothing is read from or sent to GitHub. A review or a comment
/// stays on the phone, and says so.
extension PRHubEnvironment {
    static func sample(usage: UsageAnalytics = .disabled()) -> PRHubEnvironment {
        offline(
            config: DeviceConfig(features: [.keyLines], login: PRSampleSet.prHubLogin),
            samples: .prHub,
            worker: URL(string: "https://samples.prhub.invalid")!, defaultsSuite: "prhub-samples", isSample: true,
            usage: usage
        )
    }

    /// PRHub over a Worker that is not there: a connection that counts as paired, `config` as its Worker's, and no
    /// pairing. The samples' environment, and the screenshots' `-PRHubPaired`.
    static func offline(
        config: DeviceConfig, access: PRViewerAccess = .offline, samples: PRSampleSet? = nil, worker: URL,
        defaultsSuite: String, isSample: Bool, usage: UsageAnalytics = .disabled(), outbox: (any PRKitOutbox)? = nil
    ) -> PRHubEnvironment {
        let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        defaults.set(try? JSONEncoder().encode(config), forKey: WorkerConnection.configKey)
        let connection = WorkerConnection(
            endpoint: WorkerEndpoint(fixed: worker),
            pairing: DevicePairing(pair: { _, _ in throw URLError(.badURL) }, save: { _ in }),
            fetchConfig: { config }, forgetSecret: {}, defaults: defaults
        )
        return PRHubEnvironment(
            connection: connection, access: access, samples: samples, isSample: isSample, usage: usage, outbox: outbox
        )
    }
}

extension PRSampleSet {
    /// The GitHub login PRHub's samples act as.
    static let prHubLogin = "octocat"

    /// PRHub's samples: four on For review (one past its review deadline, one waiting on the user's own change
    /// request, one already approved) and two of the user's own on My PRs. Each has a description, checks, a
    /// conversation, a diff and key lines.
    static let prHub = PRSampleSet(
        samples: [
            PRHubSample(
                repo: "acme/web", number: 412, title: "Show a retry button when checkout fails", list: "review",
                author: "mona", checks: "passing", review: "required", merge: "clean",
                body: "## What this does\\n\\nWhen a payment fails, checkout now shows **Try again** instead of a dead "
                    + "end. The retry calls `retryPayment`, which the server treats as the same payment.\\n\\n"
                    + "- [x] Tested with a declined test card\\n- [ ] Tested on a slow network",
                diff: checkoutDiff, keyLines: checkoutKeyLines,
                comment: ("hubot", "Should the button say why it failed?")
            ).sample,
            PRHubSample(
                repo: "acme/api", number: 88, title: "Rate-limit the password reset endpoint", list: "review",
                author: "hubot", checks: "failing", review: "required", merge: "behind", dueHoursAgo: 26,
                body: rateLimitBody,
                diff: rateLimitDiff, keyLines: rateLimitKeyLines, comment: nil
            ).sample,
            PRHubSample(
                repo: "acme/mobile", number: 57, title: "fix: Keep the cart when the app is closed", list: "review",
                author: "ada-l", checks: "passing", review: "changes_requested", merge: "blocked",
                yourReview: "changes_requested",
                body: "The cart was cleared on exit. It is now saved to storage on every change and restored at "
                    + "launch.",
                diff: cartDiff, keyLines: cartKeyLines, comment: ("octocat", "Can we save less often than every tap?")
            ).sample,
            PRHubSample(
                repo: "acme/web", number: 405, title: "docs: Explain the local setup", list: "reviewed",
                author: "grace-h", checks: "passing", review: "approved", merge: "clean", yourReview: "approved",
                body: "Adds the two commands a new contributor needs to run the app locally.",
                diff: readmeDiff, keyLines: readmeKeyLines, comment: nil
            ).sample,
            PRHubSample(
                repo: "acme/web", number: 415, title: "feat: Dark mode for the settings page", list: "mine",
                author: PRSampleSet.prHubLogin, checks: "pending", review: "required", merge: "behind",
                body: "Follows the system appearance on the settings page. The rest of the app comes next.",
                diff: themeDiff, keyLines: themeKeyLines, comment: ("mona", "Looks good on my phone in dark mode.")
            ).sample,
            PRHubSample(
                repo: "octocat/dotfiles", number: 12, title: "Add a fish shell prompt", list: "mine",
                author: PRSampleSet.prHubLogin, checks: "passing", review: "none", merge: "clean",
                body: "A short prompt: the current folder in cyan, then `>`.",
                diff: fishDiff, keyLines: fishKeyLines, comment: nil
            ).sample,
        ],
        mergedReviewed: [], mergedMine: [], answersOnPhone: true
    )

    /// GitHub's Markdown at full stretch, as a big repo's descriptions have it: a table with aligned columns, tasks,
    /// code, a quote and a fold. Escaped for the detail's JSON.
    private static let rateLimitBody = """
        Limits password reset requests to five an hour for each email address, so the endpoint can't be used to \
        flood someone's inbox.

        | Requests in an hour, per email address | Today | This PR |
        | :--- | :---: | ---: |
        | 1 to 5 | Sent | Sent |
        | 6 and over | Sent, every time | **429**, with ~~no~~ a `Retry-After` |

        - [x] Unit tests for the window's edges
        - [ ] Tried against staging

        ```ts
        if (await limiter.count(email, { window: '1h' }) >= 5) return tooMany(res, 'Try again in an hour')
        ```

        > The limit counts by email address, not by IP, so a shared office network is never locked out.

        <details><summary>How the window is kept</summary>

        Each request adds a row with its time; rows older than an hour drop out when the next one is counted.
        </details>
        """.replacingOccurrences(of: "\n", with: "\\n")

    private static let checkoutDiff = """
    diff --git a/src/checkout/CheckoutError.tsx b/src/checkout/CheckoutError.tsx
    --- a/src/checkout/CheckoutError.tsx
    +++ b/src/checkout/CheckoutError.tsx
    @@ -1,5 +1,17 @@
     import { useState } from "react";
    +import { retryPayment } from "./payments";
     // Shown when the payment step fails.
     export function CheckoutError({ order }) {
    -  return <p>Payment failed. Please try again later.</p>;
    +  const [retrying, setRetrying] = useState(false);
    +  const retry = async () => {
    +    setRetrying(true);
    +    await retryPayment(order.id);
    +    setRetrying(false);
    +  };
    +  return (
    +    <div role="alert">
    +      <p>Payment failed.</p>
    +      <button onClick={retry} disabled={retrying}>Try again</button>
    +    </div>
    +  );
     }
    diff --git a/src/checkout/payments.ts b/src/checkout/payments.ts
    --- a/src/checkout/payments.ts
    +++ b/src/checkout/payments.ts
    @@ -10,2 +10,6 @@ export async function pay(order) {
       return api.post(`/orders/${order.id}/pay`);
     }
    +// The server ignores a second payment for the same order.
    +export async function retryPayment(orderId) {
    +  return api.post(`/orders/${orderId}/pay`, { retry: true });
    +}

    """

    private static let checkoutKeyLines = """
    {"items": [{"path": "src/checkout/CheckoutError.tsx", "line": 9, "side": "RIGHT", "kind": "risk",
                "why": "If retryPayment throws, retrying stays true and the button stays disabled."},
               {"path": "src/checkout/payments.ts", "line": 12, "side": "RIGHT", "kind": "decision",
                "why": "The retry relies on the server ignoring a second payment. Is that guaranteed?"}],
     "context": 100, "leftOut": []}
    """

    private static let rateLimitDiff = """
    diff --git a/app/routes/password_reset.py b/app/routes/password_reset.py
    --- a/app/routes/password_reset.py
    +++ b/app/routes/password_reset.py
    @@ -1,6 +1,9 @@
     from flask import Blueprint, request
    +from app.limits import limiter
     bp = Blueprint("password_reset", __name__)
     @bp.post("/password-reset")
    +@limiter.limit("5 per hour", key_func=lambda: request.form["email"])
     def reset():
    -    send_reset_email(request.form["email"])
    +    email = request.form["email"]
    +    send_reset_email(email)
         return "", 204

    """

    private static let rateLimitKeyLines = """
    {"items": [{"path": "app/routes/password_reset.py", "line": 5, "side": "RIGHT", "kind": "risk",
                "why": "The limit is per email, so one client can still try many addresses. Add a limit per IP too?"}],
     "context": 100, "leftOut": []}
    """

    private static let cartDiff = """
    diff --git a/src/cart/store.ts b/src/cart/store.ts
    --- a/src/cart/store.ts
    +++ b/src/cart/store.ts
    @@ -1,3 +1,5 @@
     export const cart = createStore({ items: [] });
    -export const clearOnExit = () => cart.reset();
    +const key = "cart";
    +cart.subscribe((state) => storage.set(key, JSON.stringify(state)));
    +export const restore = () => cart.set(JSON.parse(storage.get(key) ?? '{"items": []}'));
     export const total = () => cart.get().items.reduce((sum, item) => sum + item.price, 0);

    """

    private static let cartKeyLines = """
    {"items": [{"path": "src/cart/store.ts", "line": 3, "side": "RIGHT", "kind": "risk",
                "why": "Every change writes the whole cart to storage, on every tap."},
               {"path": "src/cart/store.ts", "line": 4, "side": "RIGHT", "kind": "decision",
                "why": "A saved cart is trusted as it is. What if a price changed since it was saved?"}],
     "context": 100, "leftOut": []}
    """

    private static let readmeDiff = """
    diff --git a/README.md b/README.md
    --- a/README.md
    +++ b/README.md
    @@ -1,2 +1,4 @@
     # acme/web
    -Run the app.
    +## Run it locally
    +1. npm install
    +2. npm run dev, then open http://localhost:3000

    """

    private static let readmeKeyLines = """
    {"items": [{"path": "README.md", "line": 4, "side": "RIGHT", "kind": "decision",
                "why": "Port 3000 is named here. Is it the port the dev server uses?"}],
     "context": 100, "leftOut": []}
    """

    private static let themeDiff = """
    diff --git a/src/settings/theme.css b/src/settings/theme.css
    --- a/src/settings/theme.css
    +++ b/src/settings/theme.css
    @@ -1,4 +1,7 @@
     .settings {
       background: white;
       color: #222;
    +}
    +@media (prefers-color-scheme: dark) {
    +  .settings { background: #111; color: #eee; }
     }

    """

    private static let themeKeyLines = """
    {"items": [{"path": "src/settings/theme.css", "line": 6, "side": "RIGHT", "kind": "decision",
                "why": "Dark mode follows the system only. Should there be a switch in the app too?"}],
     "context": 100, "leftOut": []}
    """

    private static let fishDiff = """
    diff --git a/fish/config.fish b/fish/config.fish
    --- a/fish/config.fish
    +++ b/fish/config.fish
    @@ -1,2 +1,6 @@
     set -g fish_greeting
     set -gx EDITOR nvim
    +function fish_prompt
    +    set_color cyan; echo -n (prompt_pwd)
    +    set_color normal; echo -n ' > '
    +end

    """

    private static let fishKeyLines = """
    {"items": [{"path": "fish/config.fish", "line": 4, "side": "RIGHT", "kind": "decision",
                "why": "The full path can get long. prompt_pwd shortens it already."}],
     "context": 100, "leftOut": []}
    """
}

/// One of PRHub's sample PRs, written out as the mirror would hold it. Debug builds add a long one (`-PRHubLongDiff`).
struct PRHubSample {
    let repo: String
    let number: Int
    let title: String
    /// `review`, `reviewed` or `mine`.
    let list: String
    let author: String
    let checks: String
    let review: String
    let merge: String
    var dueHoursAgo: Double?
    /// The user's own last review, on the For review list.
    var yourReview: String?
    /// Markdown, with its newlines escaped for JSON.
    let body: String
    let diff: String
    let keyLines: String
    /// Someone's comment on the PR: login and words.
    let comment: (String, String)?

    var sample: PRSampleSet.Sample {
        let row = PullRequestRow(
            repo: repo, number: number, title: title, head: "sample-\(number)", revision: "sample", diff: .ready,
            detail: "sample",
            status: PullRequestRow.Status(
                list: list, author: author, checks: checks, review: review, merge: merge, jaiReview: yourReview,
                jaiReviewedAt: yourReview.map { _ in Date.now.addingTimeInterval(-86_400).ISO8601Format() },
                reviewDueAt: dueHoursAgo.map { Date.now.addingTimeInterval(-$0 * 3_600).ISO8601Format() }
            ),
            keyLines: PRKeyLines.defaultContext
        )
        return PRSampleSet.Sample(row: row, detail: detail, diff: diff, keyLines: keyLines)
    }

    /// The diff's lines that start with `prefix`, its file headers aside.
    private func count(_ prefix: String) -> Int {
        diff.split(separator: "\n")
            .filter { $0.hasPrefix(prefix) && !$0.hasPrefix("+++") && !$0.hasPrefix("---") }
            .count
    }

    /// Checks as a big repo has them: one job name in two workflows, and a job's matrix legs beside its own check.
    private static let groupedChecks = (
        [#"{"name": "detect-changes", "state": "success", "url": null, "required": false, "workflow": "CI"}"#,
         #"{"name": "detect-changes", "state": "skipped", "url": null, "required": false, "workflow": "Preview"}"#,
         #"{"name": "visual proof", "state": "success", "url": null, "required": false, "workflow": "Visual Proof"}"#,
        ]
            + (1...4).map {
                #"{"name": "visual proof (web \#($0)/4)", "state": "success", "url": null, "required": false, "#
                    + #""workflow": "Visual Proof"}"#
            }
    ).joined(separator: ", ")

    private var detail: String {
        let isMine = list == "mine"
        let yesterday = Date.now.addingTimeInterval(-86_400).ISO8601Format()
        let failing = checks == "failing"
        let comments = comment.map {
            #"[{"id": "sample-comment-\#(number)", "author": {"login": "\#($0.0)", "avatarUrl": null}, "#
                + #""body": "\#($0.1)", "createdAt": "\#(yesterday)"}]"#
        } ?? "[]"
        let reviews = yourReview == "approved"
            ? #"[{"id": "sample-review-\#(number)", "author": {"login": "\#(PRSampleSet.prHubLogin)", "#
                + #""avatarUrl": null}, "state": "APPROVED", "body": "Clear, thanks.", "#
                + #""submittedAt": "\#(yesterday)"}]"#
            : "[]"
        return """
        {"id": null, "url": "https://github.com/\(repo)/pull/\(number)", "state": "open", "head": "sample-\(number)",
         "base": "main", "headBranch": "\(author)/sample-\(number)",
         "author": {"login": "\(author)", "avatarUrl": null},
         "isAuthor": \(isMine), "body": "\(body)",
         "additions": \(count("+")), "deletions": \(count("-")), "changedFiles": \(count("diff --git")),
         "reviewDecision": "\(review == "approved" ? "APPROVED" : "REVIEW_REQUIRED")",
         "mergeState": "\(merge.uppercased())",
         "reviewers": [{"login": "\(isMine ? "mona" : PRSampleSet.prHubLogin)", "avatarUrl": null,
                        "state": "\(review == "approved" ? "APPROVED" : "REQUESTED")"}],
         "viewedFiles": [], "labels": [{"name": "sample", "color": "8250DF"}],
         "checks": [{"name": "test", "state": "\(failing ? "failure" : checks == "pending" ? "pending" : "success")",
                     "url": null, "required": true, "workflow": "CI"},
                    {"name": "lint", "state": "success", "url": null, "required": false, "workflow": "CI"},
                    \(Self.groupedChecks)],
         "comments": {"nodes": \(comments)}, "reviews": {"nodes": \(reviews)}, "reviewThreads": {"nodes": []},
         "title": \(String(reflecting: title))}
        """
    }
}
