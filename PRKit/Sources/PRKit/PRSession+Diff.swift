import PRKitCore
import PRKitDesign
import SwiftUI

/// What the diff page asks of its session: stepping through key lines, what it says about itself, and viewed marks.
extension PRSession {
    var keyLineItems: [PRKeyLines.Item] {
        if offersKeyLines, case let .ready(lines) = keyLines {
            return lines.items
        }
        return []
    }

    /// The Worker's AI features, as `GET /device/config` has them in PRHub; all three in Jai's build.
    var offersKeyLines: Bool { model.configuration.isOn(.keyLines) }
    var offersAsk: Bool { model.configuration.isOn(.askAI) }
    var offersRewrite: Bool { model.configuration.isOn(.rewrite) }

    /// Previous or next key line, going round. With none selected, next is the first and previous the last.
    func stepKeyLine(by step: Int) {
        let items = keyLineItems
        guard !items.isEmpty else {
            return
        }
        let current = items.firstIndex { $0.id == selectedKeyLine?.id }
        let next = current.map { ($0 + step + items.count) % items.count } ?? (step > 0 ? 0 : items.count - 1)
        show(items[next])
    }

    /// How the diff got here, for the panel's foot and the log.
    func summary(_ document: DiffDocument) -> String {
        let scrollable = timer.milliseconds.map { "\(Int($0.rounded())) ms to scrollable" } ?? "…"
        let size = document.data.count.formatted(.byteCount(style: .file))
        return "\(scrollable) · \(document.lines.count) lines · \(size) · \(isPreloaded ? "preloaded" : "live")"
    }

    func setViewed(_ isViewed: Bool, path: String) {
        guard let id = content?.detail.id else {
            return
        }
        viewedFiles.formSymmetricDifference([path])
        notice = nil
        // Jai's `-UXFixtures` samples: nothing is marked anywhere but here.
        if model.samples?.answersOnPhone == false {
            return
        }
        Task {
            do {
                _ = try await model.write(.viewed(pullRequest: id, path: path, viewed: isViewed), to: ref)
            } catch PRViewerError.saved {
                return // It goes when the network does; the file stays marked.
            } catch {
                viewedFiles.formSymmetricDifference([path])
                notice = error.localizedDescription
            }
        }
    }
}
