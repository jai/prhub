import PRKitDesign
import SwiftUI

/// A section's title on the page's grey: the PR list's "Recently reviewed", the filter's "Orgs", an onboarding block's
/// "Or paste the setup link". The one look for every section title (DESIGN.md, Typography).
public struct PRSectionTitle: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.appFootnote.weight(.semibold))
            .foregroundStyle(Color.inkQuiet)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.lg)
            .accessibilityAddTraits(.isHeader)
    }
}
