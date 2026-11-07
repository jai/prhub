import SwiftUI

/// The app's motion, in one place (docs/design.md). A state change that moves the layout animates with one of these.
public enum AppMotion {
    /// Something opening, closing or arriving in place.
    public static let fold = Animation.snappy(duration: 0.28)
    /// One page or state replacing another where it stands.
    public static let swap = Animation.easeInOut(duration: 0.18)
}

extension AnyTransition {
    /// Content opening under a header: it fades while the layout around it moves. A slide would pass through the header.
    public static var fold: AnyTransition {
        .opacity
    }
}
