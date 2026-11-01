/// Recognizes AudioPin's own per-app route aggregates.
///
/// Inside the process that creates them, private aggregates still show up in the device list. They must
/// never enter a priority list or be picked as a default, so `AudioManager` drops them on every refresh.
/// The filter sits above `AudioSystem` on purpose: `FakeAudioSystem` returns its arrays directly, so tests
/// exercise it.
enum RouteDeviceFilter {
    static let uidPrefix = "dev.mjozefiak.AudioPin.route."

    static func isOwnRouteDevice(uid: String) -> Bool { uid.hasPrefix(uidPrefix) }
}
