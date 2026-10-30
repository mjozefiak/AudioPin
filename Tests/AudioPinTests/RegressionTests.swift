import CoreAudio
import Foundation
import Testing
@testable import AudioPin

/// Regression tests for the issues found in the code review.
@Suite("Code review regressions")
struct RegressionTests {
    // Adding a setting in a future version must not wipe the stored priority lists.
    @Test func settingsDecodeWithMissingKeysKeepsPriorities() throws {
        let json = """
        {"isActive": false, "inputPriority": [{"uid": "mic", "name": "Mic", "transport": 0,
          "isEnabled": true, "lastSeen": 0}]}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.isActive == false)
        #expect(settings.inputPriority.map(\.uid) == ["mic"])
        #expect(settings.enforceOutput == true)
        #expect(settings.didOfferLaunchAtLogin == false)
    }

    @MainActor
    @Test func unreadableSettingsAreBackedUpNotLost() throws {
        let defaults = try #require(UserDefaults(suiteName: "AudioPinTests-\(UUID().uuidString)"))
        let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "settings")
        #expect(store.load() == AppSettings())
        #expect(defaults.data(forKey: store.backupKey) == garbage)
    }

    @MainActor
    @Test func settingsRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "AudioPinTests-\(UUID().uuidString)"))
        let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")
        var settings = AppSettings()
        settings.outputPriority = [Sample.known(Sample.speakers)]
        settings.notifyOnCorrection = true
        store.save(settings)
        #expect(store.load() == settings)
    }

    // Two Bluetooth headsets with the same default name must not take over each other's entry.
    @Test func bluetoothDeviceWithSameNameDoesNotStealIdentity() {
        let pairA = AudioDevice(objectID: 1, uid: "AA:input", name: "AirPods Pro", modelUID: "airpods-pro",
                                transport: kAudioDeviceTransportTypeBluetooth, direction: .output)
        let pairB = AudioDevice(objectID: 2, uid: "BB:input", name: "AirPods Pro", modelUID: "airpods-pro",
                                transport: kAudioDeviceTransportTypeBluetooth, direction: .output)
        let known = [Sample.known(pairA), Sample.known(Sample.speakers)]
        let result = PriorityPolicy.merge(known: known, connected: [pairB, Sample.speakers], now: .now)
        #expect(result.list.map(\.uid) == [pairA.uid, Sample.speakers.uid, pairB.uid])
        #expect(result.added == [pairB])
    }

    @Test func disconnectedDevicesGetLastSeenStamped() {
        let old = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 1000)
        let list = [Sample.known(Sample.usbMic, lastSeen: old), Sample.known(Sample.builtInMic, lastSeen: old)]
        let updated = PriorityPolicy.markDisconnected([Sample.usbMic.uid], in: list, now: now)
        #expect(updated[0].lastSeen == now)
        #expect(updated[1].lastSeen == old)
    }

    @Test func deviceNamesAreSanitized() {
        #expect(AudioHAL.sanitizedName("Evil\u{202E}enoD") == "EvilenoD")
        #expect(AudioHAL.sanitizedName("  Mic\n ") == "Mic")
        #expect(AudioHAL.sanitizedName(nil) == "Nieznane urządzenie")
        let long = String(repeating: "x", count: 200)
        #expect(AudioHAL.sanitizedName(long).count == AudioHAL.maxNameLength + 1)
    }
}

@MainActor
@Suite("AudioManager regressions")
struct AudioManagerRegressionTests {
    private func makeManager() -> (AudioManager, FakeAudioSystem, InMemorySettingsStore) {
        let system = FakeAudioSystem()
        system.inputs = [Sample.usbMic, Sample.airPodsMic]
        system.outputs = [Sample.airPodsOut, Sample.speakers]
        system.defaultInput = Sample.usbMic.objectID
        system.defaultOutput = Sample.airPodsOut.objectID
        let store = InMemorySettingsStore()
        return (AudioManager(system: system, store: store), system, store)
    }

    @Test func connectedDevicesCannotBeForgotten() {
        let (manager, system, store) = makeManager()
        manager.start()
        system.inputs = [Sample.usbMic]
        manager.reconcile()
        manager.forget([Sample.usbMic.uid, Sample.airPodsMic.uid], .input)
        #expect(store.stored.inputPriority.map(\.uid) == [Sample.usbMic.uid])
        manager.stop()
    }

    @Test func suspendedSessionDoesNotTouchDevices() {
        let (manager, system, _) = makeManager()
        manager.start()
        manager.setSuspended(true)
        system.defaultInput = Sample.airPodsMic.objectID
        manager.reconcile()
        #expect(system.defaultInput == Sample.airPodsMic.objectID)
        manager.stop()
    }

    @Test func failingDeviceDoesNotCauseEndlessAttempts() {
        let (manager, system, _) = makeManager()
        manager.start()
        system.failingDevices = [Sample.usbMic.objectID]
        system.defaultInput = Sample.airPodsMic.objectID
        let before = system.setDefaultCalls.count
        for _ in 0..<20 { manager.reconcile() }
        #expect(system.setDefaultCalls.count - before == CorrectionLimiter().maxCorrections)
        manager.stop()
    }

    @Test func disconnectingStampsLastSeen() {
        let (manager, system, store) = makeManager()
        manager.start()
        let before = Date()
        system.inputs = [Sample.usbMic]
        manager.reconcile()
        let airPods = store.stored.inputPriority.first { $0.uid == Sample.airPodsMic.uid }
        #expect((airPods?.lastSeen ?? .distantPast) >= before)
        manager.stop()
    }
}
