import Foundation

/// A screenshot on a message, as a Worker takes it: a JPEG, base64. Agent Pager's thread replies and FeatureKit's
/// requests send it.
public struct MessageImage: Codable, Equatable, Sendable {
    // swiftlint:disable:next identifier_name
    public var media_type = "image/jpeg"
    public var data: String

    public init(jpeg: Data) {
        data = jpeg.base64EncodedString()
    }

    public static let limit = 4
}

/// A message's words as a bubble shows them, with a line for the screenshots it carried: the bubble shows that they
/// went, not the pictures.
public enum ScreenshotLine {
    public static func bubbleText(_ words: String, screenshots: Int) -> String {
        guard screenshots > 0 else {
            return words
        }
        let line = screenshots == 1 ? "Screenshot attached" : "\(screenshots) screenshots attached"
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? line : "\(trimmed)\n\n\(line)"
    }
}
