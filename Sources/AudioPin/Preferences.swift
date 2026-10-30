import CoreAudio
import Foundation

/// A device remembered in a priority list (also while disconnected).
struct KnownDevice: Codable, Identifiable, Hashable, Sendable {
    var uid: String
    var name: String
    var modelUID: String?
    var transport: UInt32
    var isEnabled: Bool
    var lastSeen: Date

    var id: String { uid }
}

/// App settings, persisted as JSON by `SettingsStore`.
///
/// Decoding is tolerant: a missing key falls back to its default, so adding a new setting
/// in a future version never wipes the user's existing priority lists.
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
    var didOfferLaunchAtLogin = false

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? d.isActive
        enforceInput = try c.decodeIfPresent(Bool.self, forKey: .enforceInput) ?? d.enforceInput
        enforceOutput = try c.decodeIfPresent(Bool.self, forKey: .enforceOutput) ?? d.enforceOutput
        alertSoundsFollowOutput = try c.decodeIfPresent(Bool.self, forKey: .alertSoundsFollowOutput)
            ?? d.alertSoundsFollowOutput
        notifyOnCorrection = try c.decodeIfPresent(Bool.self, forKey: .notifyOnCorrection) ?? d.notifyOnCorrection
        showNameInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showNameInMenuBar) ?? d.showNameInMenuBar
        inputPriority = try c.decodeIfPresent([KnownDevice].self, forKey: .inputPriority) ?? d.inputPriority
        outputPriority = try c.decodeIfPresent([KnownDevice].self, forKey: .outputPriority) ?? d.outputPriority
        didRunOnboarding = try c.decodeIfPresent(Bool.self, forKey: .didRunOnboarding) ?? d.didRunOnboarding
        didOfferLaunchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .didOfferLaunchAtLogin)
            ?? d.didOfferLaunchAtLogin
    }

    func priority(_ direction: Direction) -> [KnownDevice] {
        direction == .input ? inputPriority : outputPriority
    }

    mutating func setPriority(_ list: [KnownDevice], for direction: Direction) {
        if direction == .input { inputPriority = list } else { outputPriority = list }
    }

    func enforces(_ direction: Direction) -> Bool {
        direction == .input ? enforceInput : enforceOutput
    }
}

extension UInt32 {
    /// Bluetooth Classic or Bluetooth LE.
    var isBluetooth: Bool {
        self == kAudioDeviceTransportTypeBluetooth || self == kAudioDeviceTransportTypeBluetoothLE
    }

    /// iPhone microphone via Continuity.
    var isContinuity: Bool {
        self == kAudioDeviceTransportTypeContinuityCaptureWired
            || self == kAudioDeviceTransportTypeContinuityCaptureWireless
    }
}
