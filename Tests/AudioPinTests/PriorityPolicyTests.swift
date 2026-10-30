import CoreAudio
import Foundation
import Testing
@testable import AudioPin

@Suite("PriorityPolicy")
struct PriorityPolicyTests {
    @Test func preferredSkipsDisabledAndDisconnected() {
        let priority = [
            Sample.known(Sample.airPodsMic, enabled: false),
            Sample.known(Sample.builtInMic),
            Sample.known(Sample.usbMic),
        ]
        let connected = [Sample.airPodsMic, Sample.usbMic]
        #expect(PriorityPolicy.preferred(priority: priority, connected: connected) == Sample.usbMic)
    }

    @Test func preferredIsNilWhenEverythingIsDisabled() {
        let priority = [Sample.known(Sample.airPodsMic, enabled: false)]
        #expect(PriorityPolicy.preferred(priority: priority, connected: [Sample.airPodsMic]) == nil)
    }

    @Test(arguments: [
        (Sample.airPodsMic, false),
        (Sample.iPhoneMic, false),
        (Sample.usbMic, true),
        (Sample.builtInMic, true),
        (Sample.airPodsOut, true),
    ])
    func enabledByDefault(device: AudioDevice, expected: Bool) {
        #expect(PriorityPolicy.isEnabledByDefault(device) == expected)
    }

    @Test func mergeAppendsNewDevicesAtTheEnd() {
        let known = [Sample.known(Sample.usbMic)]
        let result = PriorityPolicy.merge(known: known, connected: [Sample.usbMic, Sample.airPodsMic], now: .now)
        #expect(result.list.map(\.uid) == [Sample.usbMic.uid, Sample.airPodsMic.uid])
        #expect(result.list[1].isEnabled == false)
        #expect(result.added == [Sample.airPodsMic])
        #expect(result.changed)
    }

    @Test func mergeIsStableWhenNothingChanged() {
        let known = [Sample.known(Sample.usbMic)]
        let result = PriorityPolicy.merge(known: known, connected: [Sample.usbMic], now: .now)
        #expect(!result.changed)
        #expect(result.list == known)
    }

    @Test func mergeKeepsPlaceOfUSBDeviceInAnotherPort() {
        let known = [Sample.known(Sample.usbMic), Sample.known(Sample.builtInMic)]
        var moved = Sample.usbMic
        moved = AudioDevice(objectID: 81, uid: "AppleUSBAudioEngine:Remo:OBSBOT:1100000:3", name: moved.name,
                            modelUID: moved.modelUID, transport: moved.transport, direction: .input)
        let result = PriorityPolicy.merge(known: known, connected: [moved, Sample.builtInMic], now: .now)
        #expect(result.list.map(\.uid) == [moved.uid, Sample.builtInMic.uid])
        #expect(result.added.isEmpty)
    }

    @Test func seedPutsCurrentDefaultFirstAndBuiltInLast() {
        let list = [
            Sample.known(Sample.builtInMic),
            Sample.known(Sample.airPodsMic, enabled: false),
            Sample.known(Sample.usbMic),
        ]
        let seeded = PriorityPolicy.seed(list, currentDefault: Sample.usbMic)
        #expect(seeded.map(\.uid) == [Sample.usbMic.uid, Sample.builtInMic.uid, Sample.airPodsMic.uid])
    }

    @Test func seedIgnoresHijackerAsCurrentDefault() {
        let list = [Sample.known(Sample.usbMic), Sample.known(Sample.airPodsMic, enabled: false)]
        let seeded = PriorityPolicy.seed(list, currentDefault: Sample.airPodsMic)
        #expect(seeded.first?.uid == Sample.usbMic.uid)
        #expect(seeded.first { $0.uid == Sample.airPodsMic.uid }?.isEnabled == false)
    }

    @Test func promoteMovesToTopAndEnables() {
        let list = [Sample.known(Sample.usbMic), Sample.known(Sample.airPodsMic, enabled: false)]
        let promoted = PriorityPolicy.promote(Sample.airPodsMic.uid, in: list)
        #expect(promoted?.first?.uid == Sample.airPodsMic.uid)
        #expect(promoted?.first?.isEnabled == true)
        #expect(PriorityPolicy.promote("missing", in: list) == nil)
    }

    @Test(arguments: [
        ([0], 3, ["b", "c", "a"]),
        ([2], 0, ["c", "a", "b"]),
        ([0, 1], 3, ["c", "a", "b"]),
        ([1], 1, ["a", "b", "c"]),
    ])
    func moveMatchesSwiftUISemantics(source: [Int], destination: Int, expected: [String]) {
        let list = ["a", "b", "c"].map {
            KnownDevice(uid: $0, name: $0, modelUID: nil, transport: 0, isEnabled: true, lastSeen: .distantPast)
        }
        let moved = PriorityPolicy.move(list, fromOffsets: IndexSet(source), toOffset: destination)
        #expect(moved.map(\.uid) == expected)
    }
}
