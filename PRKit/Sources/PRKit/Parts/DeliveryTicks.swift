import PRKitDesign
import SwiftUI

/// How far a message of Jai's has got, as ticks beside its time, as a messaging app shows it: one once the Worker has
/// it, two once the agent has it. A message still on its way, or failed, has none: its status says so in words.
/// Every chat draws them: a thread in Agent Pager, Ask AI on a PR.
public enum DeliveryTicks: Int, Equatable, Sendable {
    case sent = 1
    case delivered = 2

    /// What VoiceOver says for them.
    public var spoken: String {
        switch self {
        case .sent: "Sent"
        case .delivered: "Delivered"
        }
    }
}

/// Under one of Jai's bubbles: its time, then its ticks, the second over the first.
public struct DeliveryTicksLine: View {
    public let ticks: DeliveryTicks
    public let date: Date?
    /// The message's words, as its value, so the line can be found by the message it is under.
    public var about: String?

    public init(ticks: DeliveryTicks, date: Date?, about: String? = nil) {
        self.ticks = ticks
        self.date = date
        self.about = about
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            if let date {
                Text(date.formatted(date: .omitted, time: .shortened))
            }
            HStack(spacing: ChatStyle.tickOverlap) {
                ForEach(0..<ticks.rawValue, id: \.self) { _ in
                    Image(AppIcon.delivered)
                }
            }
            .foregroundStyle(ticks == .delivered ? Color.toneGood : Color.inkQuiet)
        }
        .font(.appCaption2)
        .foregroundStyle(Color.inkQuiet)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([date?.formatted(date: .omitted, time: .shortened), ticks.spoken].compactMap(\.self)
            .joined(separator: ", "))
        .accessibilityValue(about ?? "")
        .accessibilityIdentifier("reply-ticks-\(ticks.rawValue)")
    }
}
