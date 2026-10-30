import Foundation
import Testing
@testable import AudioPin

@MainActor
@Suite("AudioManager")
struct AudioManagerTests {
    private func makeManager(
        inputs: [AudioDevice] = [Sample.usbMic, Sample.airPodsMic],
        outputs: [AudioDevice] = [Sample.airPodsOut, Sample.speakers],
        defaultInput: AudioDevice? = Sample.usbMic,
        defaultOutput: AudioDevice? = Sample.airPodsOut,
        settings: AppSettings = AppSettings()
    ) -> (AudioManager, FakeAudioSystem, InMemorySettingsStore) {
        let system = FakeAudioSystem()
        system.inputs = inputs
        system.outputs = outputs
        system.defaultInput = defaultInput?.objectID
        system.defaultOutput = defaultOutput?.objectID
        let store = InMemorySettingsStore(settings)
        let manager = AudioManager(system: system, store: store)
        return (manager, system, store)
    }

    @Test func firstLaunchRevertsAirPodsMicHijack() {
        let (manager, system, store) = makeManager(defaultInput: Sample.airPodsMic)
        manager.start()
        #expect(system.defaultInput == Sample.usbMic.objectID)
        #expect(store.stored.inputPriority.first?.uid == Sample.usbMic.uid)
        #expect(store.stored.didRunOnboarding)
        #expect(system.listening)
        manager.stop()
    }

    @Test func revertsSystemSwitchOnBothDirections() {
        let (manager, system, _) = makeManager()
        manager.start()
        system.defaultInput = Sample.airPodsMic.objectID
        system.defaultOutput = Sample.speakers.objectID
        manager.reconcile()
        #expect(system.defaultInput == Sample.usbMic.objectID)
        #expect(system.defaultOutput == Sample.airPodsOut.objectID)
        #expect(manager.correctionCount == 2)
        manager.stop()
    }

    @Test func fallsBackToNextDeviceWhenFavoriteDisconnects() {
        let (manager, system, _) = makeManager(inputs: [Sample.usbMic, Sample.builtInMic, Sample.airPodsMic])
        manager.start()
        system.inputs = [Sample.builtInMic, Sample.airPodsMic]
        system.defaultInput = Sample.airPodsMic.objectID
        manager.reconcile()
        #expect(system.defaultInput == Sample.builtInMic.objectID)
        manager.stop()
    }

    @Test func pausedManagerDoesNothing() {
        var settings = AppSettings()
        settings.isActive = false
        let (manager, system, _) = makeManager(defaultInput: Sample.airPodsMic, settings: settings)
        manager.start()
        #expect(system.defaultInput == Sample.airPodsMic.objectID)
        #expect(system.setDefaultCalls.isEmpty)
        manager.stop()
    }

    @Test func enforcementCanBeTurnedOffPerDirection() {
        var settings = AppSettings()
        settings.enforceInput = false
        let (manager, system, _) = makeManager(defaultInput: Sample.airPodsMic, settings: settings)
        manager.start()
        system.defaultOutput = Sample.speakers.objectID
        manager.reconcile()
        #expect(system.defaultInput == Sample.airPodsMic.objectID)
        #expect(system.defaultOutput == Sample.airPodsOut.objectID)
        manager.stop()
    }

    @Test func stopsFightingAfterRepeatedSwitches() {
        let (manager, system, _) = makeManager()
        manager.start()
        for _ in 0..<10 {
            system.defaultInput = Sample.airPodsMic.objectID
            manager.reconcile()
        }
        #expect(manager.correctionCount == CorrectionLimiter().maxCorrections)
        #expect(system.defaultInput == Sample.airPodsMic.objectID)
        manager.stop()
    }

    @Test func makeTopPriorityEnablesAndSelects() {
        let (manager, system, _) = makeManager()
        manager.start()
        manager.makeTopPriority(Sample.airPodsMic.uid, .input)
        manager.reconcile()
        #expect(system.defaultInput == Sample.airPodsMic.objectID)
        manager.stop()
    }

    @Test func alertSoundsFollowOutput() {
        let (manager, system, _) = makeManager()
        system.systemOutput = Sample.speakers.objectID
        manager.start()
        #expect(system.systemOutput == Sample.airPodsOut.objectID)
        manager.stop()
    }
}
