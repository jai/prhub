import SwiftUI
import Testing
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// A view laid out in a window of a real size and drawn from it, for what `ImageRenderer` cannot draw: a page that
/// scrolls, its bars, and the safe area under them. On an iOS Simulator the window is in the host app's scene; on the
/// Mac it is a window of the test's own that is never shown. The window is the test's to close.
@MainActor
final class DrawnWindow {
    let size: CGSize
    #if os(iOS)
        let window: UIWindow
    #else
        let window: NSWindow
        private let host: NSView
    #endif

    init(
        _ view: some View, size: CGSize, in scheme: ColorScheme, textSize: DynamicTypeSize = .large
    ) throws {
        self.size = size
        let content = view
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, textSize)
        #if os(iOS)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let controller = UIHostingController(rootView: content)
            controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = controller
            window.isHidden = false
            window.layoutIfNeeded()
        #else
            _ = NSApplication.shared
            let host = NSHostingView(rootView: content)
            host.frame = CGRect(origin: .zero, size: size)
            window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            self.host = host
            host.layoutSubtreeIfNeeded()
        #endif
    }

    func close() {
        #if os(iOS)
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        #else
            window.contentView = nil
            window.close()
        #endif
    }

    /// The window's picture once two in a row are the same: a page's lazy rows and its bars come over a few turns of
    /// the run loop. `name`, when given, keeps the picture with the test's results.
    func picture(named name: String? = nil) async throws -> Bitmap {
        let deadline = ContinuousClock.now + .seconds(10)
        var last: Bitmap?
        while true {
            let next = try draw()
            if let last, last.bytes == next.bitmap.bytes {
                if let name {
                    Attachment.record(next.png, named: "\(name).png")
                }
                return next.bitmap
            }
            try #require(ContinuousClock.now < deadline, "the window's picture settles")
            last = next.bitmap
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// How much of the window's foot is the device's own safe area: a phone's home indicator. None on the Mac.
    var footInset: CGFloat {
        #if os(iOS)
            window.safeAreaInsets.bottom
        #else
            0
        #endif
    }

    /// How many of the picture's pixels a point is.
    func scale(of bitmap: Bitmap) -> CGFloat {
        CGFloat(bitmap.width) / size.width
    }

    private func draw() throws -> (bitmap: Bitmap, png: Data) {
        #if os(iOS)
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(drawn, "the window was drawn")
            return try (Bitmap(#require(image.cgImage)), #require(image.pngData()))
        #else
            host.layoutSubtreeIfNeeded()
            let drawing = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: drawing)
            return try (
                Bitmap(#require(drawing.cgImage)), #require(drawing.representation(using: .png, properties: [:]))
            )
        #endif
    }
}

// MARK: - The page's scroll view

extension DrawnWindow {
    #if os(iOS)
        /// Every view of this kind in the window, outermost first.
        func views<Kind: UIView>(_: Kind.Type) -> [Kind] {
            func within(_ view: UIView) -> [Kind] {
                ((view as? Kind).map { [$0] } ?? []) + view.subviews.flatMap(within)
            }
            return within(window)
        }

        /// The scroll view that scrolls the page up and down: the tallest one.
        private func page() throws -> UIScrollView {
            window.layoutIfNeeded()
            return try #require(views(UIScrollView.self).max { $0.bounds.height < $1.bounds.height }, "a scroll view")
        }
    #else
        private func page() throws -> NSScrollView {
            func within(_ view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(within)
            }
            host.layoutSubtreeIfNeeded()
            return try #require(within(host).max { $0.bounds.height < $1.bounds.height }, "a scroll view")
        }
    #endif

    /// How tall everything the page scrolls is.
    func pageHeight() throws -> CGFloat {
        #if os(iOS)
            try page().contentSize.height
        #else
            try #require(page().documentView).frame.height
        #endif
    }

    /// How far down the page is scrolled, from where it rests.
    func scrolled() throws -> CGFloat {
        #if os(iOS)
            let page = try page()
            return page.contentOffset.y + page.adjustedContentInset.top
        #else
            let page = try page()
            return page.contentView.bounds.minY + page.contentView.contentInsets.top
        #endif
    }

    /// Scrolls the page down by `distance`, as far as it goes: `.infinity` is its end.
    func scroll(by distance: CGFloat) throws {
        #if os(iOS)
            let page = try page()
            let inset = page.adjustedContentInset
            let end = max(-inset.top, page.contentSize.height - page.bounds.height + inset.bottom)
            page.setContentOffset(CGPoint(x: page.contentOffset.x, y: min(page.contentOffset.y + distance, end)), animated: false)
            page.layoutIfNeeded()
        #else
            let page = try page()
            let clip = page.contentView
            let inset = clip.contentInsets
            let height = try #require(page.documentView).frame.height
            let end = max(-inset.top, height - clip.bounds.height + inset.bottom)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(clip.bounds.minY + distance, end)))
            page.reflectScrolledClipView(clip)
        #endif
    }
}
