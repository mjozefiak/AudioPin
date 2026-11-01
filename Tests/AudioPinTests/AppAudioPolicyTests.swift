import Testing
@testable import AudioPin

@Suite("AppAudioPolicy")
struct AppAudioPolicyTests {
    private static let speakers = Sample.speakers.uid
    private static let airPods = Sample.airPodsOut.uid

    private func rule(
        _ bundleID: String, device: String? = nil, volume: Float = 1, muted: Bool = false, enabled: Bool = true
    ) -> AppRule {
        AppRule(bundleID: bundleID, appName: bundleID, deviceUID: device, volume: volume, isMuted: muted,
                isEnabled: enabled)
    }

    private func process(_ bundleID: String, playing: Bool = true) -> AudioProcess {
        AudioProcess(bundleID: bundleID, pid: 100, isRunningOutput: playing)
    }

    private func routes(
        _ rules: [AppRule],
        _ processes: [AudioProcess],
        recent: Set<String> = [],
        connected: [AudioDevice] = [Sample.speakers, Sample.airPodsOut],
        defaultOutput: String? = speakers
    ) -> [WarmRoute] {
        AppAudioPolicy.warmRoutes(rules: rules, processes: processes, recentBundleIDs: recent,
                                  connectedOutputs: connected, defaultOutputUID: defaultOutput)
    }

    // MARK: Which rules get a route

    @Test func disabledRuleGetsNoRoute() {
        #expect(routes([rule("com.spotify.client", device: Self.airPods, enabled: false)],
                       [process("com.spotify.client")]).isEmpty)
    }

    @Test func notRunningAppGetsNoRoute() {
        #expect(routes([rule("com.spotify.client", device: Self.airPods)], [process("com.apple.Music")]).isEmpty)
    }

    @Test func appThatQuitEarlierKeepsItsRoute() throws {
        let route = try #require(routes([rule("com.spotify.client", device: Self.airPods)], [],
                                        recent: ["com.spotify.client"]).first)
        #expect(route.appRunning == false)
        #expect(route.mode == .routing)
        #expect(route.bundleIDs == ["com.spotify.client"])
    }

    @Test func runningAppIsMarkedRunningEvenWhenSilent() throws {
        let route = try #require(routes([rule("com.spotify.client", volume: 0.5)],
                                        [process("com.spotify.client", playing: false)]).first)
        #expect(route.appRunning)
    }

    @Test func noDefaultOutputMeansNoRoutes() {
        #expect(routes([rule("com.spotify.client", device: Self.airPods)], [process("com.spotify.client")],
                       defaultOutput: nil).isEmpty)
    }

    @Test(arguments: ["", "com.apple.WebKit.GPU", "com.apple.WebKit"])
    func unsupportedProcessesAreNeverTapped(bundleID: String) {
        #expect(AppAudioPolicy.owner(of: bundleID, rules: [rule(bundleID, volume: 0.5)]) == nil)
        #expect(routes([rule(bundleID, volume: 0.5)], [process(bundleID)]).isEmpty)
    }

    // MARK: Mode and target

    struct ModeCase: Sendable, CustomTestStringConvertible {
        let name: String
        let device: String?
        let volume: Float
        let muted: Bool
        let mode: RouteMode
        let target: String
        let gain: Float
        var testDescription: String { name }
    }

    @Test(arguments: [
        ModeCase(name: "pinned to another device", device: airPods, volume: 1, muted: false,
                 mode: .routing, target: airPods, gain: 1),
        ModeCase(name: "pinned to the default at full volume", device: speakers, volume: 1, muted: false,
                 mode: .passthrough, target: speakers, gain: 1),
        ModeCase(name: "volume only", device: nil, volume: 0.5, muted: false,
                 mode: .routing, target: speakers, gain: 0.25),
        ModeCase(name: "muted only", device: nil, volume: 1, muted: true,
                 mode: .routing, target: speakers, gain: 0),
        ModeCase(name: "disconnected pin falls back to default", device: "gone-usb", volume: 1, muted: false,
                 mode: .passthrough, target: speakers, gain: 1),
        ModeCase(name: "disconnected pin keeps volume", device: "gone-usb", volume: 0.5, muted: false,
                 mode: .routing, target: speakers, gain: 0.25),
    ])
    func modeAndTarget(_ c: ModeCase) throws {
        let route = try #require(routes([rule("com.spotify.client", device: c.device, volume: c.volume, muted: c.muted)],
                                        [process("com.spotify.client")]).first)
        #expect(route.mode == c.mode)
        #expect(route.deviceUID == c.target)
        #expect(route.gain == c.gain)
    }

    @Test func followDefaultRuleTargetsTheCurrentDefault() throws {
        let route = try #require(routes([rule("com.spotify.client", volume: 0.5)], [process("com.spotify.client")],
                                        defaultOutput: Self.airPods).first)
        #expect(route.deviceUID == Self.airPods)
        #expect(route.mode == .routing)
    }

    @Test func neutralRuleGetsNoRoute() {
        #expect(routes([rule("com.spotify.client")], [process("com.spotify.client")]).isEmpty)
    }

    // MARK: Helper processes

    @Test func helpersJoinTheirAppsRoute() throws {
        let route = try #require(routes(
            [rule("com.google.Chrome", device: Self.airPods)],
            [process("com.google.Chrome.helper.Renderer"), process("com.google.Chrome.helper"),
             process("com.google.Chrome")]).first)
        #expect(route.bundleIDs == ["com.google.Chrome", "com.google.Chrome.helper",
                                    "com.google.Chrome.helper.Renderer"])
    }

    @Test func helperAloneKeepsTheAppRouted() throws {
        let route = try #require(routes([rule("com.hnc.Discord", volume: 0.5)], [process("com.hnc.Discord.helper")]).first)
        #expect(route.appRunning)
        #expect(route.bundleIDs == ["com.hnc.Discord", "com.hnc.Discord.helper"])
    }

    @Test func prefixMatchNeedsADotBoundary() {
        #expect(AppAudioPolicy.owner(of: "com.google.ChromeCanary", rules: [rule("com.google.Chrome", volume: 0.5)]) == nil)
    }

    @Test func exactMatchBeatsPrefixAndLongestPrefixWins() {
        let rules = [rule("com.google.Chrome", volume: 0.5), rule("com.google.Chrome.helper", volume: 0.2),
                     rule("com.google.Chrome.helper.Renderer", muted: true)]
        #expect(AppAudioPolicy.owner(of: "com.google.Chrome.helper", rules: rules)?.bundleID == "com.google.Chrome.helper")
        #expect(AppAudioPolicy.owner(of: "com.google.Chrome.helper.GPU", rules: rules)?.bundleID == "com.google.Chrome.helper")
        #expect(AppAudioPolicy.owner(of: "com.google.Chrome.helper.Renderer", rules: rules)?.bundleID
            == "com.google.Chrome.helper.Renderer")
    }

    @Test func eachProcessBelongsToOneRouteOnly() {
        let result = routes(
            [rule("com.google.Chrome", volume: 0.5), rule("com.google.Chrome.helper", muted: true)],
            [process("com.google.Chrome"), process("com.google.Chrome.helper"), process("com.google.Chrome.helper.GPU")])
        let all = result.flatMap(\.bundleIDs)
        #expect(all.count == Set(all).count)
        #expect(result.first { $0.ruleID == "com.google.Chrome" }?.bundleIDs == ["com.google.Chrome"])
    }

    @Test func sharedGenericHelperMatchesOnlyAnExactRule() {
        let rules = [rule("com.hnc.Discord", volume: 0.5), rule("com.tinyspeck.slackmacgap", muted: true)]
        #expect(AppAudioPolicy.owner(of: "com.github.Electron.helper", rules: rules) == nil)
        let exact = rules + [rule("com.github.Electron.helper", volume: 0.3)]
        #expect(AppAudioPolicy.owner(of: "com.github.Electron.helper", rules: exact)?.bundleID == "com.github.Electron.helper")
    }

    @Test func disabledRuleDoesNotClaimProcesses() {
        let rules = [rule("com.google.Chrome", volume: 0.5), rule("com.google.Chrome.helper", muted: true, enabled: false)]
        #expect(AppAudioPolicy.owner(of: "com.google.Chrome.helper", rules: rules)?.bundleID == "com.google.Chrome")
    }

    // MARK: Gain curve

    @Test(arguments: [
        (Float(0), false, Float(0)), (1, false, 1), (0.5, false, 0.25), (1, true, 0), (0.5, true, 0),
        (-1, false, 0), (2, false, 1), (.nan, false, 1),
    ])
    func gainCurve(volume: Float, muted: Bool, expected: Float) {
        #expect(AppAudioPolicy.gain(forVolume: volume, muted: muted) == expected)
    }

    @Test func recentButDisabledRuleGetsNoRoute() {
        #expect(routes([rule("com.spotify.client", device: Self.airPods, enabled: false)], [],
                       recent: ["com.spotify.client"]).isEmpty)
    }

    @Test func quitAppWithPassthroughRuleKeepsAPassthroughRoute() throws {
        let route = try #require(routes([rule("com.spotify.client", device: Self.speakers)], [],
                                        recent: ["com.spotify.client"]).first)
        #expect(route.mode == .passthrough)
        #expect(route.appRunning == false)
    }

    @Test func duplicateRulesInMemoryYieldOneRoute() {
        let result = routes([rule("com.spotify.client", volume: 0.5), rule("com.spotify.client", muted: true)],
                            [process("com.spotify.client")])
        #expect(result.map(\.ruleID) == ["com.spotify.client"])
        #expect(result.first?.gain == 0.25)
    }

    @Test func neutralRuleDoesNotClaimHelpers() {
        let rules = [rule("com.google.Chrome", volume: 0.5), rule("com.google.Chrome.helper")]
        #expect(AppAudioPolicy.owner(of: "com.google.Chrome.helper", rules: rules)?.bundleID == "com.google.Chrome")
    }
}
