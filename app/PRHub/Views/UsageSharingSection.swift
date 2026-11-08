import SwiftUI

/// Settings' "Share anonymous usage": on until the person turns it off. Shown only when the build names an analytics
/// project (`UsageAnalytics.hasProject`).
struct UsageSharingSection: View {
    let usage: UsageAnalytics

    var body: some View {
        if usage.hasProject {
            PRPageBlock(
                "Privacy",
                note: "Which screens and features you use, with no GitHub account, repo, PR or code in it. It helps "
                    + "make PRHub better. Nothing is sent while this is off."
            ) {
                Toggle("Share anonymous usage", isOn: Binding(get: { usage.isSharing }, set: { usage.setSharing($0) }))
                    .accessibilityIdentifier("prhub-share-usage")
            }
        }
    }
}

extension View {
    /// The diff font's face and size, each time Settings changes them.
    func recordsDiffFontChanges(_ usage: UsageAnalytics) -> some View {
        modifier(DiffFontChangeRecorder(usage: usage))
    }

    /// `screen` each time it shows.
    func recordsScreen(_ screen: AnalyticsScreen?, _ usage: UsageAnalytics) -> some View {
        onChange(of: screen, initial: true) { _, screen in
            if let screen {
                usage.record(.screenViewed(screen))
            }
        }
    }
}

private struct DiffFontChangeRecorder: ViewModifier {
    let usage: UsageAnalytics
    @AppStorage(diffFontIn: nil) private var diffFont

    func body(content: Content) -> some View {
        content.onChange(of: diffFont) { _, font in
            usage.record(.diffFontChanged(font.face, size: Int(font.size)))
        }
    }
}
