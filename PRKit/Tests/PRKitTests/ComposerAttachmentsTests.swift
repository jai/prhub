import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PRKit

/// A screenshot on a message: made small enough to send, and the tray's limit.
@MainActor
struct ComposerAttachmentsTests {
    /// A PNG of noise, which compresses badly: the worst case for size.
    private func noisyPNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        var generator = SystemRandomNumberGenerator()
        let pixels = try #require(context.data).bindMemory(to: UInt32.self, capacity: context.bytesPerRow / 4 * height)
        for index in 0..<(context.bytesPerRow / 4 * height) {
            pixels[index] = UInt32.random(in: 0...UInt32.max, using: &generator) | 0xFF00_0000
        }
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    @Test func aBigScreenshotBecomesAJPEGOfAtMost1568PixelsAndUnderTheCap() throws {
        let encoded = try #require(ComposerImageEncoder.encode(try noisyPNG(width: 2_400, height: 3_000)))
        #expect(max(encoded.preview.width, encoded.preview.height) <= ComposerImageEncoder.maxPixels)
        #expect(encoded.jpeg.count <= ComposerImageEncoder.maxBytes)
        #expect(encoded.jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    @Test func aSmallOneKeepsItsSize() throws {
        let encoded = try #require(ComposerImageEncoder.encode(try noisyPNG(width: 300, height: 200)))
        #expect((encoded.preview.width, encoded.preview.height) == (300, 200))
    }

    @Test func wordsAreNotAnImage() {
        #expect(ComposerImageEncoder.encode(Data("not a picture".utf8)) == nil)
    }

    @Test func theTrayHoldsFourAndEmptiesWhenTaken() async throws {
        let attachments = ComposerAttachments()
        let png = try noisyPNG(width: 40, height: 40)
        for _ in 0..<5 {
            await attachments.add(png)
        }
        #expect(attachments.images.count == ComposerAttachments.limit)
        #expect(attachments.problem != nil)
        let taken = attachments.take()
        #expect(attachments.isEmpty && taken.count == 4)
        attachments.restore(taken)
        attachments.remove(taken[0].id)
        #expect(attachments.images.map(\.id) == taken.dropFirst().map(\.id))
        await attachments.add(Data("nope".utf8))
        #expect(attachments.problem == "That isn't an image the app can read.")
    }
}
