import PRKitDesign
import SwiftUI

/// What a card's states do to it (DESIGN.md, PR card). At rest it is its ground alone. Under the pointer, and while its
/// PR is the one open beside the list, the ground lifts by `groundHover`; the open one is also marked down its
/// leading edge.
struct PRRowCardLook: Equatable {
    var isHovered = false
    var isSelected = false

    /// The ground carries the hover fill.
    var isLifted: Bool {
        isHovered || isSelected
    }

    /// The accent down the leading edge.
    var showsMark: Bool {
        isSelected
    }
}

extension EnvironmentValues {
    /// The card a `PrListBlock` is on (`PRRowCard`). The card draws the ground, so the block draws none of its own and
    /// its avatar backs itself with the card's. `nil` where a block lies on the page across its width: the phone, the
    /// iPad, and a host's own lists.
    @Entry var prRowCard: PRRowCardLook?
}

/// A card's ground with its state's lift: what the card draws, and what a part on it backs itself with to cover what
/// runs under it (an avatar over the rail).
struct PRRowGround: View {
    let look: PRRowCardLook

    var body: some View {
        Color.groundCard
            .overlay {
                if look.isLifted {
                    Color.groundHover
                }
            }
    }
}

/// One PR and its tickets on a card of their own, on the list's page (`Color.groundList`): the Mac's PR list (DESIGN.md,
/// PR card). The Mac's window and a block on it are one colour, so the band of the page that divides blocks on the
/// phone can't be seen there; a card has a corner, a hairline and a darker page around it.
///
/// What is on the card is not clipped to it: a keyboard focus ring around its PR or its ticket line is drawn whole.
struct PRRowCard<Content: View>: View {
    /// Its PR is the one open beside the list.
    let isSelected: Bool
    @ViewBuilder let content: Content
    @State private var isHovered = false

    private var look: PRRowCardLook {
        PRRowCardLook(isHovered: isHovered, isSelected: isSelected)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PRStyle.cardRadius, style: .continuous)
        content
            .environment(\.prRowCard, look)
            .background {
                PRRowGround(look: look)
                    .overlay(alignment: .leading) {
                        if look.showsMark {
                            Color.accentColor
                                .frame(width: Space.xs)
                        }
                    }
                    .clipShape(shape)
            }
            .overlay {
                shape
                    .strokeBorder(Color.line, lineWidth: PRStyle.hairline)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .animation(AppMotion.press, value: isHovered)
            .animation(AppMotion.swap, value: isSelected)
            .padding(.horizontal, Space.lg)
    }
}

extension View {
    /// A row of the PRs list, set apart as its platform does it. On the Mac it is a card of its own (`PRRowCard`). On
    /// the phone and the iPad it is the block as it is, across the width, filled where it is the one open beside the
    /// list (`selected`).
    @ViewBuilder func prListRow(isSelected: Bool) -> some View {
        #if os(macOS)
            PRRowCard(isSelected: isSelected) { self }
        #else
            selected(isSelected)
        #endif
    }

    /// A block's own ground, across its width: `groundCard`, or none on a card, which draws the ground itself.
    func blockGround() -> some View {
        modifier(PRBlockGround())
    }

    /// Backs an avatar with the ground it is on, so the rail under it stops at its rim.
    func avatarGround() -> some View {
        modifier(PRAvatarGround())
    }
}

/// Off the Mac nothing is a card, and the block's ground is drawn exactly as it was before cards.
private struct PRBlockGround: ViewModifier {
    #if os(macOS)
        @Environment(\.prRowCard) private var card
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
            content.background(card == nil ? Color.groundCard : Color.clear)
        #else
            content.background(Color.groundCard)
        #endif
    }
}

private struct PRAvatarGround: ViewModifier {
    #if os(macOS)
        @Environment(\.prRowCard) private var card
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
            content.background {
                PRRowGround(look: card ?? PRRowCardLook())
                    .clipShape(.circle)
            }
        #else
            content.background(Color.groundCard, in: .circle)
        #endif
    }
}
