import AVFoundation
import CoreTransferable
import ImageIO
import Observation
import PhotosUI
import PRKitDesign
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A screenshot waiting to go with a message: the JPEG that will be sent, and its picture for the tray.
public struct ComposerImage: Identifiable {
    public let id = UUID()
    /// What is sent: a JPEG at most `ComposerImageEncoder.maxPixels` on its long side.
    public let jpeg: Data
    let preview: CGImage
}

/// The screenshots on one message box, before they are sent (`SessionComposer`'s `attachments`). Each is made small enough
/// for an agent to read as it is added, so what the tray shows is what goes.
@MainActor
@Observable
public final class ComposerAttachments {
    public static let limit = 4

    public private(set) var images: [ComposerImage] = []
    /// Why the last image could not be added.
    public private(set) var problem: String?

    public init() {}

    public var isEmpty: Bool { images.isEmpty }
    var isFull: Bool { images.count >= Self.limit }

    /// Adds an image from the photo library, a file or the clipboard, made into a JPEG for sending.
    public func add(_ data: Data) async {
        guard !isFull else {
            problem = "At most \(Self.limit) screenshots on one message."
            return
        }
        guard let encoded = await Task.detached(priority: .userInitiated, operation: {
            ComposerImageEncoder.encode(data)
        }).value else {
            problem = "That isn't an image the app can read."
            return
        }
        problem = nil
        if !isFull {
            images.append(ComposerImage(jpeg: encoded.jpeg, preview: encoded.preview))
        }
    }

    /// Adds a video as stills from across it, as many as the tray has room for, at most `ComposerVideo.stills`: an
    /// agent reads pictures, not a film.
    public func add(video url: URL) async {
        guard !isFull else {
            problem = "At most \(Self.limit) screenshots on one message."
            return
        }
        let room = min(ComposerVideo.stills, Self.limit - images.count)
        let stills = await ComposerVideo.stills(of: url, count: room)
        guard !stills.isEmpty else {
            problem = "That video couldn't be read."
            return
        }
        for still in stills {
            await add(still)
        }
    }

    public func remove(_ id: ComposerImage.ID) {
        images.removeAll { $0.id == id }
        problem = nil
    }

    /// Everything in the tray, which empties: the message is on its way.
    public func take() -> [ComposerImage] {
        defer { images = [] }
        problem = nil
        return images
    }

    /// Puts back what `take()` gave, when the send did not go.
    public func restore(_ taken: [ComposerImage]) {
        images = Array((taken + images).prefix(Self.limit))
    }

    func failed(_ why: String) {
        problem = why
    }
}

/// Makes a picture small enough to send and for an agent to read whole: at most 1568 px on its long side (the most a
/// Claude model reads without scaling it down), as a JPEG under 1.5 MB, upright, with no metadata.
public enum ComposerImageEncoder {
    public static let maxPixels = 1568
    public static let maxBytes = 1_500_000

    public static func encode(_ data: Data) -> (jpeg: Data, preview: CGImage)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        for (pixels, quality) in [(maxPixels, 0.8), (maxPixels, 0.6), (1024, 0.6)] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
            else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }
            if out.length <= maxBytes {
                return (out as Data, image)
            }
        }
        return nil
    }
}

/// Stills from a video, evenly across it, each a JPEG that `ComposerImageEncoder` then makes small enough to send.
public enum ComposerVideo {
    public static let stills = 4

    /// `count` stills, from the middle of each of `count` equal stretches, upright; none if it can't be read.
    public static func stills(of url: URL, count: Int) async -> [Data] {
        let asset = AVURLAsset(url: url)
        guard count > 0, let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            return []
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let side = CGFloat(ComposerImageEncoder.maxPixels)
        generator.maximumSize = CGSize(width: side, height: side)
        var stills: [Data] = []
        for index in 0..<count {
            let time = CMTimeMultiplyByFloat64(duration, multiplier: (Double(index) + 0.5) / Double(count))
            guard let (image, _) = try? await generator.image(at: time), let jpeg = jpeg(image) else {
                continue
            }
            stills.append(jpeg)
        }
        return stills
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// A video from the photo library, copied where the app can read it.
struct ComposerMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return ComposerMovie(url: copy)
        }
    }
}

/// Any picture from the photo library or the clipboard, as its bytes.
struct ComposerPicture: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { ComposerPicture(data: $0) }
    }
}

/// The screenshots above the field, each with a button that takes it off, and why the last one could not be added. Empty,
/// it takes no room.
struct ComposerAttachmentTray: View {
    let attachments: ComposerAttachments
    /// The attachment open full screen, from a tap on its thumbnail.
    @State private var viewing: ComposerImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if !attachments.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        ForEach(attachments.images) { image in
                            thumbnail(image)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.top, Space.sm)
                    .padding(.trailing, Space.sm)
                }
                .scrollIndicators(.hidden)
                .transition(.fold)
            }
            if let problem = attachments.problem {
                Label(problem, systemImage: AppIcon.problem.symbol)
                    .labelStyle(.iconText)
                    .font(.appFootnote)
                    .foregroundStyle(Color.toneBad)
                    .transition(.fold)
            }
        }
        .animation(AppMotion.fold, value: attachments.images.map(\.id))
        .animation(AppMotion.fold, value: attachments.problem)
        .fullScreenCoverOrSheet(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let viewing {
                ComposerImageViewer(image: viewing) { self.viewing = nil }
            }
        }
    }

    private func thumbnail(_ image: ComposerImage) -> some View {
        Image(decorative: image.preview, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: ChatStyle.attachmentSize, height: ChatStyle.attachmentSize)
            .clipShape(.rect(cornerRadius: Radius.md, style: .continuous))
            // A light screenshot on the page's grey needs its edge drawn.
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line))
            .contentShape(.rect(cornerRadius: Radius.md, style: .continuous))
            .onTapGesture { viewing = image }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "View") { viewing = image }
            .overlay(alignment: .topTrailing) {
                Button {
                    attachments.remove(image.id)
                } label: {
                    Image(AppIcon.close)
                        .font(.appCaption2.weight(.bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: ChatStyle.attachmentRemove, height: ChatStyle.attachmentRemove)
                        .background(Color.groundCard, in: .circle)
                        .overlay(Circle().strokeBorder(Color.line))
                }
                .buttonStyle(.plain)
                .offset(x: Space.xs, y: -Space.xs)
                .accessibilityLabel("Remove screenshot")
                .accessibilityIdentifier("composerAttachmentRemove")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Screenshot")
            .accessibilityIdentifier("composerAttachment")
    }
}

/// An attachment on the whole screen, as Photos shows one: fitted on black, closed by its button or a swipe down.
struct ComposerImageViewer: View {
    let image: ComposerImage
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // design-lint: allow a picture viewer's black, as Photos draws one
            Color.black.ignoresSafeArea()
            Image(decorative: image.preview, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Screenshot")
                .accessibilityIdentifier("composerAttachmentViewer")
            Button("Close", systemImage: AppIcon.close.symbol, action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(Space.lg)
                .accessibilityIdentifier("composerAttachmentViewerClose")
        }
        .gesture(DragGesture().onEnded { drag in
            if drag.translation.height > ChatStyle.viewerDismissDrag {
                close()
            }
        })
    }
}

/// The paperclip beside the field: a screenshot from Photos or from Files, and while the clipboard holds a picture,
/// that one.
struct ComposerAttachButton: View {
    let attachments: ComposerAttachments
    @State private var clipboard = ClipboardWatch()
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            if clipboard.hasPicture {
                pasteItem
            }
            Button("Photos", systemImage: AppIcon.attachPhoto.symbol) { choosingPhotos = true }
                .accessibilityIdentifier("composerAttachPhotos")
            Button("Files", systemImage: AppIcon.attachFile.symbol) { choosingFiles = true }
                .accessibilityIdentifier("composerAttachFiles")
        } label: {
            Image(AppIcon.attach)
                .font(.appBody.weight(.semibold))
                .frame(width: 22, height: 22) // design-lint: allow the send button's own glyph frame, beside it
        }
        .menuIndicator(.hidden)
        .task { await clipboard.watch() }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(attachments.isFull)
        .accessibilityLabel("Attach a screenshot or video")
        .accessibilityIdentifier("composerAttach")
        .photosPicker(
            isPresented: $choosingPhotos, selection: $photos,
            maxSelectionCount: max(1, ComposerAttachments.limit - attachments.images.count),
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photos) { _, chosen in
            guard !chosen.isEmpty else {
                return
            }
            photos = []
            Task {
                for item in chosen {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        if let movie = try? await item.loadTransferable(type: ComposerMovie.self) {
                            await attachments.add(video: movie.url)
                            try? FileManager.default.removeItem(at: movie.url)
                        } else {
                            attachments.failed("That video couldn't be loaded.")
                        }
                    } else if let picture = try? await item.loadTransferable(type: ComposerPicture.self) {
                        await attachments.add(picture.data)
                    } else {
                        attachments.failed("That photo couldn't be loaded.")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $choosingFiles, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else {
                return
            }
            Task {
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
                        await attachments.add(video: url)
                        if scoped {
                            url.stopAccessingSecurityScopedResource()
                        }
                        continue
                    }
                    let data = try? Data(contentsOf: url)
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                    if let data {
                        await attachments.add(data)
                    } else {
                        attachments.failed("That file couldn't be read.")
                    }
                }
            }
        }
    }
}

extension ComposerAttachButton {
    /// "Paste screenshot": the system's Paste control on the phone, which reads the clipboard without asking.
    private var pasteItem: some View {
        PasteButton(payloadType: ComposerPicture.self) { pictures in
            Task { @MainActor in
                for picture in pictures {
                    await attachments.add(picture.data)
                }
            }
        }
        .accessibilityIdentifier("composerAttachPaste")
    }
}

/// Whether the clipboard holds a picture, while the paperclip is on screen. Its change count is read each second:
/// another app's copy posts nothing here, and the count is cheap and never asks Jai.
@MainActor
@Observable
final class ClipboardWatch {
    private(set) var hasPicture = false
    @ObservationIgnored private var seen: Int?

    func watch() async {
        while !Task.isCancelled {
            let count = ClipboardPicture.changeCount
            if count != seen {
                seen = count
                hasPicture = ClipboardPicture.isWaiting
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// A screenshot on the clipboard: on the phone a picture, on the Mac a picture or a copied image file. Asked without
/// reading it, which on the phone would ask Jai first.
enum ClipboardPicture {
    @MainActor static var changeCount: Int {
        #if os(iOS)
        UIPasteboard.general.changeCount
        #else
        NSPasteboard.general.changeCount
        #endif
    }

    @MainActor static var isWaiting: Bool {
        #if os(iOS)
        UIPasteboard.general.hasImages
        #else
        let board = NSPasteboard.general
        return board.availableType(from: pictureTypes) != nil || imageFile(board) != nil
        #endif
    }

    #if os(macOS)
    private static let pictureTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// The picture's bytes, when Command-V should attach it rather than paste words.
    static func take() -> Data? {
        let board = NSPasteboard.general
        if let file = imageFile(board) {
            return try? Data(contentsOf: file)
        }
        guard board.string(forType: .string) == nil, let type = board.availableType(from: pictureTypes) else {
            return nil
        }
        return board.data(forType: type)
    }

    private static func imageFile(_ board: NSPasteboard) -> URL? {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }
    #endif
}

#if os(macOS)

/// Command-V in the field: the field takes only words, so a screenshot on the clipboard is caught before it and
/// attached. Words on the clipboard paste as always.
struct CommandVPictures: ViewModifier {
    let attachments: ComposerAttachments
    let isActive: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                active ? start() : stop()
            }
            .onDisappear { stop() }
    }

    private func start() {
        guard monitor == nil else {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v", let data = ClipboardPicture.take()
            else {
                return event
            }
            Task { await attachments.add(data) }
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
#endif
