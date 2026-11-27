import DurableNetworking
import Foundation
@testable import PRKit
import Testing
#if SWIFT_PACKAGE
    import PRKitTestSupport
#endif

/// A made-up PR, acme/web#412, for the rendering tests that draw a PR's page or its diff's panel: its detail, its diff
/// and its key lines, held by a session that has no Worker and sends nothing.
@MainActor
enum PRSamplePage {
    static let ref = PullRequestRef(repo: "acme/web", number: 412)
    static let title = "Show a retry button when checkout fails"

    static let ticket = PRListTicket(
        key: "WEB-31", url: "https://linear.app/acme/issue/WEB-31", title: "Let shoppers retry a failed payment",
        state: "In Review", stateType: "started", assignee: "Alex Doe", found: true
    )

    static let secondTicket = PRListTicket(
        key: "WEB-40", url: "https://linear.app/acme/issue/WEB-40", title: "Say why a payment failed",
        state: "Todo", stateType: "unstarted", found: true
    )

    /// The PR's detail. `opened` is its `createdAt`; a Worker that does not say when leaves it out.
    static func detail(opened: Date? = nil, tickets: [PRListTicket] = [], body: String = "") throws -> PullRequestDetail {
        var object: [String: Any] = [
            "url": "https://github.com/acme/web/pull/412", "head": "sample-412", "base": "main",
            "headBranch": "mona/sample-412", "author": ["login": "mona", "avatarUrl": NSNull()], "isAuthor": false,
            "body": body, "additions": 14, "deletions": 1, "changedFiles": 2, "reviewDecision": NSNull(),
            "mergeState": "CLEAN", "labels": [[String: Any]](), "checks": [[String: Any]](),
            "comments": ["nodes": [[String: Any]]()], "reviews": ["nodes": [[String: Any]]()],
            "reviewThreads": ["nodes": [[String: Any]]()], "title": title,
        ]
        if let opened {
            object["createdAt"] = opened.ISO8601Format()
        }
        if !tickets.isEmpty {
            object["tickets"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tickets))
        }
        return try PullRequestDetail.decode(JSONSerialization.data(withJSONObject: object))
    }

    static let diff = """
    diff --git a/src/checkout/CheckoutError.tsx b/src/checkout/CheckoutError.tsx
    --- a/src/checkout/CheckoutError.tsx
    +++ b/src/checkout/CheckoutError.tsx
    @@ -7,3 +7,4 @@
       const retry = async () => {
         setRetrying(true);
    +    await retryPayment(order.id);
         setRetrying(false);
    diff --git a/src/checkout/payments.ts b/src/checkout/payments.ts
    --- a/src/checkout/payments.ts
    +++ b/src/checkout/payments.ts
    @@ -10,3 +10,4 @@
     export async function retryPayment(orderId) {
       const key = paymentKey(orderId);
    +  return post("/payments/retry", { orderId, key });
     }

    """

    /// The PR at a glance and six key lines: more than a phone's panel shows at once, so the list scrolls.
    static let keyLines: String = {
        let whys = [
            "If retryPayment throws, retrying stays true and the button stays disabled.",
            "The retry relies on the server ignoring a second payment. Is that guaranteed?",
        ]
        let items = (0 ..< 6).map { index in
            let path = index.isMultiple(of: 2) ? "src/checkout/CheckoutError.tsx" : "src/checkout/payments.ts"
            let kind = index.isMultiple(of: 2) ? "risk" : "decision"
            return #"{"path": "\#(path)", "line": \#(9 + index), "side": "RIGHT", "kind": "\#(kind)", "#
                + #""why": "\#(whys[index % 2])"}"#
        }
        return """
        {"items": [\(items.joined(separator: ","))],
         "summary": {"risk": "medium", "riskWhy": "A retry can pay twice if the server doesn't ignore repeats.",
                     "points": ["Adds a Retry button when a payment fails", "Retries through a new retryPayment call",
                                "Disables the button while a retry runs"],
                     "bugs": [{"path": "src/checkout/CheckoutError.tsx", "line": 9, "side": "RIGHT",
                               "why": "A thrown retry leaves the button disabled for good."}],
                     "requirements": {"state": "mismatch", "tickets": ["WEB-31"],
                                      "gaps": ["No limit on how many times a payment can be retried"]}},
         "context": 100, "leftOut": []}
        """
    }()

    /// A session on the PR with `detail`, its diff read and its key lines ready.
    static func session(_ detail: PullRequestDetail) async throws -> (session: PRSession, document: DiffDocument) {
        let model = PRsModel(
            client: PRViewerClient(access: .offline, transport: NoRequests()), storage: .inMemory(),
            network: PRNetwork(isOnline: false)
        )
        let document = DiffDocument(data: Data(diff.utf8))
        let lines = try JSONDecoder().decode(PRKeyLines.self, from: Data(keyLines.utf8))
        let session = PRSession(
            ref: ref, title: title, content: PRContent(detail: detail, document: document), keyLines: lines,
            tappedAt: 0, model: model
        )
        session.setContextLines(PRKeyLines.defaultContext)
        await session.loadKeyLines()
        return (session, document)
    }

    private struct NoRequests: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            Issue.record("A drawn page sent a request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
            throw URLError(.unsupportedURL)
        }
    }
}
