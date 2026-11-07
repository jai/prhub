import PRKitCore
import PRKitDesign
import SwiftUI

/// A small tinted capsule for a state word such as `written` or `ack pending`.
public struct StatusChip: View {
    public let text: String
    public let tint: Color

    public init(text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.appCaption2.weight(.semibold))
            .padding(.horizontal, ChipStyle.horizontal)
            .padding(.vertical, ChipStyle.vertical)
            .foregroundStyle(tint)
            .background(tint.opacity(ChipStyle.groundOpacity), in: Capsule())
    }
}
