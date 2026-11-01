import Testing
@testable import AudioPin

@Suite("RouteDeviceFilter")
struct RouteDeviceFilterTests {
    @Test(arguments: [
        ("dev.mjozefiak.AudioPin.route.com.spotify.client", true),
        ("dev.mjozefiak.AudioPin.route.spike.6F1C", true),
        ("dev.mjozefiak.AudioPin.routeX", false),
        ("dev.mjozefiak.AudioPin", false),
        ("BuiltInSpeakerDevice", false),
        ("~:AMS2_StackedOutput:0", false),
    ])
    func recognizesOnlyAudioPinRouteDevices(uid: String, own: Bool) {
        #expect(RouteDeviceFilter.isOwnRouteDevice(uid: uid) == own)
    }
}
