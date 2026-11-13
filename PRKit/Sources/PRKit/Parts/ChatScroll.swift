import PRKitDesign
import SwiftUI

/// The scroll view of every chat — a thread, a session message, Ask AI, Feedback: it opens at its end, and a
/// conversation shorter than the page sits at its foot, over the reply box, as a chat does.
public struct ChatScroll<Content: View>: View {
    @ViewBuilder public let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Laid out with the page, not after it: the foot moves with the reply box in the same frame.
        .defaultScrollAnchor(.bottom, for: .alignment)
    }
}
