import CoreAudio
import Foundation

/// Pure rules for choosing and maintaining device priorities. No side effects, fully unit-testable.
enum PriorityPolicy {
    /// Result of merging the currently connected devices into the saved priority list.
    struct MergeResult: Equatable {
        var list: [KnownDevice]
        /// Devices seen for the first time (appended to the end of the list).
        var added: [AudioDevice]
        var changed: Bool
    }

    /// The first enabled device from the priority list that is currently connected.
    static func preferred(priority: [KnownDevice], connected: [AudioDevice]) -> AudioDevice? {
        for known in priority where known.isEnabled {
            if let device = connected.first(where: { $0.uid == known.uid }) { return device }
        }
        return nil
    }

    /// Bluetooth microphones (e.g. AirPods) and iPhone Continuity microphones are the usual
    /// input "hijackers", so they start disabled. Everything else starts enabled.
    static func isEnabledByDefault(_ device: AudioDevice) -> Bool {
        guard device.direction == .input else { return true }
        return !(device.transport.isBluetooth || device.transport.isContinuity)
    }

    /// Adds newly seen devices to the list and refreshes the stored details of known ones.
    static func merge(known: [KnownDevice], connected: [AudioDevice], now: Date) -> MergeResult {
        var list = known
        var added: [AudioDevice] = []
        var changed = false
        let connectedUIDs = Set(connected.map(\.uid))

        for device in connected {
            if let index = list.firstIndex(where: { $0.uid == device.uid }) {
                if list[index].name != device.name || list[index].transport != device.transport {
                    list[index].name = device.name
                    list[index].transport = device.transport
                    list[index].lastSeen = now
                    changed = true
                }
            } else if let index = list.firstIndex(where: {
                isSameUSBDeviceInAnotherPort(known: $0, device: device, connectedUIDs: connectedUIDs)
            }) {
                list[index].uid = device.uid
                list[index].lastSeen = now
                changed = true
            } else {
                list.append(KnownDevice(
                    uid: device.uid,
                    name: device.name,
                    modelUID: device.modelUID,
                    transport: device.transport,
                    isEnabled: isEnabledByDefault(device),
                    lastSeen: now
                ))
                added.append(device)
                changed = true
            }
        }
        return MergeResult(list: list, added: added, changed: changed)
    }

    /// A USB device plugged into a different port gets a new UID (it contains the port location),
    /// so it is matched by model and name instead. Only USB: Bluetooth UIDs are stable MAC-based,
    /// and two headsets with the same default name must never take over each other's place.
    /// Known limitation: two identical USB devices moved between ports may swap places.
    static func isSameUSBDeviceInAnotherPort(
        known: KnownDevice, device: AudioDevice, connectedUIDs: Set<String>
    ) -> Bool {
        device.transport == kAudioDeviceTransportTypeUSB
            && known.transport == kAudioDeviceTransportTypeUSB
            && !connectedUIDs.contains(known.uid)
            && known.modelUID != nil
            && known.modelUID == device.modelUID
            && known.name == device.name
    }

    /// Stamps `lastSeen` for devices that were connected before and are gone now.
    static func markDisconnected(_ uids: Set<String>, in list: [KnownDevice], now: Date) -> [KnownDevice] {
        guard !uids.isEmpty else { return list }
        return list.map { device in
            var device = device
            if uids.contains(device.uid) { device.lastSeen = now }
            return device
        }
    }

    /// Initial order on first launch: enabled devices first, built-in ones last among them,
    /// and the current default on top — unless the system picked a "hijacker" (e.g. the AirPods mic).
    static func seed(_ list: [KnownDevice], currentDefault: AudioDevice?) -> [KnownDevice] {
        func weight(_ device: KnownDevice) -> Int {
            if !device.isEnabled { return 2 }
            return device.transport == kAudioDeviceTransportTypeBuiltIn ? 1 : 0
        }
        var result = list.enumerated()
            .sorted { (weight($0.element), $0.offset) < (weight($1.element), $1.offset) }
            .map(\.element)
        if let current = currentDefault, isEnabledByDefault(current),
           let index = result.firstIndex(where: { $0.uid == current.uid }) {
            result.insert(result.remove(at: index), at: 0)
        }
        return result
    }

    /// Moves the device to the top of the list and enables it.
    static func promote(_ uid: String, in list: [KnownDevice]) -> [KnownDevice]? {
        var result = list
        guard let index = result.firstIndex(where: { $0.uid == uid }) else { return nil }
        var item = result.remove(at: index)
        item.isEnabled = true
        result.insert(item, at: 0)
        return result
    }

    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`, without depending on SwiftUI.
    static func move(_ list: [KnownDevice], fromOffsets source: IndexSet, toOffset destination: Int) -> [KnownDevice] {
        let moving = source.map { list[$0] }
        var result = list
        for index in source.sorted(by: >) { result.remove(at: index) }
        let insertAt = destination - source.count(in: 0..<destination)
        result.insert(contentsOf: moving, at: min(max(insertAt, 0), result.count))
        return result
    }
}
