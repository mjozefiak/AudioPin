import CoreAudio
import Foundation
@testable import AudioPin

/// In-memory audio hardware. Tests set `inputs`, `outputs` and the defaults, then inspect what AudioPin changed.
@MainActor
final class FakeAudioSystem: AudioSystem {
    var inputs: [AudioDevice] = []
    var outputs: [AudioDevice] = []
    var defaultInput: AudioObjectID?
    var defaultOutput: AudioObjectID?
    var systemOutput: AudioObjectID?
    var failingDevices: Set<AudioObjectID> = []
    private(set) var setDefaultCalls: [(AudioObjectID, Direction)] = []
    private(set) var listening = false

    func devices(_ direction: Direction) -> [AudioDevice] { direction == .input ? inputs : outputs }

    func defaultDeviceID(_ direction: Direction) -> AudioObjectID? {
        direction == .input ? defaultInput : defaultOutput
    }

    func setDefaultDevice(_ id: AudioObjectID, for direction: Direction) -> Bool {
        setDefaultCalls.append((id, direction))
        guard !failingDevices.contains(id), devices(direction).contains(where: { $0.objectID == id }) else {
            return false
        }
        if direction == .input { defaultInput = id } else { defaultOutput = id }
        return true
    }

    func systemOutputDeviceID() -> AudioObjectID? { systemOutput }
    func canBeSystemOutput(_ id: AudioObjectID) -> Bool { true }
    func setSystemOutputDevice(_ id: AudioObjectID) -> Bool {
        systemOutput = id
        return true
    }

    func volume(_ id: AudioObjectID, _ direction: Direction) -> Float? { 0.5 }
    func setVolume(_ id: AudioObjectID, _ direction: Direction, _ volume: Float) {}

    func startListening(onChange: @escaping @Sendable (AudioObjectPropertySelector) -> Void) { listening = true }
    func stopListening() { listening = false }
}

@MainActor
final class InMemorySettingsStore: SettingsStore {
    var stored: AppSettings
    private(set) var saveCount = 0

    init(_ settings: AppSettings = AppSettings()) { stored = settings }

    func load() -> AppSettings { stored }
    func save(_ settings: AppSettings) {
        stored = settings
        saveCount += 1
    }
}

/// Sample devices matching a typical setup: USB mic + AirPods Max + iPhone + built-in speakers.
enum Sample {
    static let usbMic = AudioDevice(
        objectID: 80, uid: "AppleUSBAudioEngine:Remo:OBSBOT:2100000:3", name: "OBSBOT Meet SE Microphone",
        modelUID: "OBSBOT:model", transport: kAudioDeviceTransportTypeUSB, direction: .input)
    static let airPodsMic = AudioDevice(
        objectID: 90, uid: "90-62-3F-B0-82-68:input", name: "AirPods Max",
        modelUID: "airpods-max", transport: kAudioDeviceTransportTypeBluetooth, direction: .input)
    static let iPhoneMic = AudioDevice(
        objectID: 95, uid: "B3686F13-iphone", name: "iPhone Microphone",
        modelUID: nil, transport: kAudioDeviceTransportTypeContinuityCaptureWired, direction: .input)
    static let builtInMic = AudioDevice(
        objectID: 70, uid: "BuiltInMicrophoneDevice", name: "MacBook Microphone",
        modelUID: "builtin-mic", transport: kAudioDeviceTransportTypeBuiltIn, direction: .input)

    static let airPodsOut = AudioDevice(
        objectID: 84, uid: "90-62-3F-B0-82-68:output", name: "AirPods Max",
        modelUID: "airpods-max", transport: kAudioDeviceTransportTypeBluetooth, direction: .output)
    static let speakers = AudioDevice(
        objectID: 74, uid: "BuiltInSpeakerDevice", name: "Mac Studio Speakers",
        modelUID: "builtin-speaker", transport: kAudioDeviceTransportTypeBuiltIn, direction: .output)
    static let monitor = AudioDevice(
        objectID: 97, uid: "monitor-dp", name: "Studio Display",
        modelUID: "display", transport: kAudioDeviceTransportTypeDisplayPort, direction: .output)

    static func known(_ device: AudioDevice, enabled: Bool = true, lastSeen: Date = .now) -> KnownDevice {
        KnownDevice(uid: device.uid, name: device.name, modelUID: device.modelUID,
                    transport: device.transport, isEnabled: enabled, lastSeen: lastSeen)
    }
}
