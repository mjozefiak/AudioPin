import AppKit
import CoreAudio
import Foundation
import Observation

/// Wpis w historii działań aplikacji.
struct ActivityEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let direction: Direction
    let message: String
}

/// Serce aplikacji: śledzi urządzenia i pilnuje, żeby domyślne było to z najwyższym priorytetem.
@MainActor
@Observable
final class AudioManager {
    private(set) var connected: [Direction: [AudioDevice]] = [.input: [], .output: []]
    private(set) var currentDefault: [Direction: AudioObjectID] = [:]
    private(set) var activity: [ActivityEntry] = []
    private(set) var correctionCount = 0

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            scheduleReconcile(delay: .milliseconds(50))
        }
    }

    @ObservationIgnored private let listener = HALListener()
    @ObservationIgnored private var pendingReconcile: Task<Void, Never>?
    @ObservationIgnored private var verifyTasks: [Direction: Task<Void, Never>] = [:]
    /// Znaczniki czasu naszych korekt (do ograniczenia walki z systemem).
    @ObservationIgnored private var corrections: [Direction: [Date]] = [:]
    @ObservationIgnored private var backoffUntil: [Direction: Date] = [:]
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored var onCorrection: ((Direction, String) -> Void)?

    init() {
        settings = AppSettings.load()
    }

    func start() {
        refreshDevices()
        if !settings.didRunOnboarding { seedInitialPriorities() }
        listener.start { [weak self] selector in
            Task { @MainActor in self?.handleHALChange(selector) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.backoffUntil.removeAll()
                self?.scheduleReconcile(delay: .seconds(1))
            }
        }
        reconcile()
    }

    // MARK: Odczyt stanu

    func devices(_ direction: Direction) -> [AudioDevice] { connected[direction] ?? [] }

    func isConnected(_ uid: String, _ direction: Direction) -> Bool {
        devices(direction).contains { $0.uid == uid }
    }

    func defaultDevice(_ direction: Direction) -> AudioDevice? {
        guard let id = currentDefault[direction] else { return nil }
        return devices(direction).first { $0.objectID == id }
    }

    /// Urządzenie, które aplikacja chce mieć jako domyślne.
    func preferredDevice(_ direction: Direction) -> AudioDevice? {
        let available = devices(direction)
        for known in settings.priority(direction) where known.isEnabled {
            if let device = available.first(where: { $0.uid == known.uid }) { return device }
        }
        return nil
    }

    func volume(_ direction: Direction) -> Float? {
        guard let id = currentDefault[direction] else { return nil }
        return AudioHAL.volume(id, direction)
    }

    func setVolume(_ value: Float, _ direction: Direction) {
        guard let id = currentDefault[direction] else { return }
        AudioHAL.setVolume(id, direction, value)
    }

    // MARK: Akcje użytkownika

    /// Przenosi urządzenie na górę listy i włącza je (wybór z menu).
    func makeTopPriority(_ uid: String, _ direction: Direction) {
        var list = settings.priority(direction)
        guard let index = list.firstIndex(where: { $0.uid == uid }) else { return }
        var item = list.remove(at: index)
        item.isEnabled = true
        list.insert(item, at: 0)
        settings.setPriority(list, for: direction)
        backoffUntil[direction] = nil
        log(direction, "Ustawiono jako ulubione: \(item.name)")
    }

    func move(_ direction: Direction, from source: IndexSet, to destination: Int) {
        var list = settings.priority(direction)
        list.move(fromOffsets: source, toOffset: destination)
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

    func forget(_ uid: String, _ direction: Direction) {
        var list = settings.priority(direction)
        list.removeAll { $0.uid == uid }
        settings.setPriority(list, for: direction)
    }

    func clearActivity() { activity.removeAll() }

    // MARK: Logika

    private func handleHALChange(_ selector: AudioObjectPropertySelector) {
        refreshDefaults()
        // Zmiana listy urządzeń: daj systemowi chwilę, Bluetooth zgłasza się kilkoma zdarzeniami.
        if selector == kAudioHardwarePropertyDevices {
            scheduleReconcile(delay: .milliseconds(300))
            scheduleWatchWindow()
        } else {
            scheduleReconcile(delay: .milliseconds(150))
        }
    }

    /// Po podłączeniu/odłączeniu macOS często przełącza urządzenie z opóźnieniem — sprawdzamy kilka razy.
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    private func scheduleWatchWindow() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var elapsed = Duration.zero
            for checkpoint in [Duration.milliseconds(800), .milliseconds(1600), .seconds(3), .seconds(5)] {
                try? await Task.sleep(for: checkpoint - elapsed)
                elapsed = checkpoint
                guard !Task.isCancelled else { return }
                self?.reconcile()
            }
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

    private func refreshDefaults() {
        for direction in Direction.allCases {
            currentDefault[direction] = AudioHAL.defaultDeviceID(direction)
        }
    }

    private func refreshDevices() {
        for direction in Direction.allCases {
            let list = AudioHAL.devices(direction)
            connected[direction] = list
            register(list, direction)
        }
        refreshDefaults()
    }

    /// Dopisuje nowe urządzenia do listy i aktualizuje dane znanych.
    private func register(_ devices: [AudioDevice], _ direction: Direction) {
        var list = settings.priority(direction)
        var changed = false
        let connectedUIDs = Set(devices.map(\.uid))

        for device in devices {
            if let index = list.firstIndex(where: { $0.uid == device.uid }) {
                if list[index].name != device.name || list[index].transport != device.transport
                    || Date().timeIntervalSince(list[index].lastSeen) > 3600 {
                    list[index].name = device.name
                    list[index].transport = device.transport
                    list[index].lastSeen = Date()
                    changed = true
                }
            } else if let index = list.firstIndex(where: {
                // To samo urządzenie USB w innym porcie dostaje nowy UID — dopasuj po modelu i nazwie.
                !connectedUIDs.contains($0.uid) && $0.modelUID != nil
                    && $0.modelUID == device.modelUID && $0.name == device.name
            }) {
                list[index].uid = device.uid
                list[index].lastSeen = Date()
                changed = true
            } else {
                list.append(KnownDevice(
                    uid: device.uid,
                    name: device.name,
                    modelUID: device.modelUID,
                    transport: device.transport,
                    isEnabled: Self.enabledByDefault(device),
                    lastSeen: Date()
                ))
                changed = true
                if settings.didRunOnboarding {
                    log(direction, "Nowe urządzenie: \(device.name)")
                }
            }
        }
        if changed { settings.setPriority(list, for: direction) }
    }

    /// Mikrofony Bluetooth (np. AirPods) i iPhone'a to typowi „porywacze” wejścia — domyślnie wyłączone.
    private static func enabledByDefault(_ device: AudioDevice) -> Bool {
        guard device.direction == .input else { return true }
        return !(device.transport.isBluetooth || device.transport.isContinuity)
    }

    /// Przy pierwszym uruchomieniu: obecne urządzenie domyślne na górę listy.
    private func seedInitialPriorities() {
        for direction in Direction.allCases {
            // Włączone przed wyłączonymi; wbudowane na końcu włączonych.
            var list = settings.priority(direction).enumerated().sorted { a, b in
                func weight(_ d: KnownDevice) -> Int {
                    if !d.isEnabled { return 2 }
                    return d.transport == kAudioDeviceTransportTypeBuiltIn ? 1 : 0
                }
                return (weight(a.element), a.offset) < (weight(b.element), b.offset)
            }.map(\.element)
            // Obecne domyślne na górę — chyba że to „porywacz” (np. mikrofon AirPods, który system właśnie wybrał sam).
            if let current = currentDefault[direction],
               let device = devices(direction).first(where: { $0.objectID == current }),
               Self.enabledByDefault(device),
               let index = list.firstIndex(where: { $0.uid == device.uid }) {
                list.insert(list.remove(at: index), at: 0)
            }
            settings.setPriority(list, for: direction)
        }
        settings.didRunOnboarding = true
    }

    func reconcile() {
        refreshDevices()
        guard settings.isActive else { return }
        for direction in Direction.allCases where settings.enforces(direction) {
            enforce(direction)
        }
    }

    private func enforce(_ direction: Direction) {
        guard let target = preferredDevice(direction) else { return }

        if direction == .output, settings.alertSoundsFollowOutput,
           AudioHAL.systemOutputDeviceID() != target.objectID,
           AudioHAL.canBeSystemOutput(target.objectID) {
            AudioHAL.setDefault(target.objectID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }

        guard currentDefault[direction] != target.objectID else { return }

        if let until = backoffUntil[direction], until > Date() { return }

        // Ograniczenie: maks. 6 korekt w ciągu 20 s, potem 30 s przerwy (nie walczymy z systemem w kółko).
        let now = Date()
        var recent = (corrections[direction] ?? []).filter { now.timeIntervalSince($0) < 20 }
        guard recent.count < 6 else {
            backoffUntil[direction] = now.addingTimeInterval(30)
            log(direction, "System ciągle przełącza urządzenie — wstrzymuję korekty na 30 s")
            return
        }

        let previous = defaultDevice(direction)?.name ?? "inne urządzenie"
        guard AudioHAL.setDefault(target.objectID, for: direction) else {
            log(direction, "Nie udało się ustawić: \(target.name)")
            return
        }
        recent.append(now)
        corrections[direction] = recent
        currentDefault[direction] = target.objectID
        correctionCount += 1

        let message = "\(previous) → \(target.name)"
        log(direction, message)
        onCorrection?(direction, message)
        flash()
        scheduleVerification(direction)
    }

    /// System potrafi przełączyć urządzenie ponownie po negocjacji Bluetooth — sprawdzamy jeszcze dwa razy.
    private func scheduleVerification(_ direction: Direction) {
        verifyTasks[direction]?.cancel()
        verifyTasks[direction] = Task { [weak self] in
            for delay in [Duration.seconds(1), .seconds(3)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.refreshDefaults()
                if self.settings.isActive, self.settings.enforces(direction) {
                    self.enforce(direction)
                }
            }
        }
    }

    private(set) var isFlashing = false
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    private func flash() {
        isFlashing = true
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.isFlashing = false
        }
    }

    private func log(_ direction: Direction, _ message: String) {
        activity.insert(ActivityEntry(date: Date(), direction: direction, message: message), at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}
