import SwiftUI

/// The parts of PRHub's own pages (onboarding, Sign in again, Delete Account): one look for each, so a change to one
/// is a change here (DESIGN.md, Components).

/// A page's title and what it is for, at the top of the page.
struct PageHeader: View {
    let title: String
    let message: String
    var messageIdentifier = "pageHeaderMessage"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.appTitle3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.appFootnote)
                .foregroundStyle(Color.inkQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(messageIdentifier)
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.lg)
    }
}

/// A block on the page's grey, the width of the screen, with its section's title above it.
struct PageBlock<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let title {
                PRSectionTitle(title)
            }
            VStack(alignment: .leading, spacing: Space.md) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.lg)
            .background(Color.groundCard)
        }
        .padding(.top, title == nil ? 0 : Space.lg)
    }
}

/// Why something didn't work, in place: the problem icon in the bad tone and the words.
struct ProblemLine: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.appFootnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(AppIcon.problem)
                .foregroundStyle(Color.toneBad)
        }
        .labelStyle(.iconText)
        .accessibilityElement(children: .combine)
    }
}
