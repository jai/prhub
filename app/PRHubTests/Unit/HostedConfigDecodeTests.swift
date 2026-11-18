import Foundation
@testable import PRHubCore
import Testing

struct HostedConfigDecodeTests {
    @Test func readsTheHostedWorkersAccount() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data("""
        {"features":{"key_lines":true,"rewrite":true,"push":true},"login":"octocat","hosted":true,
         "account":{"state":"signed_in","login":"octocat","user_id":"4242","anthropic_key":true}}
        """.utf8))
        #expect(config.hosted)
        #expect(config.account == DeviceConfig.Account(
            state: .signedIn, login: "octocat", userId: "4242", anthropicKey: true
        ))
        #expect(try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func linearConnectionDecodesAndOlderWorkersDefaultToDisconnected() throws {
        let body = #"{"features":{},"hosted":true,"account":{"state":"signed_in","linear_key":true}}"#
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(body.utf8))
        #expect(config.account?.linearKey == true)
        #expect(try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(config)) == config)
        let old = #"{"features":{},"hosted":true,"account":{"state":"signed_in"}}"#
        #expect(try JSONDecoder().decode(DeviceConfig.self, from: Data(old.utf8)).account?.linearKey == false)
    }

    @Test func onlyASignedInHostedAccountWithoutLinearIsOfferedTheConnection() throws {
        func config(_ body: String) throws -> DeviceConfig {
            try JSONDecoder().decode(DeviceConfig.self, from: Data(body.utf8))
        }
        #expect(try config(#"{"features":{},"hosted":true,"account":{"state":"signed_in"}}"#).offersLinearConnection)
        let connected = #"{"features":{},"hosted":true,"account":{"state":"signed_in","linear_key":true}}"#
        #expect(try !config(connected).offersLinearConnection)
        let signedOut = #"{"features":{},"hosted":true,"account":{"state":"signed_out","reason":"revoked"}}"#
        #expect(try !config(signedOut).offersLinearConnection, "Sign in again comes first")
        #expect(try !config(#"{"features":{},"login":"octocat"}"#).offersLinearConnection, "self-hosted: the operator's key")
    }

    @Test func aLinearKeyThatCanOnlyReadSaysSoAndAnOlderWorkerSaysNothing() throws {
        let readOnly = #"{"features":{},"hosted":true,"account":{"state":"signed_in","linear_key":true,"linear_can_comment":false}}"#
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(readOnly.utf8))
        #expect(config.account?.linearCanComment == false)
        #expect(try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(config)) == config)
        let old = #"{"features":{},"hosted":true,"account":{"state":"signed_in","linear_key":true}}"#
        #expect(try JSONDecoder().decode(DeviceConfig.self, from: Data(old.utf8)).account?.linearCanComment == nil)
    }

    @Test func aSignedOutOrUnknownStateReadsAsSignedOut() throws {
        let signedOut = try JSONDecoder().decode(DeviceConfig.self, from: Data(#"""
        {"features":{},"hosted":true,"account":{"state":"signed_out","reason":"revoked","anthropic_key":false}}
        """#.utf8))
        #expect(signedOut.account?.state == .signedOut && signedOut.account?.reason == "revoked")
        let unknown = try JSONDecoder().decode(DeviceConfig.self, from: Data(#"""
        {"features":{},"hosted":true,"account":{"state":"paused"}}
        """#.utf8))
        #expect(unknown.account?.state == .signedOut)
    }

    @Test func aSelfHostedConfigIsNotHosted() throws {
        let config = try JSONDecoder().decode(DeviceConfig.self, from: Data(#"{"features":{"push":true}}"#.utf8))
        #expect(!config.hosted && config.account == nil)
    }

    @Test func theSignedOutPushIsKnown() {
        #expect(PRHubNotificationDelegate.isSignedOut(["reason": "signed_out"]))
        #expect(!PRHubNotificationDelegate.isSignedOut(["reason": "pr_sync"]))
    }
}
