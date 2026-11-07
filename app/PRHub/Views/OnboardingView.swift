import SwiftUI

/// PRHub's first screen, while it has no pr-worker (docs/api.md, "Pairing"): scan the QR code the Worker's
/// `npm run pair` printed, paste its setup link, or type the address and code apart. Opening the link itself lands
/// here too (`PRHubRootView`). Everything happens in place: the camera opens in its block, the status arrives under
/// the blocks, and a failure says what to do next. With `trySamples`, a last block offers the app on sample PRs, for
/// anyone with no pr-worker yet.
struct OnboardingView: View {
    let connection: WorkerConnection
    /// PRHub's "Try with sample PRs" (`PRHubSamples.swift`).
    var trySamples: (() -> Void)?
    @State private var link = ""
    @State private var worker = ""
    @State private var code = ""
    @State private var opened = FoldSet()
    @State private var scanner = ScannerState.closed

    enum ScannerState: Equatable {
        case closed
        case open
        case unavailable(String)
    }

    private static let manualFold = "manual"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                scanBlock
                pasteBlock
                manualBlock
                if connection.phase != .idle {
                    statusBlock
                        .transition(.fold)
                }
                if let trySamples {
                    samplesBlock(trySamples)
                }
            }
            .padding(.vertical, 24)
            .animation(AppMotion.fold, value: connection.phase)
            .animation(AppMotion.fold, value: scanner)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(HomePalette.screenBackground)
        .readableContentWidth()
        .disabled(connection.isWorking)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect PRHub to your pr-worker")
                .font(.appTitle3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("When your agent set up your pr-worker from github.com/jai/prhub, it printed a setup link and a QR "
                 + "code. Scan the code or paste the link to connect this phone. For a new one, run npm run pair "
                 + "there again.")
                .font(.appFootnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Scan

    @ViewBuilder private var scanBlock: some View {
        block("Scan the QR code") {
            switch scanner {
            case .closed:
                Button("Scan QR code", systemImage: "qrcode.viewfinder") { openScanner() }
                    .buttonStyle(PRButtonStyle(.primary))
                    .accessibilityIdentifier("onboardingScan")
            case .open:
                #if os(iOS)
                SetupCodeScanner { payload in
                    scanner = .closed
                    link = payload
                    Task { await connection.connect(text: payload) }
                }
                .frame(height: 280)
                .clipShape(.rect(cornerRadius: 6))
                .transition(.fold)
                #endif
                Button("Cancel") { scanner = .closed }
                    .buttonStyle(PRButtonStyle(.secondary))
            case .unavailable(let reason):
                Text(reason)
                    .font(.appFootnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboardingScanUnavailable")
                Button("Try scanning again") { openScanner() }
                    .buttonStyle(PRButtonStyle(.secondary))
            }
        }
    }

    private func openScanner() {
        #if os(iOS)
        Task {
            switch await SetupCodeScanner.availability() {
            case .available: scanner = .open
            case .unsupported: scanner = .unavailable("This device can't scan codes. Paste the link instead.")
            case .denied:
                scanner = .unavailable("Camera access is off for PRHub. Turn it on in Settings, or paste the "
                                       + "link instead.")
            }
        }
        #else
        scanner = .unavailable("This Mac can't scan codes. Paste the link instead.")
        #endif
    }

    // MARK: - Paste

    private var pasteBlock: some View {
        block("Or paste the setup link") {
            TextField("prhub://setup?worker=…&code=…", text: $link, axis: .vertical)
                .font(.appFootnote.monospaced())
                .lineLimit(1...4)
                .plainEntry()
                .accessibilityIdentifier("onboardingLinkField")
            HStack(spacing: 8) {
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first else {
                        return
                    }
                    Task { @MainActor in link = pasted }
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                Button("Connect") { Task { await connection.connect(text: link) } }
                    .buttonStyle(PRButtonStyle(.primary))
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("onboardingConnect")
            }
        }
    }

    // MARK: - Address and code

    private var manualBlock: some View {
        block(nil) {
            Button {
                opened.toggle(Self.manualFold)
            } label: {
                HStack {
                    Text("Enter the address and code instead")
                        .font(.appFootnote.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(opened.isFlipped(Self.manualFold) ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboardingManual")
            if opened.isFlipped(Self.manualFold) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("pr-review.example.workers.dev", text: $worker)
                        .font(.appFootnote.monospaced())
                        .plainEntry(isURL: true)
                        .accessibilityIdentifier("onboardingWorkerField")
                    TextField("Code, like 7KQ2-M9XA", text: $code)
                        .font(.appFootnote.monospaced())
                        .plainEntry(isCode: true)
                        .accessibilityIdentifier("onboardingCodeField")
                    Button("Connect") { Task { await connection.connect(worker: worker, code: code) } }
                        .buttonStyle(PRButtonStyle(.primary))
                        .disabled(worker.isEmpty || code.isEmpty)
                        .accessibilityIdentifier("onboardingManualConnect")
                }
                .transition(.fold)
            }
        }
    }

    // MARK: - Samples

    private func samplesBlock(_ trySamples: @escaping () -> Void) -> some View {
        block("No pr-worker yet?") {
            Text("Look around PRHub with sample PRs in made-up repos. Nothing reaches GitHub.")
                .font(.appFootnote)
                .foregroundStyle(.secondary)
            Button("Try with sample PRs", systemImage: "sparkles.rectangle.stack") { trySamples() }
                .buttonStyle(PRButtonStyle(.secondary))
                .accessibilityIdentifier("onboardingTrySamples")
        }
    }

    // MARK: - Status

    @ViewBuilder private var statusBlock: some View {
        block(nil) {
            switch connection.phase {
            case .idle:
                EmptyView()
            case .working(let step):
                HStack(spacing: 12) {
                    ProgressView()
                    Text(Self.words(for: step))
                        .font(.appFootnote)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboardingStatus")
            case .invalidLink(let failure):
                failureLabel(failure.message)
            case .failed(let error):
                failureLabel(error.message)
            }
        }
    }

    private func failureLabel(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.appFootnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color("ToneBad"))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboardingStatus")
    }

    static func words(for step: DevicePairing.Step) -> String {
        switch step {
        case .pairing:
            "Pairing with your pr-worker…"
        }
    }

    /// A block on the page's grey, the width of the screen, with its section's title above it.
    private func block(_ title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.appFootnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(HomePalette.cardBackground)
        }
        .padding(.top, title == nil ? 0 : 16)
    }
}

private extension View {
    /// A field for a link, an address or a code: no capitals, no corrections, the keyboard that suits it.
    func plainEntry(isURL: Bool = false, isCode: Bool = false) -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(isCode ? .characters : .never)
            .autocorrectionDisabled()
            .keyboardType(isURL ? .URL : .asciiCapable)
            .textFieldStyle(.roundedBorder)
        #else
        self
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
        #endif
    }
}
