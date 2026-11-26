import PRKitCore
import PRKitDesign
import SwiftUI

/// How far the read of a repo's labels has got.
enum PRLabelsLoad: Equatable, Sendable {
    case notRead
    case reading
    case ready(PRRepoLabels)
    /// The Worker has no labels route, or no such PR: the PR's labels are read here and not changed.
    case unavailable
    case failed(String)
}

/// A PR's labels while they are being changed: the repo's labels as read, the panel that lists them, and what was put
/// on or taken off here that the PR's detail does not show yet.
struct PRLabelEditing: Equatable, Sendable {
    var load = PRLabelsLoad.notRead
    var isShowing = false
    /// Labels changed here, by name: true is on the PR. One stays until GitHub's answer shows the same.
    var wanted: [String: Bool] = [:]
    /// Labels whose change GitHub has not answered yet: a second tap waits for the first.
    var sending: Set<String> = []
    /// GitHub's words for the change it refused last.
    var problem: String?
}

extension PRsModel {
    /// The labels of the PR's repo. A sample answers from the phone; one of Jai's fixture rows, which names a real
    /// PR, answers as a Worker without the route does.
    func repoLabels(for ref: PullRequestRef) async throws -> PRRepoLabels {
        if let samples {
            guard samples.answersOnPhone else {
                throw PRWorkerError.notFound
            }
            return samples.repoLabels
        }
        return try await client.labels(for: ref)
    }
}

/// Putting labels on a PR and taking them off: shown at once, sent as any write is, and put back with GitHub's words
/// when it refuses.
extension PRSession {
    /// The way in shows until the Worker says it has no labels to change; the chips stay either way.
    var offersLabelEditing: Bool {
        labelEditing.load != .unavailable
    }

    /// Whether the person may change this PR's labels; false until the read says so.
    var canEditLabels: Bool {
        if case let .ready(repo) = labelEditing.load {
            return repo.canEdit
        }
        return false
    }

    /// On the PR as the page draws it: what was changed here, else what GitHub has.
    func hasLabel(_ name: String) -> Bool {
        labelEditing.wanted[name] ?? (content?.detail.labels.contains { $0.name == name } ?? false)
    }

    /// The PR's labels as the page draws them: GitHub's without the ones taken off here, then the ones put on here in
    /// the repo's colour for them.
    func shownLabels(in detail: PullRequestDetail) -> [PullRequestDetail.Label] {
        let wanted = labelEditing.wanted
        var shown = detail.labels.filter { wanted[$0.name] != false }
        var repo: [PRRepoLabels.Label] = []
        if case let .ready(read) = labelEditing.load {
            repo = read.labels
        }
        for name in wanted.filter(\.value).keys.sorted() where !shown.contains(where: { $0.name == name }) {
            let color = repo.first { $0.name == name }?.color ?? ""
            shown.append(PullRequestDetail.Label(name: name, color: color))
        }
        return shown
    }

    func openLabels() {
        withAnimation(AppMotion.fold) { labelEditing.isShowing = true }
        Task { await loadLabels() }
    }

    func closeLabels() {
        PRPlatform.endEditing()
        withAnimation(AppMotion.fold) { labelEditing.isShowing = false }
    }

    /// Reads the repo's labels once; `retry` reads them again after a failure. A `404` is a Worker older than the
    /// route (`unreachable`: the route is not one of a PR's that this app knows a `404` on), or a PR it can't find:
    /// either way the labels are not changed here.
    func loadLabels(retry: Bool = false) async {
        switch labelEditing.load {
        case .notRead: break
        case .failed where retry: break
        case .reading, .ready, .unavailable, .failed: return
        }
        labelEditing.load = .reading
        let next: PRLabelsLoad
        do {
            next = try await .ready(model.repoLabels(for: ref))
        } catch PRWorkerError.notFound, PRWorkerError.unreachable {
            next = .unavailable
        } catch {
            next = .failed(error.localizedDescription)
        }
        withAnimation(AppMotion.swap) { labelEditing.load = next }
    }

    /// Puts the label on the PR, or takes it off: shown at once, then sent. GitHub's answer is the PR as it now
    /// stands; a write saved to go keeps what is shown; a refusal puts the label back and says why. Nil where labels
    /// can't be changed, and while this label's last change is still going.
    @discardableResult
    func toggleLabel(_ label: PRRepoLabels.Label) -> Task<Void, Never>? {
        let name = label.name
        guard canEditLabels, !labelEditing.sending.contains(name) else {
            return nil
        }
        let isOn = !hasLabel(name)
        withAnimation(AppMotion.fold) {
            labelEditing.wanted[name] = isOn
            labelEditing.sending.insert(name)
            labelEditing.problem = nil
        }
        let write = isOn ? PRWrite.labelAdd(name: name) : .labelRemove(name: name)
        return Task {
            do {
                let outcome = try await model.write(write, to: ref)
                labelEditing.sending.remove(name)
                if let detail = outcome.posted {
                    rebuildRows(detail: detail)
                    withAnimation(AppMotion.fold) {
                        labelEditing.wanted[name] = nil
                        notice = model.writeNotice
                    }
                }
            } catch {
                withAnimation(AppMotion.fold) {
                    labelEditing.sending.remove(name)
                    labelEditing.wanted[name] = nil
                    labelEditing.problem = error.localizedDescription
                }
            }
        }
    }
}
