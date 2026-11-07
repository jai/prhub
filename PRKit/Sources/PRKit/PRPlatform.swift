import PRKitCore
import PRKitDesign
import SwiftUI
#if os(iOS)

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

    /// The keyboard goes; on the Mac, editing in the window ends.
    @MainActor public static func endEditing() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #else
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }
}

extension Color {
    public init(platform color: PlatformColor) {
        #if os(iOS)
        self.init(uiColor: color)
        #else
        self.init(nsColor: color)
        #endif
    }
}

extension View {
    /// The phone's diff runs under its bars, so they can go without moving the code. The Mac has no bars to hide.
    public func diffExtendsUnderBars() -> some View {
        #if os(iOS)
        ignoresSafeArea(.container, edges: .top)
        #else
        self
        #endif
    }

    public func phoneBarsHidden(_ isHidden: Bool) -> some View {
        #if os(iOS)
        toolbar(isHidden ? .hidden : .automatic, for: .navigationBar, .tabBar)
        #else
        self
        #endif
    }

    /// The phone's number pad; the Mac types numbers on its own keyboard.
    public func numericKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }
}
