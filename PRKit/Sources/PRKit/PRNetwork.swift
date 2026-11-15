import DurableNetworking
import Observation
import PRKitDesign
import SwiftUI

/// Whether the device has a network now, from the system's path (DurableNetworking's `PathWatcher`). The PR screens
/// read it to say less about a failed read while offline; the host shows `prKitOfflineBanner` over the whole app.
@MainActor
@Observable
public final class PRNetwork {
    public private(set) var isOnline: Bool
    @ObservationIgnored private var watcher: PathWatcher?
    @ObservationIgnored private var isHeld = false

    init(isOnline: Bool = NetworkStatus.shared.isOnline) {
        self.isOnline = isOnline
    }

    /// Follows the system's path from now on. Not in `init`, so a test's network stays where the test puts it.
    func watch() {
        guard watcher == nil, !isHeld else {
            return
        }
        watcher = PathWatcher(
            satisfied: { [weak self] isUp in Task { @MainActor in self?.update(isUp) } },
            returned: {}
        )
    }

    /// Offline from now on, whatever the system says: a Debug run's UI test of the offline screens.
    public func holdOffline() {
        isHeld = true
        watcher = nil
        isOnline = false
    }

    func update(_ isUp: Bool) {
        guard !isHeld else {
            return
        }
        isOnline = isUp
    }
}

extension View {
    /// One quiet line at the top while the device is offline: what is on screen is what was saved.
    public func prKitOfflineBanner(_ controller: PRKitController) -> some View {
        modifier(PROfflineBanner(network: controller.network))
    }
}

struct PROfflineBanner: ViewModifier {
    let network: PRNetwork

    func body(content: Content) -> some View {
        // A bar, not an inset: what scrolls under it fades by the system's edge effect, and nothing opaque sits over
        // a toolbar's glass buttons.
        content.safeAreaBar(edge: .top, spacing: 0) {
            if !network.isOnline {
                Label("Offline — showing saved information", systemImage: AppIcon.offline.symbol)
                    .font(.appCaption)
                    .foregroundStyle(Color.toneWaiting)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.xs)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("prkit-offline-banner")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(AppMotion.fold, value: network.isOnline)
    }
}
