import Foundation

/// Which APNs host the Worker must use for this install (`apns_env` of `POST /device/register`, docs/api.md). A
/// device token belongs to one APNs environment, and a push sent to the other host fails with `BadDeviceToken`:
///
/// 1. **The Simulator is `sandbox`**, whatever its bundle holds.
/// 2. **A real device whose embedded provisioning profile says `aps-environment` = `development` is `sandbox`** —
///    an Xcode install.
/// 3. **Every other real device is `production`.** A TestFlight or App Store install carries **no**
///    `embedded.mobileprovision` at all — Apple signs the app again and leaves the profile out — and its tokens are
///    production tokens; an ad hoc build carries a profile that says `production`. A profile that cannot be read, or
///    whose entitlement is missing or says anything else, is production too: the only builds that reach a real device
///    without a development profile are distribution builds, so `sandbox` has to be proved and `production` is what
///    is left.
enum APNSEnvironment {
    static let sandbox = "sandbox"
    static let production = "production"

    /// Compiled in: a Simulator build and a device build are different binaries.
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static func current(bundle: Bundle = .main) -> String {
        let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return resolve(isSimulator: isSimulator, profileData: profile)
    }

    /// The rule itself, over everything it depends on: where the app runs, and the bytes of its embedded profile
    /// (`nil`: there is none, or it could not be read).
    static func resolve(isSimulator: Bool, profileData: Data?) -> String {
        if isSimulator {
            return sandbox
        }
        return apsEnvironment(inProfile: profileData) == "development" ? sandbox : production
    }

    /// The profile's `aps-environment` entitlement, as written. `embedded.mobileprovision` is a CMS (DER) envelope
    /// around an XML plist; the plist is sliced out between its `<?xml` and `</plist>` markers and read with
    /// PropertyListSerialization, because `CMSDecoder` is macOS-only.
    static func apsEnvironment(inProfile profileData: Data?) -> String? {
        guard let data = profileData,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], options: [], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else {
            return nil
        }
        return entitlements["aps-environment"] as? String
    }

    /// Lowercase hex, the form `/device/register` expects for `apns_token`.
    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
