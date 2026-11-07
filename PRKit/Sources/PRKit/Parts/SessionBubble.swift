import PRKitDesign
import SwiftUI

/// A message in any of the app's chats — a thread, a session message, Ask AI on a PR, Feedback: the agent's on the left
/// in Markdown, Jai's on the right in the accent as he typed them, the time or a note under it, and what hangs under it —
/// where a reply of his stands, or the question waiting on him.
public struct SessionBubble<Accessory: View>: View {
    public let title: String?
    public let text: String
    public let date: Date?
    public let isMine: Bool
    public var footnote: String?
    public let accessory: Accessory

    public init(
        title: String?, text: String, date: Date?, isMine: Bool, footnote: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.text = text
        self.date = date
        self.isMine = isMine
        self.footnote = footnote
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(.appBody.weight(.semibold))
                }
                // An agent writes Markdown; Jai's own words are drawn as he typed them.
                if isMine {
                    Text(text)
                        .textSelection(.enabled)
                } else {
                    MarkdownText(text)
                }
            }
            .font(.appCallout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(isMine ? .white : .primary)
            .background(
                isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.secondary),
                in: .rect(cornerRadius: 18, style: .continuous)
            )
            if !caption.isEmpty {
                Text(caption)
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
            }
            accessory
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .padding(isMine ? .leading : .trailing, 48)
    }

    private var caption: String {
        [date?.formatted(date: .omitted, time: .shortened), footnote].compactMap(\.self).joined(separator: " · ")
    }
}

extension SessionBubble where Accessory == EmptyView {
    public init(title: String?, text: String, date: Date?, isMine: Bool, footnote: String? = nil) {
        self.init(title: title, text: text, date: date, isMine: isMine, footnote: footnote) { EmptyView() }
    }
}
