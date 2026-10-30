import CoreAudio

/// Everything AudioPin needs from the audio hardware. `CoreAudioSystem` is the real implementation;
/// tests use an in-memory fake, so the enforcement logic can run without touching real devices.
@MainActor
protocol AudioSystem: AnyObject {
    func devices(_ direction: Direction) -> [AudioDevice]
    func defaultDeviceID(_ direction: Direction) -> AudioObjectID?
    func setDefaultDevice(_ id: AudioObjectID, for direction: Direction) -> Bool

    func systemOutputDeviceID() -> AudioObjectID?
    func canBeSystemOutput(_ id: AudioObjectID) -> Bool
    func setSystemOutputDevice(_ id: AudioObjectID) -> Bool

    func volume(_ id: AudioObjectID, _ direction: Direction) -> Float?
    func setVolume(_ id: AudioObjectID, _ direction: Direction, _ volume: Float)

    /// Calls `onChange` (on an arbitrary queue) whenever the device list or a default device changes.
    func startListening(onChange: @escaping @Sendable (AudioObjectPropertySelector) -> Void)
    func stopListening()
}

/// Production `AudioSystem` backed by the Core Audio HAL.
@MainActor
final class CoreAudioSystem: AudioSystem {
    private let listener = HALListener()

    func devices(_ direction: Direction) -> [AudioDevice] { AudioHAL.devices(direction) }
    func defaultDeviceID(_ direction: Direction) -> AudioObjectID? { AudioHAL.defaultDeviceID(direction) }
    func setDefaultDevice(_ id: AudioObjectID, for direction: Direction) -> Bool {
        AudioHAL.setDefault(id, for: direction)
    }

    func systemOutputDeviceID() -> AudioObjectID? { AudioHAL.systemOutputDeviceID() }
    func canBeSystemOutput(_ id: AudioObjectID) -> Bool { AudioHAL.canBeSystemOutput(id) }
    func setSystemOutputDevice(_ id: AudioObjectID) -> Bool {
        AudioHAL.setDefault(id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    func volume(_ id: AudioObjectID, _ direction: Direction) -> Float? { AudioHAL.volume(id, direction) }
    func setVolume(_ id: AudioObjectID, _ direction: Direction, _ volume: Float) {
        AudioHAL.setVolume(id, direction, volume)
    }

    func startListening(onChange: @escaping @Sendable (AudioObjectPropertySelector) -> Void) {
        listener.start(onChange: onChange)
    }

    func stopListening() { listener.stop() }
}
