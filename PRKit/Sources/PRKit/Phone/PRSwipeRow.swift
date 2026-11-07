#if os(iOS)
import PRKitCore
import PRKitDesign
import SwiftUI
import UIKit

/// A row that slides to show an action on either side: right for `leading` (Review changes), left for `trailing`
/// (Remove me). It is drawn here because a list's own swipe needs a `List`, and these rows sit in a plain stack
/// (`DESIGN.md`). The row's long-press menu lists the same actions.
struct PRSwipeRow<Content: View>: View {
    private static var width: CGFloat { 132 }

    var leading: PRSwipeAction?
    var trailing: PRSwipeAction?
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0
    /// Where the row sat when the finger took it: a swipe carries on from an action already showing.
    @State private var start: CGFloat?

    var body: some View {
        content
            .environment(\.rowSwipeActions, [leading, trailing].compactMap(\.self))
            .offset(x: offset)
            .background(alignment: .leading) {
                if let leading, offset > 0 {
                    button(leading)
                }
            }
            .background(alignment: .trailing) {
                if let trailing, offset < 0 {
                    button(trailing)
                }
            }
            .clipped()
            .gesture(HorizontalPan { translation in
                let from = start ?? offset
                start = from
                offset = min(maxOffset, max(minOffset, from + translation))
            } ended: { _ in
                start = nil
                withAnimation(AppMotion.fold) {
                    offset = offset > Self.width / 2 ? Self.width : offset < -Self.width / 2 ? -Self.width : 0
                }
            })
            .accessibilityActions {
                ForEach([leading, trailing].compactMap(\.self), id: \.id) { action in
                    Button(action.title) { run(action) }
                }
            }
    }

    /// How far the row slides: past its action a little, and not at all toward a side with none.
    private var maxOffset: CGFloat { leading == nil ? 0 : Self.width * 1.5 }
    private var minOffset: CGFloat { trailing == nil ? 0 : -Self.width * 1.5 }

    private func button(_ swipe: PRSwipeAction) -> some View {
        Button {
            run(swipe)
        } label: {
            Text(swipe.title)
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(Color.onAccent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.sm)
                .frame(width: max(Self.width, abs(offset)))
                .frame(maxHeight: .infinity)
                .background(swipe.tone.ground)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(swipe.id)
        .transition(.opacity)
    }

    private func run(_ swipe: PRSwipeAction) {
        withAnimation(AppMotion.fold) { offset = 0 }
        swipe.action()
    }
}

/// A pan that starts only sideways, so the list under it still scrolls.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else {
                return false
            }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: changed(translation)
        case .ended, .cancelled: ended(translation)
        default: break
        }
    }
}
#endif
