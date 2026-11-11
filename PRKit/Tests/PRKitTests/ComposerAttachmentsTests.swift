import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PRKit

/// A screenshot on a message: made small enough to send, and the tray's limit. Off the main actor but for the tray, so
/// drawing and encoding pictures never holds up the PR screens' tests, which run on it beside these.
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

    /// A two-second H.264 film of 160×120 frames, written to a temporary file.
    private func film() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 12), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test @MainActor func aVideoBecomesStillsFromAcrossItAsTheTrayHasRoom() async throws {
        let url = try await film()
        defer { try? FileManager.default.removeItem(at: url) }
        let attachments = ComposerAttachments()
        await attachments.add(try stripedPNG(width: 40, height: 40))
        await attachments.add(video: url)
        #expect(attachments.images.count == ComposerAttachments.limit, "three stills fill the room left")
        #expect(attachments.problem == nil)
        #expect(attachments.images.dropFirst().allSatisfy { $0.jpeg.starts(with: [0xFF, 0xD8, 0xFF]) })
        await attachments.add(video: url)
        #expect(attachments.problem != nil, "a full tray takes no more")
    }

    @Test @MainActor func aFileThatIsNoVideoSaysSo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data("not a film".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let attachments = ComposerAttachments()
        await attachments.add(video: url)
        #expect(attachments.isEmpty)
        #expect(attachments.problem == "That video couldn't be read.")
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

    @Test @MainActor func theTrayHoldsFourAndEmptiesWhenTaken() async throws {
        let png = try stripedPNG(width: 40, height: 40)
        let attachments = ComposerAttachments()
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
