#if os(macOS)
import PRKitCore
import PRKitDesign
import SwiftUI

/// The phone's swipe as the Mac does it: the same actions, in the row's menu (`PrListBlock`).
struct PRSwipeRow<Content: View>: View {
    var leading: PRSwipeAction?
    var trailing: PRSwipeAction?
    @ViewBuilder let content: Content

    var body: some View {
        content
            .environment(\.rowSwipeActions, [leading, trailing].compactMap(\.self))
    }
}
#endif
