/// What a chat channel's screen says: its title, what an empty one asks, and the box's prompt.
public struct FeatureWording: Equatable, Sendable {
    public var title: String
    /// Shown while there are no chats, and in a new chat before its first message.
    public var emptyPrompt: String
    /// The box's placeholder in a new chat; a chat that has started says "Reply".
    public var placeholder: String
    /// A new chat's title and its button's label.
    public var newChat: String
    /// Under "The builder Mac is offline.": what happens to a message meanwhile.
    public var whileOffline: String
    /// A wide screen with no chat open.
    public var noneOpen: String
    public var noneOpenHint: String

    public init(
        title: String, emptyPrompt: String, placeholder: String, newChat: String = "New chat",
        whileOffline: String = "Messages wait until it is back.", noneOpen: String = "No chat open",
        noneOpenHint: String = "Pick a conversation, or start a new one."
    ) {
        self.title = title
        self.emptyPrompt = emptyPrompt
        self.placeholder = placeholder
        self.newChat = newChat
        self.whileOffline = whileOffline
        self.noneOpen = noneOpen
        self.noneOpenHint = noneOpenHint
    }

    /// Feature requests: changes to the app.
    public static let feedback = FeatureWording(
        title: "Feedback",
        emptyPrompt: "Say what to change in the app. An agent makes the change, tests it and ships a build.",
        placeholder: "What should change?", newChat: "New feedback",
        whileOffline: "Feedback waits until it is back.", noneOpen: "No feedback open",
        noneOpenHint: "Pick a conversation, or start new feedback."
    )
}
