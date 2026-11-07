#if os(macOS)
import PRKitCore
import PRKitDesign
import SwiftUI

/// The phone's swipe as the Mac does it: the same action, from the row's menu.
struct PRSwipeRow<Content: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .contextMenu {
                Button(title, role: .destructive, action: action)
            }
    }
}
#endif
