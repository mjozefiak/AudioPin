import Foundation
import Testing
@testable import AudioPin

@Suite("AppRule settings")
struct AppRuleTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func version12SettingsDecodeWithDefaults() throws {
        let settings = try decode("""
        {"isActive": true, "outputPriority": [{"uid": "spk", "name": "Speakers", "transport": 0,
          "isEnabled": true, "lastSeen": 0}], "didRunOnboarding": true}
        """)
        #expect(settings.outputPriority.map(\.uid) == ["spk"])
        #expect(settings.appRules == [])
        #expect(settings.showAppsInMenu == true)
    }

    @Test func ruleRoundTrips() throws {
        var settings = AppSettings()
        settings.showAppsInMenu = false
        settings.appRules = [
            AppRule(bundleID: "com.spotify.client", appName: "Spotify", deviceUID: "airpods",
                    deviceName: "AirPods Max", volume: 0.6, isMuted: true, isEnabled: false),
        ]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func ruleWithOnlyABundleIDDecodesWithDefaults() throws {
        let settings = try decode(#"{"appRules": [{"bundleID": "com.apple.Music", "isMuted": true}]}"#)
        let rule = try #require(settings.appRules.first)
        #expect(rule.appName == "com.apple.Music")
        #expect(rule.deviceUID == nil)
        #expect(rule.volume == 1)
        #expect(rule.isMuted)
        #expect(rule.isEnabled)
    }

    @Test func malformedRulesAreDroppedButSettingsSurvive() throws {
        let settings = try decode("""
        {"inputPriority": [{"uid": "mic", "name": "Mic", "transport": 0, "isEnabled": true, "lastSeen": 0}],
         "appRules": [{"bundleID": "bad id/../x", "isMuted": true}, {"appName": "No ID"},
                      {"bundleID": "com.spotify.client", "volume": "loud"},
                      {"bundleID": "com.apple.Music", "volume": 0.5}]}
        """)
        #expect(settings.inputPriority.map(\.uid) == ["mic"])
        #expect(settings.appRules.map(\.bundleID) == ["com.apple.Music"])
    }

    @Test func ruleListOfTheWrongTypeKeepsTheRestOfTheSettings() throws {
        let settings = try decode(#"{"isActive": false, "appRules": "oops"}"#)
        #expect(settings.isActive == false)
        #expect(settings.appRules == [])
    }

    @Test func decodingDropsNeutralAndDuplicateRules() throws {
        let settings = try decode("""
        {"appRules": [{"bundleID": "com.apple.Music"},
                      {"bundleID": "com.spotify.client", "volume": 0.5},
                      {"bundleID": "com.spotify.client", "volume": 0.2}]}
        """)
        #expect(settings.appRules.map(\.bundleID) == ["com.spotify.client"])
        #expect(settings.appRules.first?.volume == 0.5)
    }

    @Test func decodingClampsVolumeAndSanitizesNames() throws {
        let settings = try decode("""
        {"appRules": [{"bundleID": "com.spotify.client", "appName": "Spo\\u202Etify\\n", "volume": 7,
                       "isMuted": true, "deviceUID": ""}]}
        """)
        let rule = try #require(settings.appRules.first)
        #expect(rule.volume == 1)
        #expect(rule.appName == "Spotify")
        #expect(rule.deviceUID == nil)
    }

    @Test(arguments: [
        ("com.spotify.client", true), ("com.google.Chrome.helper", true), ("org.mozilla.firefox-esr", true),
        ("", false), ("com spotify", false), ("com/spotify", false), ("com.spötify", false),
        (String(repeating: "a", count: 256), false),
    ])
    func validatesBundleIDs(bundleID: String, valid: Bool) {
        #expect(AppRule.isValidBundleID(bundleID) == valid)
    }

    @Test func neutralMeansPlainMacOSBehavior() {
        let neutral = AppRule(bundleID: "com.apple.Music", appName: "Music")
        #expect(neutral.isNeutral)
        var rule = neutral
        rule.volume = 0.99
        #expect(!rule.isNeutral)
        rule = neutral
        rule.isMuted = true
        #expect(!rule.isNeutral)
        rule = neutral
        rule.deviceUID = "airpods"
        #expect(!rule.isNeutral)
    }
}
