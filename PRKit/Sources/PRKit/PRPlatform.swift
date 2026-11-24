import PRKitCore
import PRKitDesign
import SwiftUI

#if os(iOS)
    import SafariServices

    public typealias PlatformColor = UIColor
    public typealias PlatformFont = UIFont
#else
    import AppKit

    public typealias PlatformColor = NSColor
    public typealias PlatformFont = NSFont
#endif

/// What the PR screens need from the platform under them, under one name: the phone's UIKit or the Mac's AppKit.
public enum PRPlatform {
    /// In the browser, past the app's own routing, which would open a PR link here.
    @MainActor public static func openExternally(_ url: URL) {
        #if os(iOS)
            UIApplication.shared.open(url)
        #else
            NSWorkspace.shared.open(url)
        #endif
    }

    /// The browser sheet's name to a UI test.
    public static let browserSheetIdentifier = "pr-ticket-browser"

    /// A page that is another app's, a Linear ticket: in that app when it is installed, else in a browser sheet over
    /// this one, so a look at it never leaves the PR. `openURL` can't say which happened, and sends a page with no app
    /// to Safari. The Mac opens it as the system does.
    @MainActor public static func openInItsAppOrHere(_ url: URL) {
        #if os(iOS)
            UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
                if !opened {
                    showBrowserSheet(url)
                }
            }
        #else
            NSWorkspace.shared.open(url)
        #endif
    }

    #if os(iOS)
        /// Over whatever is on top in the window in use, a sheet included. Safari itself when there is no window to
        /// put it over, and for anything a browser sheet can't show.
        @MainActor private static func showBrowserSheet(_ url: URL) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            let window = scenes.compactMap(\.keyWindow).first(where: \.isKeyWindow) ?? scenes.first?.keyWindow
            guard var top = window?.rootViewController, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                UIApplication.shared.open(url)
                return
            }
            while let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            let browser = SFSafariViewController(url: url)
            browser.view.accessibilityIdentifier = browserSheetIdentifier
            top.present(browser, animated: true)
        }
    #endif

    /// The keyboard goes; on the Mac, editing in the window ends.
    @MainActor public static func endEditing() {
        #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #else
            NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }
}

public extension Color {
    init(platform color: PlatformColor) {
        #if os(iOS)
            self.init(uiColor: color)
        #else
            self.init(nsColor: color)
        #endif
    }
}

public extension View {
    /// The phone's diff runs under its bars, so they can go without moving the code. The Mac has no bars to hide.
    func diffExtendsUnderBars() -> some View {
        #if os(iOS)
            ignoresSafeArea(.container, edges: .top)
        #else
            self
        #endif
    }

    func phoneBarsHidden(_ isHidden: Bool) -> some View {
        #if os(iOS)
            toolbar(isHidden ? .hidden : .automatic, for: .navigationBar, .tabBar)
        #else
            self
        #endif
    }

    /// The phone's number pad; the Mac types numbers on its own keyboard.
    func numericKeyboard() -> some View {
        #if os(iOS)
            keyboardType(.numbersAndPunctuation)
        #else
            self
        #endif
    }
}
