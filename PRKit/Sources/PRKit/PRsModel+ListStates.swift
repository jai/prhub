import Foundation

/// What the list says over itself when it has nothing to show, in the order the list decides it.
enum PRListEmptyState: Equatable {
    case loading(arriving: Int)
    /// Nothing on the phone and the read failed, or the first download has not finished.
    case failed(stillDownloading: Bool, message: String)
    /// Merged picked, and none merged on this page. Before the host's hint, which is about open PRs.
    case noMerged(PRListPage)
    /// The host's words for an empty list (`PRKitConfiguration.emptyHint`).
    case hint(PREmptyHint)
    /// PRs on the phone, none in the orgs and repos picked.
    case filteredOut
}

/// The lines the list shows about its own state.
extension PRsModel {
    /// "Not up to date" over a list whose last read failed. Offline, the host's banner already says why, so none.
    var notUpToDateLine: String? {
        guard !rows.isEmpty, network.isOnline, let errorMessage else {
            return nil
        }
        return "Not up to date. \(errorMessage)"
    }

    /// What the list says over `page`, or nil when it has rows to show. `showsMerged`: Merged is picked there;
    /// `pageIsEmpty`: no row on the page passes the filter.
    func emptyState(on page: PRListPage, showsMerged: Bool, pageIsEmpty: Bool) -> PRListEmptyState? {
        if rows.isEmpty, isSyncing {
            return .loading(arriving: arrivingCount)
        }
        if rows.isEmpty, let errorMessage {
            return .failed(stillDownloading: stillDownloading, message: errorMessage)
        }
        if showsMerged, mergedError[page] == nil, merged[page]?.isEmpty == true {
            return .noMerged(page)
        }
        if rows.isEmpty, workerSyncedAt != nil || samples != nil, let hint = configuration.emptyHint {
            return .hint(hint)
        }
        if !rows.isEmpty, pageIsEmpty, !showsMerged || mergedError[page] == nil {
            return .filteredOut
        }
        return nil
    }
}
