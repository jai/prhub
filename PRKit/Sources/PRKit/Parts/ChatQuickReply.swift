import Foundation
import PRKitDesign
import SwiftUI

/// A message Jai sends with one tap from a chat: what reaches the agent, and what his bubble says.
public enum ChatQuickReply: CaseIterable, Sendable {
    /// "Wait, what?" (Jai, 2026-11-13): the agent's last answer did not land, so it rewrites it. His agents load the
    /// `wait-what` skill on "wait, what?"; the plain sentence after it works where the skill is not installed.
    case waitWhat

    /// The words that reach the agent.
    public var text: String {
        switch self {
        case .waitWhat:
            "Wait, what? Rewrite your last reply so I can follow it: the answer first, short plain sentences, bullets. "
                + "Use the wait-what skill if you have it."
        }
    }

    /// The button's label, and what his bubble shows for it.
    public var label: String {
        switch self {
        case .waitWhat: "Wait, what?"
        }
    }

    /// What his bubble shows for words he sent: a quick reply's label, his own words otherwise.
    public static func shown(_ words: String) -> String {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.text == trimmed }?.label ?? words
    }
}

/// "Wait, what?": one tap asks the agent to say its last answer again, plainly (`ChatQuickReply.waitWhat`). `ChatView`
/// draws it under the agent's newest words when its host turns it on; a host may put it elsewhere too (a list row).
public struct WaitWhatButton: View {
    public var isSending: Bool
    public let send: () -> Void

    public init(isSending: Bool = false, send: @escaping () -> Void) {
        self.isSending = isSending
        self.send = send
    }

    public var body: some View {
        Button(action: send) {
            Text("\(Image(systemName: AppIcon.askAI.symbol)) \(ChatQuickReply.waitWhat.label)")
                .font(.appFootnote.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .disabled(isSending)
        .accessibilityLabel(ChatQuickReply.waitWhat.label)
        .accessibilityIdentifier("wait-what")
    }
}
