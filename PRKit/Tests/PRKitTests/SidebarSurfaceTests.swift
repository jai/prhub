#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import PRKit

@MainActor
struct SidebarSurfaceTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func trailingEdgeRemainsVisible(_ scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content:
            Color.groundPage
                .frame(width: 100, height: 100)
                .sidebarSurface()
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2
        let image = try #require(renderer.uiImage?.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for row in [height / 4, height / 2, height * 3 / 4] {
            let edge = (row * width + width - 1) * 4
            let inside = (row * width + width - 8) * 4
            let difference = (0..<3).reduce(0) {
                $0 + abs(Int(pixels[edge + $1]) - Int(pixels[inside + $1]))
            }
            #expect(difference > 10, "The sidebar's trailing edge must be distinct from its surface")
        }
    }
}
#endif
