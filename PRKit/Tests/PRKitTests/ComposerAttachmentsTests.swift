import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PRKit

/// A screenshot on a message: made small enough to send, and the tray's limit.
@MainActor
@Suite(.serialized)
struct ComposerAttachmentsTests {
    /// A PNG of stripes, drawn rather than computed pixel by pixel: the suite runs beside PRKit's timing tests, so it
    /// stays cheap.
    private func stripedPNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for stripe in stride(from: 0, to: height, by: 40) {
            context.setFillColor(red: CGFloat(stripe % 255) / 255, green: 0.4, blue: 0.6, alpha: 1)
            context.fill(CGRect(x: 0, y: stripe, width: width, height: 20))
        }
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    @Test func aBigScreenshotBecomesAJPEGOfAtMost1568PixelsAndUnderTheCap() throws {
        let encoded = try #require(ComposerImageEncoder.encode(try stripedPNG(width: 1_200, height: 2_600)))
        #expect(max(encoded.preview.width, encoded.preview.height) <= ComposerImageEncoder.maxPixels)
        #expect(encoded.jpeg.count <= ComposerImageEncoder.maxBytes)
        #expect(encoded.jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    @Test func aSmallOneKeepsItsSize() throws {
        let encoded = try #require(ComposerImageEncoder.encode(try stripedPNG(width: 300, height: 200)))
        #expect((encoded.preview.width, encoded.preview.height) == (300, 200))
    }

    @Test func wordsAreNotAnImage() {
        #expect(ComposerImageEncoder.encode(Data("not a picture".utf8)) == nil)
    }

    @Test func theTrayHoldsFourAndEmptiesWhenTaken() async throws {
        let attachments = ComposerAttachments()
        let png = try stripedPNG(width: 40, height: 40)
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
