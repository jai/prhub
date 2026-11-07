import CoreText
import Foundation
import PRKitDesign
import SwiftUI

/// A monospaced face the diff and code can be drawn in. `system` is DESIGN.md's `code` family, the system's monospaced
/// font unless the token names another. The open-licence faces ship in PRKit (`Resources/Fonts`, each with its OFL)
/// and are registered for the process on first use, so no host app lists them in its Info.plist.
public enum DiffFontFace: String, CaseIterable, Identifiable, Sendable {
    case system
    case menlo
    case courierNew
    case sourceCodePro
    case jetBrainsMono
    case ibmPlexMono
    case firaCode

    public var id: Self { self }

    public var name: String {
        switch self {
        case .system: DesignTokens.codeFontFamily ?? "SF Mono"
        case .menlo: "Menlo"
        case .courierNew: "Courier New"
        case .sourceCodePro: "Source Code Pro"
        case .jetBrainsMono: "JetBrains Mono"
        case .ibmPlexMono: "IBM Plex Mono"
        case .firaCode: "Fira Code"
        }
    }

    /// The PostScript names of its regular and bold, or nil for the system's monospaced font.
    var postScriptNames: (regular: String, bold: String)? {
        switch self {
        case .system: DesignTokens.codeFontFamily.map { ($0, $0) }
        case .menlo: ("Menlo-Regular", "Menlo-Bold")
        case .courierNew: ("CourierNewPSMT", "CourierNewPS-BoldMT")
        case .sourceCodePro: ("SourceCodePro-Regular", "SourceCodePro-Bold")
        case .jetBrainsMono: ("JetBrainsMono-Regular", "JetBrainsMono-Bold")
        case .ibmPlexMono: ("IBMPlexMono-Regular", "IBMPlexMono-Bold")
        case .firaCode: ("FiraCode-Regular", "FiraCode-Bold")
        }
    }

    /// Its folder in `Resources/Fonts`, for the faces PRKit ships.
    var bundledFolder: String? {
        switch self {
        case .system, .menlo, .courierNew: nil
        case .sourceCodePro: "SourceCodePro"
        case .jetBrainsMono: "JetBrainsMono"
        case .ibmPlexMono: "IBMPlexMono"
        case .firaCode: "FiraCode"
        }
    }
}

/// The diff's font: a face and a size in points at the default text size, kept on the device. Every diff and code view
/// reads it, so a change in Settings redraws an open diff. Stored as `face:size` under `storageKey`; anything else
/// stored there reads as `standard`.
public struct DiffFont: Hashable, Sendable, RawRepresentable {
    public static let storageKey = "prkit.diffFont"
    public static let sizes: ClosedRange<CGFloat> = 9 ... 20
    /// Today's diff: DESIGN.md's `code` token.
    public static let standard = DiffFont(face: .system, size: DesignTokens.codeFontSize)
    /// How much bigger a file's header is than its code (DESIGN.md, "A heading is a step bigger").
    static let headingStep: CGFloat = 2

    public let face: DiffFontFace
    public let size: CGFloat

    /// A size outside `sizes` is held to it, and rounded to a whole point.
    public init(face: DiffFontFace, size: CGFloat) {
        self.face = face
        self.size = min(max(size.rounded(), Self.sizes.lowerBound), Self.sizes.upperBound)
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let face = DiffFontFace(rawValue: String(parts[0])),
              let size = Double(parts[1]), Self.sizes.contains(CGFloat(size)) else {
            return nil
        }
        self.init(face: face, size: CGFloat(size))
    }

    public var rawValue: String {
        "\(face.rawValue):\(Int(size))"
    }

    public func with(face: DiffFontFace) -> DiffFont {
        DiffFont(face: face, size: size)
    }

    public func with(size: CGFloat) -> DiffFont {
        DiffFont(face: face, size: size)
    }

    /// The face at `points`, as drawn: bold for a heading. The system face's heading is semibold, as it always was.
    func platformFont(points: CGFloat, isBold: Bool = false) -> PlatformFont {
        DiffFontRegistry.registerBundledFaces()
        if let names = face.postScriptNames,
           let font = PlatformFont(name: isBold ? names.bold : names.regular, size: points) {
            return font
        }
        return .monospacedSystemFont(ofSize: points, weight: isBold ? .semibold : .regular)
    }
}

extension AppStorage where Value == DiffFont {
    /// The device's diff font, `standard` until someone picks another.
    public init(diffFontIn store: UserDefaults? = nil) {
        self.init(wrappedValue: .standard, DiffFont.storageKey, store: store)
    }
}

/// Registers PRKit's own faces for this process, once.
enum DiffFontRegistry {
    private static let registration: Void = {
        for face in DiffFontFace.allCases {
            for url in fontFiles(of: face) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    static func registerBundledFaces() {
        registration
    }

    static func fontFiles(of face: DiffFontFace) -> [URL] {
        guard let folder = face.bundledFolder,
              let directory = Bundle.module.url(forResource: folder, withExtension: nil, subdirectory: "Fonts") else {
            return []
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "ttf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
