import PRKitDesign
import SwiftUI

extension View {
    /// A panel that slides in from the right over the page, which dims under it; a tap on the dim closes it, and a
    /// swipe to the right carries it with the finger, then lets it go or springs it back (DESIGN.md, Other parts). Where the screen has room, the diff puts its panel in a column instead (`PRPanelPlacement`).
    /// The panel draws its own ground.
    public func sidePanel(
        isPresented: Bool, close: @escaping () -> Void, @ViewBuilder panel: @escaping () -> some View
    ) -> some View {
        modifier(SidePanel(isPresented: isPresented, close: close, panel: panel))
    }
}

private struct SidePanel<Panel: View>: ViewModifier {
    let isPresented: Bool
    let close: () -> Void
    let panel: () -> Panel
    /// How far the finger has carried the panel to the right.
    @State private var dragged: CGFloat = 0
    /// Whether the drag under way is a swipe to the right, decided by its first move; `nil` between drags. One that
    /// starts as scrolling stays scrolling.
    @State private var isSwiping: Bool?

    private static var width: Double { PanelStyle.width }

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                Color.scrim.opacity(1 - min(dragged / Self.width, 1))
                    .ignoresSafeArea()
                    .transition(.opacity)
                GeometryReader { proxy in
                    let gap = max(proxy.size.width - Self.width, proxy.size.width * 0.14)
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: gap)
                            .contentShape(.rect)
                            .onTapGesture(perform: close)
                            .accessibilityLabel("Close")
                            .accessibilityAddTraits(.isButton)
                        panel()
                            .offset(x: dragged)
                            // Beside the panel's own scrolling and the rows' buttons, so a swipe that starts on a PR or
                            // ticket still carries it.
                            .simultaneousGesture(swipe(width: proxy.size.width - gap))
                    }
                }
                .transition(.move(edge: .trailing))
                .onDisappear { dragged = 0 }
            }
        }
    }

    /// Follows the finger to the right; let go past a third of the panel, or flung, it closes from where it is,
    /// else it springs back.
    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { drag in
                let swiping = isSwiping ?? (drag.translation.width > abs(drag.translation.height))
                isSwiping = swiping
                if swiping {
                    dragged = max(0, drag.translation.width)
                }
            }
            .onEnded { drag in
                defer { isSwiping = nil }
                guard isSwiping == true else {
                    return
                }
                if dragged > width / 3 || drag.predictedEndTranslation.width > width / 2 {
                    close()
                } else {
                    withAnimation(AppMotion.fold) { dragged = 0 }
                }
            }
    }
}
