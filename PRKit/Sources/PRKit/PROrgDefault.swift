import Foundation
import PRKitCore

/// The filter before anyone has picked one: orgs the host names, as in PRHub the pr-worker's `orgs`, else every owner in
/// the list (docs/api.md, `GET /device/config`). The Worker never filters by it.
public enum PROrgDefault: Equatable, Sendable {
    case orgs([String])
    case everyOwner

    /// A pr-worker's `orgs`, else every owner.
    public static func following(orgs: [String]?) -> PROrgDefault {
        guard let orgs, !orgs.isEmpty else {
            return .everyOwner
        }
        return .orgs(orgs)
    }

    /// `owners`: every owner in the list, for `everyOwner`, so one that appears later shows too.
    func filter(owners: [String]) -> PROrgFilter {
        switch self {
        case let .orgs(orgs): PROrgFilter(selected: Set(orgs))
        case .everyOwner: PROrgFilter(selected: Set(owners))
        }
    }
}
