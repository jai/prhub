import PRKitDesign
import SwiftUI

/// A block on the page's grey, the width of the screen: its section's title above it and a note under it, both
/// optional. The one look for a page of blocks: onboarding, Sign in again and Settings (DESIGN.md, Page and block).
public struct PRPageBlock<Content: View>: View {
    let title: String?
    let note: String?
    let content: Content

    public init(_ title: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    public var body: some View {
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
            if let note {
                PRBlockNote(note)
            }
        }
        .padding(.top, title == nil ? 0 : Space.lg)
    }
}

/// What a block is for, or what its controls do, in quiet words under it.
public struct PRBlockNote: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.appCaption)
            .foregroundStyle(Color.inkQuiet)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.lg)
            .contentTransition(.opacity)
    }
}

/// A setting's name and its value on one line in a block: the name in ink, the value quiet at the right. At a large text
/// size the value goes under the name rather than squeezing it.
public struct PRValueLine<Value: View>: View {
    let name: String
    let value: Value

    public init(_ name: String, @ViewBuilder value: () -> Value) {
        self.name = name
        self.value = value()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                nameText
                Spacer(minLength: 0)
                valueView
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                nameText
                valueView
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var nameText: some View {
        Text(name)
            .font(.appFootnote)
            .foregroundStyle(Color.ink)
            .fixedSize()
    }

    private var valueView: some View {
        value
            .font(.appFootnote)
            .foregroundStyle(Color.inkQuiet)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
    }
}

extension PRValueLine where Value == Text {
    public init(_ name: String, value: String) {
        self.init(name) { Text(value) }
    }
}
