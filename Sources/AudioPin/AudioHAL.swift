import AudioToolbox
import CoreAudio
import Foundation

/// Audio direction: input (microphones) or output (speakers, headphones).
enum Direction: String, Codable, CaseIterable, Identifiable, Sendable {
    case input, output

    var id: String { rawValue }

    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    var defaultSelector: AudioObjectPropertySelector {
        self == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }

    var title: String { self == .input ? String(localized: "Input") : String(localized: "Output") }
    var longTitle: String {
        self == .input ? String(localized: "Microphones") : String(localized: "Speakers & Headphones")
    }
    var symbol: String { self == .input ? "mic.fill" : "speaker.wave.2.fill" }
}

/// Snapshot of one audio device in one direction.
struct AudioDevice: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let modelUID: String?
    let transport: UInt32
    let direction: Direction

    var id: String { uid }
}

/// Thin wrapper over the Core Audio HAL C API. All calls are synchronous and fast.
enum AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        // A device may disappear between the two calls; keep only what was actually returned.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func streamCount(_ id: AudioObjectID, _ direction: Direction) -> Int {
        var addr = address(kAudioDevicePropertyStreams, direction.scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Devices the system allows as the default in the given direction.
    static func devices(_ direction: Direction) -> [AudioDevice] {
        allDeviceIDs().compactMap { id in
            guard streamCount(id, direction) > 0,
                  uint32(id, kAudioDevicePropertyIsHidden) != 1,
                  uint32(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                  uint32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, direction.scope) != 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return AudioDevice(
                objectID: id,
                uid: uid,
                name: sanitizedName(string(id, kAudioObjectPropertyName)),
                modelUID: string(id, kAudioDevicePropertyModelUID),
                transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0,
                direction: direction
            )
        }
    }

    static let maxNameLength = 80

    /// Device names come from the device itself (Bluetooth names are chosen by the peer).
    /// Strip control and bidirectional-override characters so a name can't spoof other UI text.
    static func sanitizedName(_ raw: String?) -> String {
        let scalars = (raw ?? "").unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0x202A...0x202E).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
                && scalar.value != 0x200E && scalar.value != 0x200F
        }
        let name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return String(localized: "Unknown Device") }
        return name.count > maxNameLength ? String(name.prefix(maxNameLength)) + "…" : name
    }

    static func defaultDeviceID(_ direction: Direction) -> AudioObjectID? {
        uint32(system, direction.defaultSelector).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func systemOutputDeviceID() -> AudioObjectID? {
        uint32(system, kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    @discardableResult
    static func setDefault(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        var value = id
        return AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }

    @discardableResult
    static func setDefault(_ id: AudioObjectID, for direction: Direction) -> Bool {
        setDefault(id, selector: direction.defaultSelector)
    }

    static func canBeSystemOutput(_ id: AudioObjectID) -> Bool {
        uint32(id, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput) == 1
    }

    // MARK: Volume

    static func volume(_ id: AudioObjectID, _ direction: Direction) -> Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, direction.scope)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func setVolume(_ id: AudioObjectID, _ direction: Direction, _ volume: Float) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, direction.scope)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue
        else { return }
        var value = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}

/// Listens for changes of the device list and the default devices.
/// Owned by `CoreAudioSystem` on the main actor; it is intentionally not `Sendable`.
final class HALListener {
    private let queue = DispatchQueue(label: "AudioPin.hal-listener")
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start(onChange: @escaping @Sendable (AudioObjectPropertySelector) -> Void) {
        stop()
        let selectors = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ]
        for selector in selectors {
            var addr = AudioHAL.address(selector)
            // Explicitly @Sendable: the HAL calls this on `queue`, never on the main actor.
            // It must not capture `self` or any main-actor state.
            let block: AudioObjectPropertyListenerBlock = { @Sendable count, addresses in
                for i in 0..<Int(count) { onChange(addresses[i].mSelector) }
            }
            if AudioObjectAddPropertyListenerBlock(AudioHAL.system, &addr, queue, block) == noErr {
                registrations.append((addr, block))
            }
        }
    }

    func stop() {
        for (stored, block) in registrations {
            var addr = stored
            AudioObjectRemovePropertyListenerBlock(AudioHAL.system, &addr, queue, block)
        }
        registrations.removeAll()
    }
}
