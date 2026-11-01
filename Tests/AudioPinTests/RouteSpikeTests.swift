#if DEBUG
import Testing
@testable import AudioPin

@Suite("RouteSpike")
struct RouteSpikeTests {
    @Test func parsesDeviceUIDsThatContainColons() {
        let request = RouteSpikeRequest.parse("com.spotify.client:AppleUSBAudioEngine:Remo:OBSBOT:2100000:3:60")
        #expect(request == RouteSpikeRequest(
            bundleID: "com.spotify.client", deviceUID: "AppleUSBAudioEngine:Remo:OBSBOT:2100000:3", volume: 0.6))
    }

    @Test func defaultMeansFollowTheSystemDefault() {
        #expect(RouteSpikeRequest.parse("com.apple.Music:default:100")
            == RouteSpikeRequest(bundleID: "com.apple.Music", deviceUID: nil, volume: 1))
    }

    @Test(arguments: [
        "", "com.spotify.client", "com.spotify.client:default", "com.spotify.client::50",
        "com.spotify.client:default:101", "com.spotify.client:default:-1", "com.spotify.client:default:loud",
        "com spotify:default:50", ":default:50", "com.spotify.client/../x:default:50",
    ])
    func rejectsMalformedValues(value: String) {
        #expect(RouteSpikeRequest.parse(value) == nil)
    }

    @Test func readsTheFlagFromArguments() {
        let args = ["AudioPin", "--preview", "--route-test=com.spotify.client:default:25"]
        #expect(RouteSpikeRequest.fromArguments(args)?.volume == 0.25)
        #expect(RouteSpikeRequest.fromArguments(["AudioPin"]) == nil)
    }
}
#endif
