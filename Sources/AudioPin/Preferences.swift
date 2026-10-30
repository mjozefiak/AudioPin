import CoreAudio
import Foundation

/// Urządzenie zapamiętane na liście priorytetów (także gdy jest odłączone).
struct KnownDevice: Codable, Identifiable, Hashable, Sendable {
    var uid: String
    var name: String
    var modelUID: String?
    var transport: UInt32
    var isEnabled: Bool
    var lastSeen: Date

    var id: String { uid }
}

/// Ustawienia aplikacji zapisywane jako JSON w UserDefaults.
struct AppSettings: Codable, Equatable, Sendable {
    var isActive = true
    var enforceInput = true
    var enforceOutput = true
    var alertSoundsFollowOutput = true
    var notifyOnCorrection = false
    var showNameInMenuBar = false
    var inputPriority: [KnownDevice] = []
    var outputPriority: [KnownDevice] = []
    var didRunOnboarding = false

    func priority(_ direction: Direction) -> [KnownDevice] {
        direction == .input ? inputPriority : outputPriority
    }

    mutating func setPriority(_ list: [KnownDevice], for direction: Direction) {
        if direction == .input { inputPriority = list } else { outputPriority = list }
    }

    func enforces(_ direction: Direction) -> Bool {
        direction == .input ? enforceInput : enforceOutput
    }

    private static let key = "AudioPin.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension UInt32 {
    /// Czy transport to Bluetooth (klasyczny lub LE).
    var isBluetooth: Bool {
        self == kAudioDeviceTransportTypeBluetooth || self == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Mikrofon iPhone'a przez Continuity.
    var isContinuity: Bool {
        self == kAudioDeviceTransportTypeContinuityCaptureWired
            || self == kAudioDeviceTransportTypeContinuityCaptureWireless
    }
}
