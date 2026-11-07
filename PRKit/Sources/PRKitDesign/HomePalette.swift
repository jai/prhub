import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The Home tab's colours (the mockup's `Palette`): burn and deficit orange, intake and surplus blue, protein purple.
/// In a file of its own since Round 7, so the widget compiles it without `HomeCharts.swift`, which imports Charts.
public enum HomePalette {
    public static let burn = Color.orange
    public static let active = Color.orange
    public static let intake = Color.blue
    public static let protein = Color.purple
    /// Opaque light orange for the resting part of a burn bar: the app's orange at 45%, flattened, so a label on it
    /// reads in both appearances.
    #if os(iOS)
    public static let restingBar = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.52, green: 0.32, blue: 0.11, alpha: 1)
            : UIColor(red: 1.00, green: 0.81, blue: 0.62, alpha: 1)
    })
    #else
    public static let restingBar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.52, green: 0.32, blue: 0.11, alpha: 1)
            : NSColor(red: 1.00, green: 0.81, blue: 0.62, alpha: 1)
    })
    #endif

    /// The grouped list's cell, which a band over a bar and a chart's badge are cut from, and the screen behind it.
    #if os(iOS)
    public static let cardBackground = Color(.secondarySystemGroupedBackground)
    public static let screenBackground = Color(.systemGroupedBackground)
    #else
    public static let cardBackground = Color(nsColor: .controlBackgroundColor)
    public static let screenBackground = Color(nsColor: .windowBackgroundColor)
    #endif

    public static func net(_ kcal: Double) -> Color {
        kcal < 0 ? burn : intake
    }
}
