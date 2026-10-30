import AudioToolbox
import CoreAudio
import Foundation

/// Kierunek audio: wejście (mikrofony) lub wyjście (głośniki, słuchawki).
enum Direction: String, Codable, CaseIterable, Identifiable, Sendable {
    case input, output

    var id: String { rawValue }

    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    var defaultSelector: AudioObjectPropertySelector {
        self == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }

    var title: String { self == .input ? "Wejście" : "Wyjście" }
    var longTitle: String { self == .input ? "Mikrofony" : "Głośniki i słuchawki" }
    var symbol: String { self == .input ? "mic.fill" : "speaker.wave.2.fill" }
}

/// Migawka jednego urządzenia audio w danym kierunku.
struct AudioDevice: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let modelUID: String?
    let transport: UInt32
    let direction: Direction

    var id: String { uid }
}

/// Cienka warstwa nad CoreAudio HAL (C API). Wszystkie wywołania są synchroniczne i szybkie.
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
        return ids
    }

    static func streamCount(_ id: AudioObjectID, _ direction: Direction) -> Int {
        var addr = address(kAudioDevicePropertyStreams, direction.scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Urządzenia, które system pozwala ustawić jako domyślne w danym kierunku.
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
                name: string(id, kAudioObjectPropertyName) ?? "Nieznane urządzenie",
                modelUID: string(id, kAudioDevicePropertyModelUID),
                transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0,
                direction: direction
            )
        }
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

    // MARK: Głośność

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

/// Nasłuchuje zmian listy urządzeń i urządzeń domyślnych.
/// Stan zmienia się tylko w start/stop wywoływanych z głównego aktora.
final class HALListener: @unchecked Sendable {
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
            let block: AudioObjectPropertyListenerBlock = { count, addresses in
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
