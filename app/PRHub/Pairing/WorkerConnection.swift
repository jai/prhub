import Foundation
import Observation

/// PRHub's pr-worker (docs/api.md, "Pairing"): whether it has one, what that Worker serves, and the pairing in between.
@MainActor
@Observable
final class WorkerConnection {
    enum Phase: Equatable {
        case idle
        case working(DevicePairing.Step)
        case invalidLink(SetupLink.Failure)
        case failed(PairingError)
    }

    /// The paired Worker's host; `nil` until a setup link has paired it.
    private(set) var host: String?
    /// The last `GET /device/config` read, kept across launches.
    private(set) var config: DeviceConfig?
    private(set) var phase: Phase = .idle
    /// A setup link opened while a Worker is paired already: its host, for the alert that says so.
    var ignoredLinkHost: String?

    @ObservationIgnored private let endpoint: WorkerEndpoint
    @ObservationIgnored private let pairing: DevicePairing
    @ObservationIgnored private let fetchConfig: @Sendable () async throws -> DeviceConfig
    @ObservationIgnored private let forgetSecret: @Sendable () throws -> Void
    /// `DELETE /device/pair` with this phone's secret, before Disconnect forgets it. Failures are the Worker's to
    /// outlive: its record goes when another device pairs.
    @ObservationIgnored private let unpair: (@Sendable () async -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    static let configKey = "deviceConfig"

    init(
        endpoint: WorkerEndpoint, pairing: DevicePairing,
        fetchConfig: @escaping @Sendable () async throws -> DeviceConfig,
        forgetSecret: @escaping @Sendable () throws -> Void, unpair: (@Sendable () async -> Void)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.endpoint = endpoint
        self.pairing = pairing
        self.fetchConfig = fetchConfig
        self.forgetSecret = forgetSecret
        self.unpair = unpair
        self.defaults = defaults
        host = endpoint.url?.host()
        config = defaults.data(forKey: Self.configKey).flatMap {
            try? JSONDecoder().decode(DeviceConfig.self, from: $0)
        }
    }

    /// Once a setup link has paired it.
    var isPaired: Bool {
        host != nil
    }

    var showsOnboarding: Bool {
        host == nil
    }

    var isWorking: Bool {
        if case .working = phase {
            return true
        }
        return false
    }

    /// The Keychain may not have been readable at launch (a wake before the first unlock): read it again.
    func reload() {
        host = endpoint.url?.host()
    }

    /// A scanned, pasted or typed link.
    func connect(text: String) async {
        do {
            try await connect(SetupLink.parse(text))
        } catch {
            phase = .invalidLink(error)
        }
    }

    /// A Worker address and a code typed in apart.
    func connect(worker: String, code: String) async {
        do {
            try await connect(SetupLink(worker: worker, code: code))
        } catch {
            phase = .invalidLink(error)
        }
    }

    /// `prhub://setup?…`, opened from anywhere.
    func open(_ url: URL) {
        guard let link = try? SetupLink.parse(url.absoluteString) else {
            return
        }
        guard showsOnboarding else {
            ignoredLinkHost = host
            return
        }
        guard !isWorking else {
            return
        }
        Task { await connect(link) }
    }

    func connect(_ link: SetupLink) async {
        guard !isWorking else {
            return
        }
        phase = .working(.pairing)
        do {
            try await pairing.run(link)
            // The first config is read before the tabs appear, so they appear as the Worker serves them.
            await readConfig()
            host = link.worker.host()
            phase = .idle
        } catch {
            phase = .failed(error)
        }
    }

    /// `GET /device/config`, at launch, at every foreground and after pairing. A failed read keeps the last one.
    func refreshConfig() async {
        guard host != nil else {
            return
        }
        await readConfig()
    }

    private func readConfig() async {
        guard let fresh = try? await fetchConfig() else {
            return
        }
        config = fresh
        defaults.set(try? JSONEncoder().encode(fresh), forKey: Self.configKey)
    }

    /// Settings' Disconnect: tells the Worker to forget this phone's secret where it can, then forgets the Worker, its
    /// config and the secret here, so the next pairing is a new device.
    func disconnect() async {
        if host != nil {
            await unpair?()
        }
        do {
            try endpoint.clear()
            try forgetSecret()
        } catch {
            phase = .failed(.keychain)
            return
        }
        defaults.removeObject(forKey: Self.configKey)
        config = nil
        host = nil
        phase = .idle
    }
}
