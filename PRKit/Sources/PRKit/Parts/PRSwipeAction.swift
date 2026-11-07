import PRKitDesign
import SwiftUI

/// One action a PR row slides to show (`PRSwipeRow`), which its long-press menu lists too.
struct PRSwipeAction {
    enum Tone {
        case accent, destructive

        var ground: Color {
            switch self {
            case .accent: Color.accentColor
            case .destructive: Color.toneBad
            }
        }
    }

    let title: String
    let icon: AppIcon
    let id: String
    let tone: Tone
    /// False where the row's menu has the action already (Review changes).
    var inMenu = true
    let action: () -> Void
}

extension EnvironmentValues {
    /// The swipe's actions, for the menu of the row under it.
    @Entry var rowSwipeActions: [PRSwipeAction] = []
}
