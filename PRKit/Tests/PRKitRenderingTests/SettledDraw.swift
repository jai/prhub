import SwiftUI
import Testing

@MainActor
extension ImageRenderer {
    /// The picture once it has settled: drawn until two draws in a row are the same and not empty. Every test here that
    /// draws off screen takes its picture through this. A process's first draw can come back unfinished: on a slow Mac
    /// the renderer stops waiting for its images ("image provider timed out"), and on 2026-11-25 that first draw failed
    /// three releases, in whichever suite drew first (runs 45609673448, 45609663914 and 45631508480).
    func settledImage(draws: Int = 6) throws -> CGImage {
        var last = try #require(cgImage)
        var lastBytes = try Bitmap(last).bytes
        for _ in 1 ..< draws {
            let next = try #require(cgImage)
            let nextBytes = try Bitmap(next).bytes
            if nextBytes == lastBytes, nextBytes.contains(where: { $0 != 0 }) {
                return next
            }
            (last, lastBytes) = (next, nextBytes)
        }
        Issue.record("the view did not draw the same twice, or drew nothing, in \(draws) draws")
        return last
    }
}
