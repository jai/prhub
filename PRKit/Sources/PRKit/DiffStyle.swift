import PRKitCore
import PRKitDesign
import SwiftUI

/// The diff's measures and colours, the same on the phone's table and the Mac's (`Phone/`, `Mac/`).
enum DiffStyle {
    /// Fonts never change once made; AppKit just doesn't say so.
    nonisolated(unsafe) static let font = DesignTokens.codeFontFamily
        .flatMap { PlatformFont(name: $0, size: DesignTokens.codeFontSize) }
        ?? PlatformFont.monospacedSystemFont(ofSize: DesignTokens.codeFontSize, weight: .regular)
    static let rowHeight: CGFloat = 17
    static let fileHeaderHeight: CGFloat = 28
    static let threadInset: CGFloat = 8
    static let selectedLine = PlatformColor.systemYellow.withAlphaComponent(0.32)

    static func background(_ kind: DiffDocument.Kind) -> PlatformColor {
        switch kind {
        case .added: .systemGreen.withAlphaComponent(0.18)
        case .removed: .systemRed.withAlphaComponent(0.18)
        case .hunk: .systemBlue.withAlphaComponent(0.14)
        case .file, .meta, .context: .clear
        }
    }
}

/// What the table can ask for. It holds these, not the session, so it only ever sees a diff and rows.
struct DiffActions {
    /// Which files and threads Jai has folded: it lives in the session, so it outlasts a switch of page.
    let folds: FoldSet
    let setViewed: (Bool, String) -> Void
    /// Hosted cells don't inherit SwiftUI's environment, and a PR link in a thread must stay in the app.
    let openURL: OpenURLAction
    let text: (DiffDocument.Line) -> Binding<String>
    let replyText: (PullRequestDetail.Thread) -> Binding<String?>
    /// A line was picked to comment on, or nil to stop. The box itself is the screen's, above the keyboard.
    let compose: (Int?) -> Void
    let closeNote: () -> Void
    /// The reader scrolled down the code (true) or back up. The phone's bars go and come with it.
    let setBarsHidden: (Bool) -> Void
    let setKeyboardUp: (Bool) -> Void
    let removeDraft: (PRDraftComment) -> Void
    let reply: (PullRequestDetail.Thread, String) async throws -> Void
    let setResolved: (PullRequestDetail.Thread, Bool) async throws -> Void
}
