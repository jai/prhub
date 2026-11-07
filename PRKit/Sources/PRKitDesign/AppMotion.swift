import SwiftUI

/// The app's motion, in one place (DESIGN.md, Motion). A state change that moves the layout animates with one of these;
/// their durations are DESIGN.md's `x-motion` (`MotionTokens`).
public enum AppMotion {
    /// Something opening, closing or arriving in place.
    public static let fold = Animation.snappy(duration: MotionTokens.fold)
    /// One page or state replacing another where it stands, and a picture arriving.
    public static let swap = Animation.easeInOut(duration: MotionTokens.swap)
    /// A control being pressed, or a field taking focus.
    public static let press = Animation.easeOut(duration: MotionTokens.press)
    /// A Mac screen sliding in as it is pushed or returned to.
    public static let screen = Animation.smooth(duration: MotionTokens.screen)
}

extension AnyTransition {
    /// Content opening under a header: it fades while the layout around it moves. A slide would pass through the header.
    public static var fold: AnyTransition {
        .opacity
    }
}
