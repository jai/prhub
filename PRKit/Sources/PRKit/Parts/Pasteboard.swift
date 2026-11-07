#if os(iOS)
import PRKitCore
import PRKitDesign
import UIKit
#else
import AppKit
#endif

/// Every Copy button's one write: the phone's general pasteboard, or the Mac's. `nil` leaves it empty.
@MainActor
public enum Pasteboard {
    public static func copy(_ text: String?) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        if let text {
            NSPasteboard.general.setString(text, forType: .string)
        }
        #endif
    }
}
