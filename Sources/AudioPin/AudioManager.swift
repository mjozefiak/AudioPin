import CoreAudio
import Foundation
import Observation
import os

/// One entry in the in-app activity log.
struct ActivityEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let direction: Direction
    let message: String
}

/// Keeps the system defaults in line with the user's priority lists.
///
/// Owns UI-facing state (connected devices, current defaults, activity log) and orchestrates
/// the work: the selection rules live in `PriorityPolicy`, rate limiting in `CorrectionLimiter`,
/// hardware access behind `AudioSystem` and persistence behind `SettingsStore`.
@MainActor
@Observable
final class AudioManager {
    /// Timing of the enforcement loop.
    enum Timing {
        static let settingsChangeDelay: Duration = .milliseconds(50)
        static let defaultChangeDelay: Duration = .milliseconds(150)
        static let deviceListChangeDelay: Duration = .milliseconds(300)
        static let wakeDelay: Duration = .seconds(1)
        /// Extra checks after a device connects or disconnects (macOS often switches late).
        static let watchCheckpoints: [Duration] = [.milliseconds(800), .milliseconds(1600), .seconds(3), .seconds(5)]
        /// Extra checks after each correction (Bluetooth may switch again after renegotiating).
        static let verificationDelays: [Duration] = [.seconds(1), .seconds(3)]
        static let flashDuration: Duration = .seconds(2.5)
        /// Small margin so the re-check after a back-off lands just after it ends.
        static let backoffMargin: Duration = .milliseconds(100)
    }

    private static let logger = Logger(subsystem: "dev.mjozefiak.AudioPin", category: "enforcement")

    static let maxActivityEntries = 50

    private(set) var connected: [Direction: [AudioDevice]] = [.input: [], .output: []]
    private(set) var currentDefault: [Direction: AudioObjectID] = [:]
    private(set) var activity: [ActivityEntry] = []
    private(set) var correctionCount = 0
    private(set) var isFlashing = false
    /// True while this login session is not the active one (fast user switching).
    /// Default devices are shared system-wide, so a background session must not fight the active user.
    private(set) var isSuspended = false

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            scheduleReconcile(delay: Timing.settingsChangeDelay)
        }
    }

    @ObservationIgnored var onCorrection: ((Direction, String) -> Void)?

    @ObservationIgnored private let system: any AudioSystem
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var limiter = CorrectionLimiter()
    /// Separate budget for the alert-sound device, so it can never ping-pong with the system either.
    @ObservationIgnored private var alertLimiter = CorrectionLimiter()
    @ObservationIgnored private var backoffTasks: [Direction: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingReconcile: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var verifyTasks: [Direction: Task<Void, Never>] = [:]
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    init(system: any AudioSystem = CoreAudioSystem(), store: any SettingsStore = UserDefaultsSettingsStore()) {
        self.system = system
        self.store = store
        settings = store.load()
    }

    func start() {
        refreshDevices()
        if !settings.didRunOnboarding { seedInitialPriorities() }
        system.startListening { [weak self] selector in
            Task { @MainActor in self?.handleHALChange(selector) }
        }
        reconcile()
    }

    func stop() {
        system.stopListening()
        [pendingReconcile, watchTask, flashTask].forEach { $0?.cancel() }
        verifyTasks.values.forEach { $0.cancel() }
        backoffTasks.values.forEach { $0.cancel() }
    }

    /// Fast user switching: pause while another user's session is in front.
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if !suspended {
            limiter.reset()
            alertLimiter.reset()
            scheduleReconcile(delay: Timing.wakeDelay)
        }
    }

    /// After sleep the hardware may have changed; clear the back-off and check again.
    func systemDidWake() {
        limiter.reset()
        alertLimiter.reset()
        scheduleReconcile(delay: Timing.wakeDelay)
    }

    // MARK: Reading state

    func devices(_ direction: Direction) -> [AudioDevice] { connected[direction] ?? [] }

    func isConnected(_ uid: String, _ direction: Direction) -> Bool {
        devices(direction).contains { $0.uid == uid }
    }

    func defaultDevice(_ direction: Direction) -> AudioDevice? {
        guard let id = currentDefault[direction] else { return nil }
        return devices(direction).first { $0.objectID == id }
    }

    /// The device AudioPin wants as the default.
    func preferredDevice(_ direction: Direction) -> AudioDevice? {
        PriorityPolicy.preferred(priority: settings.priority(direction), connected: devices(direction))
    }

    func volume(_ direction: Direction) -> Float? {
        guard let id = currentDefault[direction] else { return nil }
        return system.volume(id, direction)
    }

    func setVolume(_ value: Float, _ direction: Direction) {
        guard let id = currentDefault[direction] else { return }
        system.setVolume(id, direction, value)
    }

    // MARK: User actions

    /// Moves the device to the top of the list and enables it (picked from the menu).
    func makeTopPriority(_ uid: String, _ direction: Direction) {
        guard let list = PriorityPolicy.promote(uid, in: settings.priority(direction)) else { return }
        settings.setPriority(list, for: direction)
        limiter.reset(direction)
        log(direction, String(localized: "Set as favorite: \(list[0].name)"))
    }

    func move(_ direction: Direction, from source: IndexSet, to destination: Int) {
        let list = PriorityPolicy.move(settings.priority(direction), fromOffsets: source, toOffset: destination)
        settings.setPriority(list, for: direction)
    }

    func move(_ uid: String, _ direction: Direction, by offset: Int) {
        var list = settings.priority(direction)
        guard let index = list.firstIndex(where: { $0.uid == uid }) else { return }
        let target = min(max(index + offset, 0), list.count - 1)
        guard target != index else { return }
        list.swapAt(index, target)
        settings.setPriority(list, for: direction)
    }

    func setEnabled(_ enabled: Bool, uid: String, _ direction: Direction) {
        var list = settings.priority(direction)
        guard let index = list.firstIndex(where: { $0.uid == uid }) else { return }
        list[index].isEnabled = enabled
        settings.setPriority(list, for: direction)
    }

    /// Removes disconnected devices from the list. Connected devices cannot be forgotten:
    /// they would be re-added immediately with default settings.
    func forget(_ uids: Set<String>, _ direction: Direction) {
        let removable = uids.filter { !isConnected($0, direction) }
        guard !removable.isEmpty else { return }
        var list = settings.priority(direction)
        list.removeAll { removable.contains($0.uid) }
        settings.setPriority(list, for: direction)
    }

    func clearActivity() { activity.removeAll() }

    // MARK: Enforcement

    func reconcile() {
        refreshDevices()
        guard settings.isActive, !isSuspended else { return }
        for direction in Direction.allCases where settings.enforces(direction) {
            enforce(direction)
        }
    }

    func scheduleReconcile(delay: Duration) {
        pendingReconcile?.cancel()
        pendingReconcile = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func handleHALChange(_ selector: AudioObjectPropertySelector) {
        refreshDefaults()
        // Bluetooth devices announce themselves with several events; give the system a moment.
        if selector == kAudioHardwarePropertyDevices {
            scheduleReconcile(delay: Timing.deviceListChangeDelay)
            scheduleWatchWindow()
        } else {
            scheduleReconcile(delay: Timing.defaultChangeDelay)
        }
    }

    private func scheduleWatchWindow() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var elapsed = Duration.zero
            for checkpoint in Timing.watchCheckpoints {
                try? await Task.sleep(for: checkpoint - elapsed)
                elapsed = checkpoint
                guard !Task.isCancelled else { return }
                self?.reconcile()
            }
        }
    }

    private func scheduleVerification(_ direction: Direction) {
        verifyTasks[direction]?.cancel()
        verifyTasks[direction] = Task { [weak self] in
            var elapsed = Duration.zero
            for delay in Timing.verificationDelays {
                try? await Task.sleep(for: delay - elapsed)
                elapsed = delay
                guard !Task.isCancelled, let self else { return }
                // Refresh the device list too: the target may have disappeared meanwhile.
                self.refreshDevices()
                if self.settings.isActive, !self.isSuspended, self.settings.enforces(direction) {
                    self.enforce(direction)
                }
            }
        }
    }

    private func refreshDefaults() {
        for direction in Direction.allCases {
            currentDefault[direction] = system.defaultDeviceID(direction)
        }
    }

    private func refreshDevices() {
        for direction in Direction.allCases {
            let list = system.devices(direction)
            let gone = Set(devices(direction).map(\.uid)).subtracting(list.map(\.uid))
            connected[direction] = list
            if !gone.isEmpty {
                settings.setPriority(
                    PriorityPolicy.markDisconnected(gone, in: settings.priority(direction), now: Date()),
                    for: direction)
            }
            register(list, direction)
        }
        refreshDefaults()
    }

    private func register(_ devices: [AudioDevice], _ direction: Direction) {
        let result = PriorityPolicy.merge(known: settings.priority(direction), connected: devices, now: Date())
        guard result.changed else { return }
        settings.setPriority(result.list, for: direction)
        if settings.didRunOnboarding {
            result.added.forEach { log(direction, String(localized: "New device: \($0.name)")) }
        }
    }

    private func seedInitialPriorities() {
        for direction in Direction.allCases {
            let list = PriorityPolicy.seed(settings.priority(direction), currentDefault: defaultDevice(direction))
            settings.setPriority(list, for: direction)
        }
        settings.didRunOnboarding = true
    }

    private func enforce(_ direction: Direction) {
        guard let target = preferredDevice(direction) else { return }

        if direction == .output, settings.alertSoundsFollowOutput {
            syncAlertSoundDevice(to: target)
        }

        guard currentDefault[direction] != target.objectID else { return }

        let now = clock.now
        switch limiter.check(direction, now: now) {
        case .inBackoff:
            return
        case .startedBackoff:
            log(direction, String(localized: "The system keeps switching devices — pausing corrections for 30 s"))
            scheduleAfterBackoff(direction)
            return
        case .allowed:
            break
        }

        let previous = defaultDevice(direction)?.name ?? String(localized: "another device")
        // Failed attempts count against the limit too, so a device that refuses can't cause a loop.
        limiter.record(direction, now: now)
        guard system.setDefaultDevice(target.objectID, for: direction) else {
            Self.logger.error("Failed to set default \(direction.rawValue, privacy: .public) device")
            log(direction, String(localized: "Could not switch to \(target.name)"))
            return
        }
        Self.logger.info("Corrected default \(direction.rawValue, privacy: .public) device")
        currentDefault[direction] = target.objectID
        correctionCount += 1

        let message = "\(previous) → \(target.name)"
        log(direction, message)
        onCorrection?(direction, message)
        flash()
        scheduleVerification(direction)
    }

    private func syncAlertSoundDevice(to target: AudioDevice) {
        guard system.systemOutputDeviceID() != target.objectID, system.canBeSystemOutput(target.objectID) else { return }
        let now = clock.now
        guard alertLimiter.check(.output, now: now) == .allowed else { return }
        alertLimiter.record(.output, now: now)
        if !system.setSystemOutputDevice(target.objectID) {
            Self.logger.error("Failed to set the alert sound device")
        }
    }

    /// When a back-off ends nothing else may trigger a check, so schedule one explicitly.
    private func scheduleAfterBackoff(_ direction: Direction) {
        backoffTasks[direction]?.cancel()
        let delay = limiter.backoff + Timing.backoffMargin
        backoffTasks[direction] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func flash() {
        isFlashing = true
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Timing.flashDuration)
            guard !Task.isCancelled else { return }
            self?.isFlashing = false
        }
    }

    private func log(_ direction: Direction, _ message: String) {
        activity.insert(ActivityEntry(date: Date(), direction: direction, message: message), at: 0)
        if activity.count > Self.maxActivityEntries {
            activity.removeLast(activity.count - Self.maxActivityEntries)
        }
    }
}
