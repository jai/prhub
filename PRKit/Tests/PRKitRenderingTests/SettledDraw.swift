import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Drawing a view off screen until its picture has settled. Every test here that draws with `ImageRenderer` takes its
/// picture through `ImageRenderer.settledImage()`.
///
/// Why: a process's first draws wait for the Simulator to build its first Metal pipeline. `ImageRenderer` waits 2 seconds
/// for it ("image provider timed out"), then hands back a picture that is empty or unfinished. On GitHub's Macs that
/// build took 1.4 s, 2.5 s and 12.7 s on 2026-11-25 and 26, and failed five release runs in whichever suite drew first
/// (45609673448, 45609663914, 45631508480, 45640305687, 45746139535). The view was never at fault: it drew at once as
/// soon as the pipeline was there. So a draw the renderer gave up on is not a picture, however many there are, and the
/// wait for the renderer is a length of time, not a number of draws.
enum SettledDraw {
    /// A draw that takes this long is one the renderer gave up on: it waits 2 seconds, and a finished draw takes
    /// milliseconds.
    static let gaveUp: Duration = .seconds(1)
    /// How long the renderer gets to be ready. The longest build seen is 12.7 seconds.
    static let patience: Duration = .seconds(180)
    /// How many pictures a view gets to draw the same twice in a row.
    static let pictures = 6

    struct Unsettled: Error, CustomStringConvertible {
        let description: String
    }

    /// The picture `draw` makes once two in a row are the same and not empty.
    /// - A draw that took `gaveUp` or longer is drawn again, for as long as `patience`. It is never the picture and
    ///   never compared.
    /// - A view whose quick draws differ `pictures` times, or are empty, does not settle: that throws.
    /// - `waited` hears of the draws the renderer gave up on before the picture came.
    static func picture<Picture: Equatable>(
        patience: Duration = patience, now: () -> ContinuousClock.Instant = { .now }, isEmpty: (Picture) -> Bool,
        waited: (_ givenUp: Int, _ time: Duration) -> Void = { _, _ in }, draw: () throws -> Picture
    ) throws -> Picture {
        let start = now()
        var last: Picture?
        var drawn = 0
        var givenUp = 0
        while true {
            let before = now()
            let next = try draw()
            let after = now()
            if after - before >= gaveUp {
                givenUp += 1
                last = nil
                guard after - start < patience else {
                    throw Unsettled(description: "the renderer gave up on \(givenUp) draws in \(after - start)")
                }
                continue
            }
            if next == last, !isEmpty(next) {
                if givenUp > 0 {
                    waited(givenUp, after - start)
                }
                return next
            }
            drawn += 1
            guard drawn < pictures else {
                throw Unsettled(description: "the view drew \(drawn) pictures and no two in a row were the same and not empty")
            }
            last = next
        }
    }
}

@MainActor
extension ImageRenderer {
    /// The view's picture once it has settled (`SettledDraw`).
    func settledImage() throws -> CGImage {
        var image: CGImage?
        _ = try SettledDraw.picture(
            isEmpty: { bytes in !bytes.contains { $0 != 0 } },
            // In the run's log, so a release that met the slow renderer can be told from one that did not.
            waited: { givenUp, time in print("SettledDraw: the renderer gave up on \(givenUp) draws in \(time), then drew") },
            draw: { () -> [UInt8] in
                let next = try #require(cgImage)
                image = next
                return try Bitmap(next).bytes
            }
        )
        return try #require(image)
    }
}

extension CGImage {
    /// The picture as a PNG, for `Attachment.record`, on the phone and the Mac alike.
    func png() throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, self, nil)
        try #require(CGImageDestinationFinalize(destination), "the picture was written")
        return data as Data
    }
}
