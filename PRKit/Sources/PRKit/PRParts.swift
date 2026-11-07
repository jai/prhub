import PRKitCore
import PRKitDesign
import SwiftUI

extension View {
    /// The box every comment and section sits in. It clips, so what opens inside it slides in from under the header.
    public func prCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.groundCard)
            .clipShape(.rect(cornerRadius: PRStyle.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PRStyle.cardRadius, style: .continuous)
                    .strokeBorder(Color.line, lineWidth: PRStyle.hairline)
            )
    }
}

/// A button on a PR's screens. The system's `.bordered` is a capsule on iOS 26, so these are drawn here. `.tint` colours
/// primary and secondary.
public struct PRButtonStyle: ButtonStyle {
    public enum Kind {
        case primary, secondary, plain
    }

    public let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appFootnote.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, PRStyle.inset)
            .frame(minHeight: PRStyle.controlHeight)
            .background(background, in: .rect(cornerRadius: PRStyle.controlRadius, style: .continuous))
            .contentShape(.rect.inset(by: -6))
            .opacity(isEnabled ? (configuration.isPressed ? PRStyle.pressedOpacity : 1) : PRStyle.disabledOpacity)
            .animation(AppMotion.press, value: configuration.isPressed)
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(Color.onAccent)
        case .secondary: AnyShapeStyle(.tint)
        case .plain: AnyShapeStyle(.secondary)
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(.tint)
        case .secondary: AnyShapeStyle(Color.groundFill)
        case .plain: AnyShapeStyle(.clear)
        }
    }
}

/// What someone wrote on a PR: the one place its type is set.
public struct PRCommentText: View {
    public let text: String
    /// Given, the text's checkboxes can be tapped.
    public let onCheckbox: ((Int, Bool) -> Void)?
    /// See `MarkdownText.firstBlockInset`.
    public var firstBlockInset: CGFloat = 0

    public init(_ text: String, firstBlockInset: CGFloat = 0, onCheckbox: ((Int, Bool) -> Void)? = nil) {
        self.text = text
        self.firstBlockInset = firstBlockInset
        self.onCheckbox = onCheckbox
    }

    public var body: some View {
        MarkdownText(
            text, headingFont: .appFootnote.weight(.semibold), firstBlockInset: firstBlockInset, onCheckbox: onCheckbox
        )
            .font(.appFootnote)
            .lineSpacing(PRStyle.bodyLineSpacing)
    }
}

public struct PRAvatar: View {
    public let author: PullRequestDetail.Author?

    public var body: some View {
        AsyncImage(url: author?.avatarUrl.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text((author?.login.prefix(1) ?? "?").uppercased())
                .font(.appCaption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.groundFill)
        }
        .frame(width: 20, height: 20)
        .clipShape(.circle)
    }
}

/// Who said it and when, the same on every comment.
public struct PRAuthorLine: View {
    public let author: PullRequestDetail.Author?
    public let date: Date?

    public var body: some View {
        HStack(spacing: Space.sm) {
            PRAvatar(author: author)
            Text(author?.login ?? "ghost")
                .font(.appFootnote.weight(.semibold))
                .lineLimit(1)
            if let date {
                Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

public struct PRChevron: View {
    public let isCollapsed: Bool

    public var body: some View {
        Image(systemName: "chevron.down")
            .font(.appCaption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
    }
}

/// Where a comment is written, always in place: under the line, in the thread, or under the button that opened it. A
/// refusal shows GitHub's reason here, and the words stay in the box.
extension Binding where Value == String? {
    /// For a box open while this has a value. SwiftUI's `Binding(_:)` unwrapping one force-unwraps it, and Cancel clearing
    /// the value while the box is still leaving crashes on that. A write as it leaves doesn't open it again.
    public var whileOpen: Binding<String> {
        Binding<String> { wrappedValue ?? "" } set: { text in
            if wrappedValue != nil {
                wrappedValue = text
            }
        }
    }
}

public struct InlineComposer: View {
    /// A second way to send the same words, beside the main button.
    public struct Alternate {
        public let title: String
        public let send: (String) async throws -> Void
    }

    /// The session's, so the words outlast this box: a scroll or a reload can take the box, never what is in it.
    @Binding public var text: String
    public let placeholder: String
    public let buttonTitle: String
    public var context: String?
    public var needsText = true
    public var lines = 3...10
    public var alternate: Alternate?
    /// Takes the words to the PR's AI agent instead.
    public var ask: ((String) -> Void)?
    public let send: (String) async throws -> Void
    public let cancel: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isSending = false
    @State private var failure: String?
    @State private var posted = 0

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let context {
                Text(verbatim: context)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.appFootnote)
                .lineSpacing(PRStyle.bodyLineSpacing)
                .lineLimit(lines)
                .focused($isFocused)
                .padding(.horizontal, PRStyle.inset)
                .padding(.vertical, Space.sm)
                .background(
                    Color.groundFill,
                    in: .rect(cornerRadius: PRStyle.controlRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PRStyle.controlRadius, style: .continuous)
                        .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 1)
                )
                .animation(AppMotion.press, value: isFocused)
                .accessibilityIdentifier("inline-composer-field")
            if let failure {
                Text(failure)
                    .font(.appFootnote)
                    .foregroundStyle(.red)
                    .transition(.fold)
            }
            HStack(spacing: Space.sm) {
                if let ask {
                    Button("Ask AI", systemImage: "bubble.left.and.text.bubble.right") { ask(trimmed) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(PRButtonStyle(.secondary))
                        .accessibilityLabel("Ask AI")
                        .accessibilityIdentifier("inline-composer-ask")
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(PRButtonStyle(.plain))
                if let alternate {
                    Button(alternate.title) { Task { await submit(through: alternate.send) } }
                        .buttonStyle(PRButtonStyle(.secondary))
                        .disabled(isSending || trimmed.isEmpty)
                        .accessibilityIdentifier("inline-composer-alternate")
                }
                Button {
                    Task { await submit(through: send) }
                } label: {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.onAccent)
                    } else {
                        Text(buttonTitle)
                    }
                }
                .buttonStyle(PRButtonStyle(.primary))
                .disabled(isSending || (needsText && trimmed.isEmpty))
                .accessibilityIdentifier("inline-composer-send")
            }
        }
        .sensoryFeedback(.success, trigger: posted)
        .onAppear { isFocused = text.isEmpty }
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit(through send: (String) async throws -> Void) async {
        isSending = true
        defer { isSending = false }
        do {
            try await send(trimmed)
            posted += 1
        } catch {
            withAnimation(AppMotion.fold) { failure = error.localizedDescription }
        }
    }
}

extension View {
    /// A row whose newest files would not download, with a line under it saying so.
    func notUpdated(_ isNotUpdated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            self
            if isNotUpdated {
                PRNotUpdatedNote()
                    .transition(.fold)
            }
        }
        .animation(AppMotion.fold, value: isNotUpdated)
    }
}

/// Under a row whose newest files would not download: it shows the last good revision until a pull tries again.
struct PRNotUpdatedNote: View {
    var body: some View {
        Text("Couldn't update · Pull to try again")
            .font(.appCaption)
            .foregroundStyle(Color.toneWaiting)
            .padding(.leading, Space.lg + PrListGrid.avatar + PrListGrid.gutter)
            .padding(.bottom, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.groundCard)
            .accessibilityIdentifier("pr-not-updated")
    }
}
