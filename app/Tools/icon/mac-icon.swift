// The Mac's app icon, from the phone's: `swift app/Tools/icon/mac-icon.swift` from the repo root, after PRHubIcon.png
// changes. The phone's icon fills its square and iOS cuts the corners; a Mac icon carries its own shape, so each size
// is the same art on the Mac's rounded square (824 of 1024 points, corner 185.4) with clear margins. App Store Connect
// refuses a Mac build whose icon has no 512 pt @2x image (ITMS-90236).
import AppKit

let set = URL(filePath: "app/PRHub/Assets.xcassets/AppIcon.appiconset")
guard let art = NSImage(contentsOf: set.appending(path: "PRHubIcon.png"))?
    .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("no PRHubIcon.png in \(set.path): run from the repo root")
}
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let side = CGFloat(pixels)
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    let body = CGRect(x: side * 100 / 1024, y: side * 100 / 1024, width: side * 824 / 1024, height: side * 824 / 1024)
    let corner = side * 185.4 / 1024
    context.addPath(CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.clip()
    context.draw(art, in: body)
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try png.write(to: set.appending(path: "PRHubIconMac-\(pixels).png"))
}
