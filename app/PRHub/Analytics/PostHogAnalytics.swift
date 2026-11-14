import Foundation
import PostHog

/// PRHub's events to PostHog: anonymous, with every automatic capture off. Only the events `AnalyticsEvent` names, and
/// the app's opens and closes, are sent. No person profile, no location from the IP address, no session replay,
/// no screen titles, no taps, no push token, no crash reports, no surveys and no feature flags.
@MainActor
final class PostHogAnalytics: Analytics {
    private let sdk = PostHogSDK.shared

    init(project: AnalyticsProject, isSharing: Bool) {
        let config = PostHogConfig(projectToken: project.apiKey, host: project.host.absoluteString)
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        config.disableGeoIp = true
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        #if os(iOS)
        // The phone's alone: the Mac's SDK has no taps, session replay or surveys to turn off.
        config.captureElementInteractions = false
        config.sessionReplay = false
        config.surveys = false
        #endif
        config.enableSwizzling = false
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.errorTrackingConfig.autoCapture = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.optOut = !isSharing
        sdk.setup(config)
    }

    func record(_ event: AnalyticsEvent) {
        let properties = event.properties.mapValues { value -> Any in
            switch value {
            case let .word(word): word
            case let .number(number): number
            }
        }
        if case let .screenViewed(screen) = event {
            sdk.screen(screen.rawValue)
        } else {
            sdk.capture(event.name, properties: properties)
        }
    }

    func setSharing(_ isOn: Bool) {
        if isOn {
            sdk.optIn()
        } else {
            sdk.reset()
            sdk.optOut()
        }
    }
}
