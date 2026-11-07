#if os(iOS)
import PRKitCore
import PRKitDesign
import SwiftUI
import UIKit

/// A row that slides left to show one action. It is drawn here because a list's own swipe needs a `List`, and these rows
/// sit in a plain stack (`DESIGN.md`).
struct PRSwipeRow<Content: View>: View {
    private static var width: CGFloat { 132 }

    let title: String
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0

    var body: some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                Button(action: run) {
                    Text(title)
                        .font(.appFootnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .frame(width: Self.width)
                        .frame(maxHeight: .infinity)
                        .background(Color("ToneBad"))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pr-remove-request")
            }
            .clipped()
            .gesture(HorizontalPan { translation in
                offset = min(0, translation)
            } ended: { translation in
                withAnimation(AppMotion.fold) { offset = translation < -Self.width / 2 ? -Self.width : 0 }
            })
            .accessibilityAction(named: title, action)
    }

    private func run() {
        withAnimation(AppMotion.fold) { offset = 0 }
        action()
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
