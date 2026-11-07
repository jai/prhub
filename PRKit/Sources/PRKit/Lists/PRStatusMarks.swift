import PRKitCore
import PRKitDesign

extension PullRequestStatus {
    /// Merged or closed alone. Open: its checks, its review, then what stands in the merge's way — `Blocked` only
    /// where neither of the others shows why. A draft says so first and leaves the merge out: it cannot merge.
    public var statusMarks: [PrStatusMark] {
        Self.marks(state: state, checks: checks, review: review, merge: merge)
    }

    /// What a list says under a PR's title: `statusMarks` without the state, which has its own place. A merged or closed
    /// PR has none, and a draft keeps Conflicts.
    public var signalMarks: [PrStatusMark] {
        switch state {
        case .merged, .closed, nil: []
        case .open: statusMarks
        case .draft: [checks?.mark, review?.mark, merge == .conflicting ? merge?.mark : nil].compactMap(\.self)
        }
    }

    public static func marks(state: State?, checks: Checks?, review: Review?, merge: Merge?) -> [PrStatusMark] {
        switch state {
        case .merged: return [PrStatusMark(symbol: AppIcon.merged.symbol, text: "Merged", tone: .merged)]
        case .closed: return [PrStatusMark(symbol: AppIcon.closed.symbol, text: "Closed", tone: .quiet)]
        case nil: return []
        case .open, .draft: break
        }
        let draft = state == .draft ? PrStatusMark(symbol: AppIcon.draft.symbol, text: "Draft", tone: .quiet) : nil
        let blockedShown = review == .required || checks == .failing || checks == .pending
        let merge = state == .draft || (merge == .blocked && blockedShown) ? nil : merge?.mark
        return [draft, checks?.mark, review?.mark, merge].compactMap(\.self)
    }
}

extension PullRequestStatus.Checks {
    public var mark: PrStatusMark? {
        switch self {
        case .passing: PrStatusMark(symbol: AppIcon.checksPass.symbol, text: "Checks pass", tone: .good)
        case .failing: PrStatusMark(symbol: AppIcon.checksFail.symbol, text: "Checks fail", tone: .bad)
        case .pending: PrStatusMark(symbol: AppIcon.checksRunning.symbol, text: "Checks running", tone: .waiting)
        case .noChecks: nil
        }
    }
}

extension PullRequestStatus.Review {
    public var mark: PrStatusMark? {
        switch self {
        case .approved: PrStatusMark(symbol: AppIcon.reviewApproved.symbol, text: "Approved", tone: .good)
        case .changesRequested:
            PrStatusMark(symbol: AppIcon.reviewChangesRequested.symbol, text: "Changes requested", tone: .bad)
        case .required:
            PrStatusMark(symbol: AppIcon.reviewNeeded.symbol, text: "Needs review", tone: .quiet)
        case .noReview: nil
        }
    }
}

extension PullRequestStatus.Merge {
    /// GitHub's merge state; `unstable` (a check that is not required failing or running) is left to the checks.
    public var mark: PrStatusMark? {
        switch self {
        case .clean: PrStatusMark(symbol: AppIcon.merged.symbol, text: "Ready to merge", tone: .good)
        case .behind: PrStatusMark(symbol: AppIcon.outOfDate.symbol, text: "Out of date", tone: .waiting)
        case .blocked: PrStatusMark(symbol: AppIcon.blocked.symbol, text: "Blocked", tone: .quiet)
        case .conflicting: PrStatusMark(symbol: AppIcon.conflicts.symbol, text: "Conflicts", tone: .bad)
        case .unstable, .unknown: nil
        }
    }
}
