import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Return in a message box, with a hardware keyboard: it sends, and so does Command-Return; Shift-Return (and
/// Option-Return) starts a new line, as in the chat apps Jai uses (2026-11-12: "on an iPad … I can't hit Enter or
/// Command + Enter"). The on-screen keyboard's return key is not a hardware key: it keeps starting a new line, and the
/// send button sends.
public enum ReturnKey: Equatable, Sendable {
    case send
    case newLine

    /// The modifiers held with Return.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let shift = Self(rawValue: 1 << 0)
        public static let option = Self(rawValue: 1 << 1)
        public static let command = Self(rawValue: 1 << 2)
        public static let control = Self(rawValue: 1 << 3)
    }

    public static func action(_ modifiers: Modifiers) -> Self {
        modifiers.contains(.shift) || modifiers.contains(.option) ? .newLine : .send
    }
}

extension ReturnKey.Modifiers {
    init(_ modifiers: EventModifiers) {
        self = []
        if modifiers.contains(.shift) { insert(.shift) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.command) { insert(.command) }
        if modifiers.contains(.control) { insert(.control) }
    }
}

extension View {
    /// The Mac's Return in a message field (`ReturnKey`): Return and Command-Return send; Shift-Return and
    /// Option-Return start a new line at the cursor. The phone's field takes its keys itself (`ChatTextView`).
    public func sendsOnReturn(_ send: @escaping () -> Void) -> some View {
        #if os(macOS)
        onKeyPress(.return, phases: .down) { press in
            switch ReturnKey.action(ReturnKey.Modifiers(press.modifiers)) {
            case .send:
                send()
                return .handled
            case .newLine:
                // As Option-Return does, at the cursor: the field takes a bare Shift-Return as Return.
                NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                return .handled
            }
        }
        #else
        self
        #endif
    }
}
