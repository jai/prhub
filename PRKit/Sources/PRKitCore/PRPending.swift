import Foundation

/// The person's pending review on GitHub, as the Worker reads it into a PR's detail (`pendingReview`): the comments
/// they saved and have not submitted yet, from this app or from github.com. Read leniently: a comment this app can't
/// read is left out, never the whole review.
public struct PRPendingReview: Decodable, Hashable, Sendable {
    public struct Comment: Decodable, Identifiable, Hashable, Sendable {
        public let id: String
        public let path: String
        /// Nil for a comment on the whole file, and for one whose line a newer commit took away.
        public let line: Int?
        public let side: PRDiffSide
        public let body: String
        public let isOutdated: Bool
        /// The posted thread it replies to; nil for a comment that starts a thread of its own.
        public let thread: String?
        /// On the whole file, not on a line.
        public let isFile: Bool

        public init(
            id: String, path: String, line: Int?, side: PRDiffSide = .right, body: String, isOutdated: Bool = false,
            thread: String? = nil, isFile: Bool = false
        ) {
            self.id = id
            self.path = path
            self.line = line
            self.side = side
            self.body = body
            self.isOutdated = isOutdated
            self.thread = thread
            self.isFile = isFile
        }

        private enum CodingKeys: String, CodingKey {
            case id, path, line, side, body, thread
            case isOutdated = "outdated"
            case isFile = "file"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            path = (try? container.decode(String.self, forKey: .path)) ?? ""
            line = try? container.decode(Int.self, forKey: .line)
            side = (try? container.decode(PRDiffSide.self, forKey: .side)) ?? .right
            body = (try? container.decode(String.self, forKey: .body)) ?? ""
            isOutdated = (try? container.decode(Bool.self, forKey: .isOutdated)) ?? false
            thread = try? container.decode(String.self, forKey: .thread)
            isFile = (try? container.decode(Bool.self, forKey: .isFile)) ?? false
        }
    }

    public let id: String
    /// GitHub keeps no words on a pending review this app can set: they go with its submit.
    public let body: String
    public let comments: [Comment]

    public init(id: String, body: String = "", comments: [Comment]) {
        self.id = id
        self.body = body
        self.comments = comments
    }

    private enum CodingKeys: String, CodingKey {
        case id, body, comments
    }

    /// A comment that can't be read decodes to nil instead of failing the list.
    private struct Lenient: Decodable {
        let comment: Comment?

        init(from decoder: any Decoder) throws {
            comment = try? Comment(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        comments = ((try? container.decode([Lenient].self, forKey: .comments)) ?? []).compactMap(\.comment)
    }
}

/// One comment of the review the person has not submitted yet, as every screen shows it: GitHub's pending comments
/// with this device's unsent changes on them, then the ones this device has not got to GitHub yet. Where it came from
/// and how far it has got are part of it, so no screen works them out again.
public struct PRPendingComment: Identifiable, Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        /// On GitHub's pending review, by its comment id there.
        case github(String)
        /// On this device only, so far.
        case device(PRDraftComment)
    }

    public enum Sync: Hashable, Sendable {
        /// GitHub has it as shown.
        case synced
        /// Saved on this device: it will be sent, or is on its way.
        case waiting
        /// GitHub refused it, in GitHub's words. It stays until it is tried again or deleted.
        case failed(String)
    }

    public let origin: Origin
    public let path: String
    public let line: Int?
    public let side: PRDiffSide
    public let body: String
    public let sync: Sync
    /// The posted thread it replies to.
    public let thread: String?
    public let isFile: Bool
    public let isOutdated: Bool

    public init(
        origin: Origin, path: String, line: Int?, side: PRDiffSide, body: String, sync: Sync, thread: String? = nil,
        isFile: Bool = false, isOutdated: Bool = false
    ) {
        self.origin = origin
        self.path = path
        self.line = line
        self.side = side
        self.body = body
        self.sync = sync
        self.thread = thread
        self.isFile = isFile
        self.isOutdated = isOutdated
    }

    /// A comment this device holds, waiting: on a Worker without pending reviews, until its review goes.
    public init(_ draft: PRDraftComment) {
        self.init(
            origin: .device(draft), path: draft.path, line: draft.isFile == true ? nil : draft.line, side: draft.side,
            body: draft.body,
            sync: draft.sync?.failure.map(Sync.failed) ?? .waiting, isFile: draft.isFile == true
        )
    }

    public var id: String {
        switch origin {
        case let .github(id): id
        case let .device(draft): draft.id.uuidString
        }
    }

    /// Why GitHub refused it, while it has.
    public var failure: String? {
        guard case let .failed(reason) = sync else {
            return nil
        }
        return reason
    }

    /// False only for a comment GitHub refused to take: it is on this device alone, so no review carries it.
    public var goesWithReview: Bool {
        if case .device = origin, failure != nil {
            return false
        }
        return true
    }

    /// `path:line`, or the path alone for a comment on a file or on a line a newer commit took away.
    public var location: String {
        line.map { "\(path):\($0)" } ?? path
    }
}

/// A change to a comment GitHub's pending review already holds, made on this device and kept here until GitHub has
/// it: new words, or its removal.
public struct PRPendingChange: Codable, Hashable, Sendable {
    /// GitHub's id of the comment.
    public let comment: String
    /// The new words; nil removes the comment.
    public var body: String?
    /// The outbox's id for it, once saved there: its answer or refusal finds the change by it.
    public var job: String?
    /// Handed to the write path, whose answer is still to come.
    public var isSent: Bool?
    /// GitHub's refusal, in its words.
    public var failure: String?

    public init(comment: String, body: String?, job: String? = nil, isSent: Bool? = nil, failure: String? = nil) {
        self.comment = comment
        self.body = body
        self.job = job
        self.isSent = isSent
        self.failure = failure
    }

    /// The name its send goes by while it is on its way: the outbox's id, or its own before it has one.
    public var sendKey: String {
        job ?? "change:\(comment)"
    }

    /// Not sent yet and not refused: the next sync sends it.
    public var isUnsent: Bool {
        isSent != true && failure == nil
    }
}

/// What this device keeps of one PR's pending review: only what GitHub does not have yet.
public struct PRPendingDevice: Equatable, Sendable {
    /// Comments written here and not yet on GitHub.
    public var drafts: [PRDraftComment]
    /// Edits and removals of comments GitHub holds.
    public var changes: [PRPendingChange]

    public init(drafts: [PRDraftComment] = [], changes: [PRPendingChange] = []) {
        self.drafts = drafts
        self.changes = changes
    }

    public var isEmpty: Bool {
        drafts.isEmpty && changes.isEmpty
    }

    /// The one list every screen shows: GitHub's pending comments with this device's edits and removals on them, then
    /// the device's own that GitHub does not have yet.
    public func comments(over github: [PRPendingReview.Comment]) -> [PRPendingComment] {
        let changed = Dictionary(changes.map { ($0.comment, $0) }, uniquingKeysWith: { _, last in last })
        let held: [PRPendingComment] = github.compactMap { comment in
            let change = changed[comment.id]
            // Removed here and on its way: gone at once. A refused removal brings it back, with the reason.
            if let change, change.body == nil, change.failure == nil {
                return nil
            }
            return PRPendingComment(
                origin: .github(comment.id), path: comment.path, line: comment.line, side: comment.side,
                body: change?.body ?? comment.body,
                sync: change.map { $0.failure.map(PRPendingComment.Sync.failed) ?? .waiting } ?? .synced,
                thread: comment.thread, isFile: comment.isFile, isOutdated: comment.isOutdated
            )
        }
        return held + drafts.filter { $0.sync?.isDeleted != true }.map(PRPendingComment.init)
    }

    /// This device's state against GitHub's pending review as just read. GitHub wins for what it has: a change it
    /// already shows, or to a comment it no longer holds, is done with. A comment or change whose send is no longer on
    /// its way anywhere (`isOnItsWay`, by `sendKey`) and that GitHub does not show goes back to waiting, to be sent
    /// again; one GitHub does show has landed, and leaves the device.
    public func reconciled(
        with github: [PRPendingReview.Comment], isOnItsWay: (String) -> Bool
    ) -> PRPendingDevice {
        var next = PRPendingDevice(changes: changes)
        var claimed: Set<String> = []
        for var draft in drafts {
            guard let sent = draft.sync?.sent, !isOnItsWay(draft.sendKey) else {
                next.drafts.append(draft)
                continue
            }
            let landed = github.last { comment in
                !claimed.contains(comment.id) && comment.thread == nil && comment.path == draft.path
                    && comment.isFile == (draft.isFile == true) && (comment.isFile || comment.line == draft.line)
                    && (comment.isFile || comment.side == draft.side) && comment.body == sent
            }
            if let landed {
                claimed.insert(landed.id)
                if let change = draft.changeOnceLanded(as: landed.id) {
                    next.changes.append(change)
                }
            } else if draft.sync?.isDeleted != true {
                draft.sync = nil
                next.drafts.append(draft)
            }
        }
        let known = Dictionary(github.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        next.changes = next.changes.compactMap { change in
            guard let comment = known[change.comment] else {
                return nil
            }
            guard change.isSent != true || !isOnItsWay(change.sendKey) else {
                return change
            }
            if change.failure == nil, change.body == comment.body {
                return nil
            }
            var waiting = change
            waiting.job = nil
            waiting.isSent = nil
            return waiting
        }
        return next
    }
}
