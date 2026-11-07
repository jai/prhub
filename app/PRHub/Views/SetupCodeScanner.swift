#if os(iOS)
import AVFoundation
import SwiftUI
import VisionKit

/// The camera, reading the setup link's QR code (docs/api.md, "Pairing") with VisionKit's data scanner: the first QR
/// code that carries text is handed over once, and the scanner stops. The camera's purpose string is in project.yml.
struct SetupCodeScanner: UIViewControllerRepresentable {
    let found: @MainActor (String) -> Void

    enum Availability {
        case available
        /// No camera, or one VisionKit cannot use: the Simulator, an old phone.
        case unsupported
        case denied
    }

    /// Asks for the camera when nobody has answered yet.
    @MainActor static func availability() async -> Availability {
        guard DataScannerViewController.isSupported else {
            return .unsupported
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                return .denied
            }
        default:
            return .denied
        }
        return DataScannerViewController.isAvailable ? .available : .denied
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(found: found)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: @MainActor (String) -> Void
        private var handedOver = false

        init(found: @escaping @MainActor (String) -> Void) {
            self.found = found
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
        ) {
            guard !handedOver else {
                return
            }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    handedOver = true
                    dataScanner.stopScanning()
                    found(payload)
                    return
                }
            }
        }
    }
}
#endif
