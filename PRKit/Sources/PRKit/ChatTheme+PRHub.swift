@_exported import AgentChatKit
import PRKitDesign
import SwiftUI

public extension ChatTheme {
    /// DESIGN.md's chat: its text styles, colour roles and icons, and a code block in the diff's font.
    static let prHub = ChatTheme(
        font: { Font.app($0) },
        code: { AnyView($0.diffCodeFont(step: Font.appleSize(.footnote) - DiffFont.standard.size)) },
        ink: .ink, inkQuiet: .inkQuiet, onBubble: .onBubble, groundPage: .groundPage, groundCard: .groundCard,
        groundFill: .groundFill, line: .line, toneGood: .toneGood, toneBad: .toneBad, toneWaiting: .toneWaiting,
        symbols: {
            var symbols = ChatTheme.Symbols()
            symbols.toolCall = AppIcon.toolCall.symbol
            symbols.copy = AppIcon.copy.symbol
            symbols.askAI = AppIcon.askAI.symbol
            symbols.close = AppIcon.close.symbol
            symbols.problem = AppIcon.problem.symbol
            symbols.attach = AppIcon.attach.symbol
            symbols.attachPhoto = AppIcon.attachPhoto.symbol
            symbols.attachFile = AppIcon.attachFile.symbol
            symbols.taskOpen = AppIcon.taskOpen.symbol
            symbols.taskDone = AppIcon.taskDone.symbol
            symbols.fold = AppIcon.fold.symbol
            symbols.back = AppIcon.back.symbol
            symbols.compose = AppIcon.compose.symbol
            symbols.conversation = AppIcon.conversation.symbol
            symbols.drillIn = AppIcon.drillIn.symbol
            symbols.paused = AppIcon.paused.symbol
            return symbols
        }()
    )
}
