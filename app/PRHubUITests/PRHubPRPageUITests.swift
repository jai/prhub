import XCTest

/// A PR's page over the sample PRs: its checks, with a job's matrix legs under one line and a shared name told apart by
/// its workflow; the review bar's icons when its words don't fit; and a description in GitHub's Markdown. Pictures go to
/// `SCREENSHOTS_DIR` when it is set.
@MainActor
final class PRHubPRPageUITests: XCTestCase {
    private let app = XCUIApplication()
    private let checkout = "Show a retry button when checkout fails"
    /// The rate limit's row: its title without `[API-88] [SEC-12]`, which show as its ticket lines.
    private let rateLimit = "Rate-limit the password reset endpoint"

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.orientation = .portrait
    }

    /// The PR at a glance on its page, from key lines already on the phone, and a bug's tap is its line in the diff.
    func testThePageShowsThePRAtAGlanceAndABugOpensItsLine() throws {
        launch([])
        openCheckout()
        XCTAssertTrue(app.descendants(matching: .any)["pr-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Medium risk"].exists && app.staticTexts["1 bug found"].exists)
        XCTAssertTrue(app.staticTexts["What this does"].exists)
        try picture("summary-on-page")
        app.buttons["key-lines-summary-bug-src/checkout/CheckoutError.tsx:RIGHT:9"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["key-line-note"].waitForExistence(timeout: 5))
        try picture("summary-bug-in-diff")
    }

    func testAskShowsSentWhileTheAgentIsThinking() throws {
        launch(["-PRHubAskWorking"])
        openCheckout()
        app.buttons["pr-ask"].tap()
        let sent = app.descendants(matching: .any)["pr-ask-sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertTrue(sent.label.contains("Sent"))
        XCTAssertTrue(app.descendants(matching: .any)["pr-ask-working"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pr-ask-sending"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pr-ask-failed"].exists)
        try picture("ask-sent-thinking")
    }

    /// An agent's long answer takes most of the chat's width from its leading edge, so its words don't break mid-word
    /// (UI bug 015, seen on a Mac; `AskSheetWidthTests` pictures the sheet there).
    func testALongAnswerTakesTheChatsWidth() throws {
        launch(["-PRHubAskAnswered"])
        openCheckout()
        app.buttons["pr-ask"].tap()
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'recovery screen'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any)["sessionReplyField"].firstMatch
        // The chat's width: from the reply box's leading edge to the send button's trailing one.
        let width = app.buttons["sessionReplySend"].frame.maxX - field.frame.minX
        try picture("ask-long-answer")
        XCTAssertGreaterThan(
            answer.frame.width, width * 0.6, "the answer is \(Int(answer.frame.width)) pt of \(Int(width))"
        )
        XCTAssertLessThan(
            answer.frame.minX - field.frame.minX, width * 0.1, "the answer starts at the chat's leading edge"
        )
    }

    func testAnEmptyAskChatDoesNotClaimAMessageWasSent() {
        launch()
        openCheckout()
        app.buttons["pr-ask"].tap()
        XCTAssertTrue(app.buttons["sessionReplySend"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["pr-ask-sent"].exists)
    }

    /// One job name in two workflows says its workflow; a job's matrix legs are one line that opens to them.
    func testTheChecksGroupMatrixLegsAndNameTheirWorkflow() throws {
        launch()
        openCheckout()
        let header = app.buttons["checks-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        header.tap()
        let group = app.buttons["check-group-visual proof"]
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertTrue(group.label.hasPrefix("visual proof, 4 legs"), group.label)
        XCTAssertTrue(app.buttons["detect-changes, CI"].exists, "a shared name says its workflow")
        XCTAssertTrue(app.buttons["detect-changes, Preview"].exists)
        XCTAssertFalse(app.buttons["web 1/4"].exists, "the legs wait under their job")
        group.tap()
        XCTAssertTrue(app.buttons["web 1/4"].waitForExistence(timeout: 3), "and open under it")
        try? picture("nav-checks-grouped")
    }

    /// A description in GitHub's Markdown: its table one grid that scrolls sideways, not a line per cell, and a
    /// `<details>` fold that opens in place.
    func testADescriptionDrawsGitHubsMarkdown() throws {
        launch()
        openRateLimit()
        let table = app.scrollViews["markdown-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5), "the table is one block")
        XCTAssertTrue(table.staticTexts["Requests in an hour, per email address"].exists, "its header")
        XCTAssertTrue(table.staticTexts["6 and over"].exists, "and its rows")
        let fold = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'markdown-details-'")).firstMatch
        XCTAssertTrue(fold.waitForExistence(timeout: 3))
        if !fold.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertEqual(fold.value as? String, "closed")
        try? picture("nav-markdown")
        fold.tap()
        XCTAssertTrue(waitFor { fold.value as? String == "open" }, "the fold opens in place")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Each request adds a row'"))
            .firstMatch.waitForExistence(timeout: 3))
        try? picture("nav-markdown-open")
    }

    /// At a text size where "Request changes" no longer fits its third, all three buttons show icons, and keep their
    /// words for VoiceOver.
    func testTheReviewBarShowsIconsWhenItsWordsDontFit() throws {
        launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXL"])
        openCheckout()
        let approve = app.buttons["pr-review-approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        if !approve.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertEqual(approve.label, "Approve")
        XCTAssertEqual(app.buttons["pr-review-request-changes"].label, "Request changes")
        XCTAssertEqual(app.buttons["pr-review-comment"].label, "Comment")
        try? picture("nav-review-bar-xxl")
    }

    /// The tickets the title names, each with Linear's state, and the title without their brackets; a bot's PR names
    /// the person it was opened for, and says it is a bot's.
    func testThePageShowsItsTicketsAndWhoItIsFrom() throws {
        launch()
        openRateLimit()
        XCTAssertTrue(app.staticTexts["Rate-limit the password reset endpoint"].waitForExistence(timeout: 5),
                      "the title leaves out the tickets shown under it")
        let author = app.descendants(matching: .any)["pr-author"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        XCTAssertTrue(author.label.contains("Mona Lisa via hubot (bot) wants hubot/sample-88 in main"), author.label)
        let tickets = app.descendants(matching: .any)["pr-tickets"].firstMatch
        XCTAssertTrue(tickets.exists)
        for words in ["API-88", "Throttle password reset emails", "In Progress", "SEC-12", "Todo"] {
            XCTAssertTrue(tickets.staticTexts[words].exists, words)
        }
        try? picture("nav-tickets-author")
    }

    /// Approve closes its box at once; the toast says Submitting review…, then Approved, then goes. A refused review
    /// stays on the toast with the reason, and Retry sends it.
    func testAReviewGoesInTheBackgroundWithAToast() throws {
        launch(["-PRHubRefuseFirstReview"])
        openCheckout()
        let approve = app.buttons["pr-review-approve"]
        if !approve.isHittable {
            app.swipeUp(velocity: .slow)
        }
        approve.tap()
        let send = app.buttons["inline-composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertLessThan(send.frame.maxX, app.buttons["Cancel"].frame.minX)
        try? picture("nav-page-approve-open")
        send.tap()
        XCTAssertTrue(waitFor(timeout: 1) { !send.exists }, "the box closes at once")
        let words = app.staticTexts["pr-review-toast-words"]
        XCTAssertTrue(words.waitForExistence(timeout: 2))
        XCTAssertEqual(words.label, "Submitting review…", "while the review goes, before any answer")
        try? picture("nav-toast-submitting")
        let retry = app.buttons["pr-review-toast-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "a refusal stays, with Retry")
        XCTAssertEqual(words.label, "Review not sent. GitHub didn't answer in time.")
        try? picture("nav-toast-failed")
        retry.tap()
        XCTAssertTrue(waitFor { words.label == "Submitting review…" }, words.label)
        XCTAssertTrue(waitFor(timeout: 8) { words.label == "Approved" }, words.label)
        try? picture("nav-toast-approved")
        XCTAssertTrue(waitFor(timeout: 6) { !words.exists }, "it fades once GitHub has it")
    }

    func testALinesCommentNowClosesItsBoxAndTheToastFollowsIt() throws {
        launch()
        openCheckout()
        let diff = app.buttons["pr-files-changed"]
        XCTAssertTrue(diff.waitForExistence(timeout: 5))
        diff.tap()
        XCTAssertTrue(app.buttons["file-viewed-0"].waitForExistence(timeout: 5))
        app.closePanelOverDiff()
        let line = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'")).element(boundBy: 2)
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        line.tap()
        let field = app.descendants(matching: .any)["inline-composer-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Nit: name this better")
        let now = app.buttons["inline-composer-alternate"]
        XCTAssertTrue(now.waitForExistence(timeout: 2))
        now.tap()
        let words = app.staticTexts["pr-review-toast-words"]
        // Looked for before the box: the samples answer at once and the toast leaves 2 s later
        // (`ToastStyle.dwell`), which a loaded iPad Simulator can spend on one query.
        XCTAssertTrue(words.waitForExistence(timeout: 10), "the toast follows the comment")
        XCTAssertFalse(now.exists, "the box closed at once")
        // The samples answer at once, so it may already have landed.
        XCTAssertTrue(["Posting comment…", "Comment posted"].contains(words.label), words.label)
        try? picture("diff-toast-comment")
        XCTAssertTrue(waitFor(timeout: 8) { words.label == "Comment posted" }, words.label)
        XCTAssertTrue(waitFor(timeout: 6) { !words.exists }, "it goes once GitHub has it")
    }

    // MARK: - Helpers

    private func openRateLimit() {
        let row = app.staticTexts[rateLimit]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    private func launch(_ arguments: [String] = []) {
        app.terminate()
        app.launchArguments = ["-PRHubPaired"] + arguments
        app.launch()
    }

    private func openCheckout() {
        let row = app.staticTexts[checkout]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["pr-review-changes"].waitForExistence(timeout: 5))
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
        return condition()
    }

    private func picture(_ name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !folder.isEmpty else {
            return
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/\(name)-light.png"))
    }
}
