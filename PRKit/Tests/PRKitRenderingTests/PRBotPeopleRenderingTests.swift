import Foundation
@testable import PRKit
import PRKitCore
import SwiftUI
import Testing

/// Who a bot's PR leads with, drawn off screen from the Worker's own payloads (Jai, 2026-11-25: a PR an agent's account
/// opened for a ticket that is someone's showed the account alone). Three shapes: the ticket has an owner and Linear
/// delegated it to an agent; an owner and no delegate; no owner. No picture is fetched, so a face is its initials.
@MainActor
struct PRBotPeopleRenderingTests {
    private static let width: CGFloat = 390
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let mona = #"{"login": null, "name": "Mona Lisa", "avatarUrl": null, "source": "linear"}"#
    private static let atlas = #"{"name": "Atlas", "avatarUrl": null}"#

    /// A row of `GET /prs` opened by `author`, with what the Worker adds on a bot's PR.
    private static func row(author: String, requestedBy: String? = nil, agent: String? = nil) throws -> some View {
        let people = [requestedBy.map { #""requestedBy": \#($0),"# }, agent.map { #""agent": \#($0),"# }]
            .compactMap(\.self).joined()
        let json = """
        {"repo": "acme/api", "number": 88, "title": "Rate-limit the password reset endpoint", "head": "h",
         "revision": "r", "diff": "ready", "detail": "d",
         "status": {"list": "mine", "author": "\(author)", \(people) "checks": "passing", "review": "required",
                    "merge": "blocked", "jaiReview": null, "jaiReviewedAt": null}}
        """
        var pullRequest = try JSONDecoder().decode(PullRequestRow.self, from: Data(json.utf8)).listPullRequest
        // Nothing to open, so the row is its words and no button: a Mac's button cannot be drawn off screen.
        pullRequest.status.url = "sample"
        return PrListBlock(
            item: PRListItem(pullRequests: [pullRequest]), id: "88", sentAt: now, now: now, folds: FoldSet()
        )
    }

    /// A PR's page byline, opened by hubot, with the ticket Linear answered with.
    private static func byline(
        bot: Bool, requestedBy: String?, delegate: String?, delegateAvatar: String? = nil
    ) throws -> some View {
        let ticket = """
        {"key": "API-88", "title": "Throttle password reset emails", "state": "In Review", "found": true,
         "assignee": \(requestedBy == nil ? "null" : #""Mona Lisa""#), "delegate": \(delegate.map { #""\#($0)""# } ?? "null"),
         "delegate_avatar": \(delegateAvatar.map { #""\#($0)""# } ?? "null")}
        """
        let json = """
        {"url": "u", "head": "h", "base": "main", "headBranch": "atlas/api-88-rate-limit",
         "author": {"login": "hubot", "avatarUrl": null}, "isAuthor": false, "authorIsBot": \(bot),
         "requestedBy": \(requestedBy ?? "null"), "tickets": [\(ticket)], "body": "", "additions": 0, "deletions": 0,
         "changedFiles": 0, "reviewDecision": null, "mergeState": "CLEAN", "labels": [], "checks": [],
         "comments": {"nodes": []}, "reviews": {"nodes": []}, "reviewThreads": {"nodes": []}, "title": "t"}
        """
        return try PRByline(detail: PullRequestDetail.decode(Data(json.utf8)))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The agent's picture in Linear, in hand so it is drawn without the network: one flat colour no other part has.
    private static let atlasPicture = "https://linear.example/atlas.png"
    private static let atlasWithPicture = #"{"name": "Atlas", "avatarUrl": "\#(atlasPicture)"}"#
    private static let fox: (red: UInt8, green: UInt8, blue: UInt8) = (255, 0, 255)

    private static func foxPicture() throws -> Image {
        var bytes = [UInt8](repeating: 255, count: 16 * 16 * 4)
        for pixel in 0 ..< 16 * 16 {
            bytes[pixel * 4 + 1] = 0
        }
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &bytes, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try Image(decorative: #require(context.makeImage()), scale: 1)
    }

    /// How many of `bytes`' pixels are the fox's colour.
    private func foxPixels(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).count { offset in
            bytes[offset] > 240 && bytes[offset + 1] < 15 && bytes[offset + 2] > 240
        }
    }

    /// The same picture, but for a level of rounding where two drawings were composed apart.
    private func isSame(_ one: [UInt8], _ other: [UInt8]) -> Bool {
        one.count == other.count && zip(one, other).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
    }

    private func render(_ view: some View) throws -> CGImage {
        let renderer = try ImageRenderer(
            content: view
                .frame(width: Self.width)
                .background(Color.white)
                .environment(\.colorScheme, .light)
                .environment(\.loadsAuthorAvatars, false)
                .environment(\.avatarPictures, [Self.atlasPicture: Self.foxPicture()])
        )
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    /// The bytes of `image` within `part`, a fraction of its width from the leading edge: its face, or what follows.
    private func bytes(_ image: CGImage, columns part: Range<CGFloat>) throws -> [UInt8] {
        let crop = CGRect(
            x: CGFloat(image.width) * part.lowerBound, y: 0,
            width: CGFloat(image.width) * (part.upperBound - part.lowerBound), height: CGFloat(image.height)
        ).integral
        let cut = try #require(image.cropping(to: crop))
        var bytes = [UInt8](repeating: 0, count: cut.width * cut.height * 4)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &bytes, width: cut.width, height: cut.height, bitsPerComponent: 8, bytesPerRow: cut.width * 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cut, in: CGRect(x: 0, y: 0, width: cut.width, height: cut.height))
        return bytes
    }

    // The row's avatar column, and the rest of the row beside it.
    // The Mac's avatar is smaller, so its text starts sooner.
    #if os(macOS)
        private static let split: CGFloat = 0.12
    #else
        private static let split: CGFloat = 0.145
    #endif
    private static let face: Range<CGFloat> = 0 ..< split
    private static let words: Range<CGFloat> = split ..< 1

    @Test func aBotsRowWithAnOwnerAndNoDelegateLeadsWithTheOwnerThenTheAccount() throws {
        let owned = try render(Self.row(author: "hubot", requestedBy: Self.mona))
        let bare = try render(Self.row(author: "hubot"))
        // A row a person named Mona Lisa opened draws her initials: the face the owner's row must show.
        let hers = try render(PrListBlock(
            item: PRListItem(pullRequests: [PRListPullRequest(
                status: PullRequestStatus(
                    repo: "acme/api", number: 88, url: "sample",
                    title: "Rate-limit the password reset endpoint", state: .open, checks: .passing, merge: .blocked,
                    review: .required
                ),
                author: "mona", authorName: "Mona Lisa", jaiReviewRequested: false, found: true, isAnswered: false
            )]),
            id: "88", sentAt: Self.now, now: Self.now, folds: FoldSet()
        ))
        #expect(try bytes(owned, columns: Self.face) == bytes(hers, columns: Self.face), "the owner's face")
        #expect(try bytes(owned, columns: Self.face) != bytes(bare, columns: Self.face), "not the account's")
        #expect(try bytes(owned, columns: Self.words) != bytes(bare, columns: Self.words), "and her name leads the line")
    }

    @Test func aBotsRowWithAnOwnerAndADelegateNamesTheAgentLinearHas() throws {
        let delegated = try render(Self.row(author: "hubot", requestedBy: Self.mona, agent: Self.atlas))
        let owned = try render(Self.row(author: "hubot", requestedBy: Self.mona))
        #expect(try bytes(delegated, columns: Self.face) == bytes(owned, columns: Self.face), "the owner's face on both")
        #expect(try bytes(delegated, columns: Self.words) != bytes(owned, columns: Self.words), "via the agent, not the account")
    }

    /// Jai, 2026-11-25: "Remember that Finbot has its own avatar as well". The agent is drawn as Linear's picture of it,
    /// on the row at the person's corner and on the page in its chip: never as initials or the GitHub account's picture.
    @Test func theAgentIsDrawnAsItsOwnPictureInLinearOnTheRowAndOnThePage() throws {
        let pictured = try render(Self.row(author: "hubot", requestedBy: Self.mona, agent: Self.atlasWithPicture))
        #expect(try foxPixels(bytes(pictured, columns: Self.face)) > 200, "the agent's picture, at the person's corner")
        #expect(try foxPixels(bytes(pictured, columns: Self.words)) == 0, "and nowhere else in the row")
        // Linear has no picture of the agent: its name in the line, and no mark made up for it.
        let unpictured = try render(Self.row(author: "hubot", requestedBy: Self.mona, agent: Self.atlas))
        let owned = try render(Self.row(author: "hubot", requestedBy: Self.mona))
        #expect(try isSame(bytes(unpictured, columns: Self.face), bytes(owned, columns: Self.face)))
        // An agent with no one behind the PR is not drawn.
        let alone = try render(Self.row(author: "hubot", agent: Self.atlasWithPicture))
        #expect(try foxPixels(bytes(alone, columns: 0 ..< 1)) == 0)

        let page = try render(Self.byline(
            bot: true, requestedBy: Self.mona, delegate: "Atlas", delegateAvatar: Self.atlasPicture
        ))
        #expect(try foxPixels(bytes(page, columns: 0.15 ..< 1)) > 200, "the chip's picture is the agent's own")
        #expect(try foxPixels(bytes(page, columns: 0 ..< 0.08)) == 0, "the person's face is not the agent's")
    }

    @Test func aBotsRowWithNoOwnerAndAPersonsRowAreAsTheyWere() throws {
        // An agent without someone behind it is not sent, and is not drawn if it were.
        let bare = try render(Self.row(author: "hubot"))
        let agentOnly = try render(Self.row(author: "hubot", agent: Self.atlas))
        #expect(try bytes(agentOnly, columns: 0 ..< 1) == bytes(bare, columns: 0 ..< 1))
    }

    @Test func thePagesBylineLeadsWithTheOwnerAndNamesTheAgentOnlyWhereLinearDelegated() throws {
        let delegated = try render(Self.byline(bot: true, requestedBy: Self.mona, delegate: "Atlas"))
        let owned = try render(Self.byline(bot: true, requestedBy: Self.mona, delegate: nil))
        let bare = try render(Self.byline(bot: true, requestedBy: nil, delegate: nil))
        let person = try render(Self.byline(bot: false, requestedBy: nil, delegate: nil))
        // The face and first name lead both; the chip after them differs.
        #expect(try bytes(delegated, columns: 0 ..< 0.2) == bytes(owned, columns: 0 ..< 0.2), "the owner leads both")
        #expect(try bytes(delegated, columns: 0.2 ..< 1) != bytes(owned, columns: 0.2 ..< 1), "the agent's chip")
        #expect(try bytes(owned, columns: 0 ..< 0.2) != bytes(bare, columns: 0 ..< 0.2), "no owner: the bot alone")
        #expect(try bytes(bare, columns: 0 ..< 1) != bytes(person, columns: 0 ..< 1), "a bot says it is one")
    }
}
