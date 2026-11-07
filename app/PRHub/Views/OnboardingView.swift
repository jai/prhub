import SwiftUI

/// PRHub's first screen, while it has no Worker. The build decides which ways in it offers (`PRHubBuild`):
/// - Sign in with GitHub, on the hosted Worker (docs/api.md, "Hosted sign-in").
/// - Connect your own Worker (docs/api.md, "Pairing"): scan the QR code the Worker's `npm run pair` printed, paste its
///   setup link, or type the address and code apart. Opening the link itself lands here too (`PRHubRootView`). Beside
///   Sign in with GitHub it folds under one row.
/// - With `trySamples`, a last block offers the app on sample PRs, for anyone just looking, App Review included.
///
/// Everything happens in place: the camera opens in its block, a status arrives under the button it is about, and a
/// failure says what to do next.
struct OnboardingView: View {
    let connection: WorkerConnection
    /// Sign in with GitHub (`PRHubEnvironment.signIn`).
    var signIn: () -> Void = {}
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
    private static let ownWorkerFold = "own-worker"

    private var build: PRHubBuild { connection.build }

    /// Sign-in's own status goes under its button; pairing's under the Worker's blocks.
    private var isSignInStatus: Bool {
        switch connection.phase {
        case .working(.signingIn), .signInFailed: true
        default: false
        }
    }

    private var showsStatus: Bool {
        if case .signInFailed(.cancelled) = connection.phase {
            return false
        }
        return connection.phase != .idle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                if build.signInWithGitHub {
                    signInBlock
                    if showsStatus, isSignInStatus {
                        statusBlock
                            .transition(.fold)
                    }
                }
                if build.selfHosted {
                    if build.signInWithGitHub {
                        ownWorkerRow
                    }
                    if !build.signInWithGitHub || opened.isFlipped(Self.ownWorkerFold) {
                        Group {
                            scanBlock
                            pasteBlock
                            manualBlock
                        }
                        .transition(.fold)
                    }
                }
                if showsStatus, !isSignInStatus {
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
            Text(build.signInWithGitHub ? "Review pull requests on your phone" : "Connect PRHub to your pr-worker")
                .font(.appTitle3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(build.signInWithGitHub
                 ? "PRHub lists the PRs waiting on you, and lets you read the diff, comment, approve and merge."
                 : "When your agent set up your pr-worker from github.com/jai/prhub, it printed a setup link and a "
                    + "QR code. Scan the code or paste the link to connect this phone. For a new one, run npm run "
                    + "pair there again.")
                .font(.appFootnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Sign in with GitHub

    private var signInBlock: some View {
        block(nil) {
            SignInWithGitHubButton(isWorking: connection.phase == .working(.signingIn), action: signIn)
            Text("PRHub reads your PRs through the PRHub GitHub App, with your own GitHub access. Each org needs the "
                 + "App installed once, by an owner.")
                .font(.appFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Your own Worker

    private var ownWorkerRow: some View {
        block(nil) {
            FoldRow(
                title: "Connect your own Worker", isOpen: opened.isFlipped(Self.ownWorkerFold),
                identifier: "onboardingOwnWorker"
            ) {
                opened.toggle(Self.ownWorkerFold)
            }
        }
        .padding(.top, 16)
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
            FoldRow(
                title: "Enter the address and code instead", isOpen: opened.isFlipped(Self.manualFold),
                identifier: "onboardingManual"
            ) {
                opened.toggle(Self.manualFold)
            }
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
        block(build.signInWithGitHub ? "Just looking?" : "No pr-worker yet?") {
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
            case .signInFailed(let error):
                failureLabel(error.message ?? "")
            case .selfHostedOff:
                failureLabel("This build of PRHub doesn't connect to self-hosted Workers. Sign in with GitHub "
                             + "instead.")
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
        case .signingIn:
            "Signing in with GitHub…"
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

/// A row that folds what is under it in and out, its chevron turning: "Connect your own Worker", "Enter the address and
/// code instead".
private struct FoldRow: View {
    let title: String
    let isOpen: Bool
    let identifier: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                Text(title)
                    .font(.appFootnote.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(isOpen ? "Open" : "Closed")
    }
}

/// Sign in with GitHub: the screen's one primary action, the width of its block, with the work in place of its words
/// while the sheet and the first config run.
struct SignInWithGitHubButton: View {
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Label("Sign in with GitHub", systemImage: "person.crop.circle")
                    .labelStyle(.iconText)
                    .opacity(isWorking ? 0 : 1)
                if isWorking {
                    ProgressView()
                        .tint(.white)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xs)
        }
        .buttonStyle(PRButtonStyle(.primary))
        .disabled(isWorking)
        .animation(AppMotion.swap, value: isWorking)
        .accessibilityIdentifier("onboardingSignIn")
        .accessibilityLabel(isWorking ? "Signing in with GitHub" : "Sign in with GitHub")
    }
}
