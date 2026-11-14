import PRKit
import SwiftUI

/// The agent's coding thread and the unsent content the host moves into its own reply composer on handoff.
@MainActor
public struct FeatureConversation {
    public let thread: FeatureAgentThread
    public let draft: Binding<String>
    public let attachments: ComposerAttachments
}
