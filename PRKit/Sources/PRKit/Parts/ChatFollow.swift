import PRKitDesign
import SwiftUI

public extension View {
    /// Keeps the reader at the end of a `ChatScroll` while they read it, and leaves them where they are once they scroll
    /// up: a long answer landing grows the page under them and they stay with its foot. Put on the `ChatScroll`, inside
    /// a `ScrollViewReader`, with a view at the foot of the chat that has `endID`.
    ///
    /// - Parameters:
    ///   - readsEnd: Whether they were at the end when they last scrolled; the host may read it (to draw less, say).
    ///   - isLoadingEarlier: While older messages go in above: the page holds what they read where it is.
    ///   - sent: Changes when they send a message: the page goes to the end with it.
    func followsChatEnd<Sent: Equatable>(
        _ proxy: ScrollViewProxy, endID: some Hashable, readsEnd: Binding<Bool>, isLoadingEarlier: Bool = false,
        sent: Sent
    ) -> some View {
        modifier(ChatFollow(
            proxy: proxy, endID: AnyHashable(endID), readsEnd: readsEnd, isLoadingEarlier: isLoadingEarlier, sent: sent
        ))
    }
}

private struct ChatFollow<Sent: Equatable>: ViewModifier {
    let proxy: ScrollViewProxy
    let endID: AnyHashable
    @Binding var readsEnd: Bool
    let isLoadingEarlier: Bool
    let sent: Sent
    /// Where the page is scrolled to, set to hold the reader's place as the page changes under them.
    @State private var position = ScrollPosition(edge: .bottom)
    /// While a finger, or the fling it gave, moves the page: the page is theirs, not ours.
    @State private var isScrolling = false
    /// How tall the page was when they last touched it: what arrives while they scroll is not them scrolling away.
    @State private var heightAtTouch: CGFloat = 0

    /// The page's height, and where it is scrolled to as `ScrollPosition` counts it: from the top of the content, which
    /// the content offset counts from under the top bars.
    private struct PageSize: Equatable {
        var contentHeight: CGFloat
        var position: CGFloat

        init(_ geometry: ScrollGeometry) {
            contentHeight = geometry.contentSize.height
            position = geometry.contentOffset.y + geometry.contentInsets.top
        }
    }

    /// How far below the bottom bars and keyboard the end of the page is. The visible rect runs under the bars.
    private static func distanceToEnd(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height - (geometry.visibleRect.maxY - geometry.contentInsets.bottom)
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            // The page grows or shrinks under them: reading the end, they stay at it; loading earlier, what they read
            // stays where it is. Corrected as the page is laid out, so no frame shows it moved.
            .onScrollGeometryChange(for: PageSize.self, of: PageSize.init) { old, new in
                let grown = new.contentHeight - old.contentHeight
                guard grown != 0, !isScrolling else {
                    return
                }
                if isLoadingEarlier {
                    position.scrollTo(y: new.position + grown)
                } else if readsEnd {
                    position.scrollTo(edge: .bottom)
                }
            }
            // Where they read is where their own scrolling stops; the page growing, or the bars and keyboard moving,
            // says nothing of it.
            .onScrollPhaseChange { old, new, context in
                let geometry = context.geometry
                isScrolling = new == .interacting || new == .decelerating
                if new == .interacting {
                    heightAtTouch = geometry.contentSize.height
                }
                guard new == .idle, old != .idle else {
                    return
                }
                let distance = Self.distanceToEnd(geometry)
                readsEnd = distance <= ChatStyle.followSlack + max(0, geometry.contentSize.height - heightAtTouch)
                // A message that landed while they flung to the end is caught up with once they let go.
                if readsEnd, distance > 1 {
                    toEnd()
                }
            }
            // The keyboard, or a field growing, covers the end of the page: someone reading it stays with it.
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentInsets.bottom) { old, new in
                if readsEnd, new > old {
                    toEnd()
                }
            }
            // A message they send lands at the end: the page goes there with it.
            .onChange(of: sent) {
                readsEnd = true
                Task { @MainActor in
                    await Task.yield()
                    toEnd()
                }
            }
    }

    private func toEnd() {
        withAnimation(AppMotion.fold) { proxy.scrollTo(endID, anchor: .bottom) }
    }
}
