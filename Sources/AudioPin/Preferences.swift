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

/// Per-app audio rule: where one app plays and how loud. Identified by bundle ID, so it survives relaunches.
struct AppRule: Codable, Identifiable, Hashable, Sendable {
    var bundleID: String
    /// Display cache, sanitized like device names.
    var appName: String
    /// `nil` = follow the system default.
    var deviceUID: String?
    /// Display cache while the device is disconnected.
    var deviceName: String?
    /// Slider position 0...1; the applied gain is `volume²` (see `AppAudioPolicy.gain`).
    var volume: Float = 1
    var isMuted = false
    var isEnabled = true

    var id: String { bundleID }

    /// Plain macOS behavior: the rule is deleted instead of stored.
    var isNeutral: Bool { deviceUID == nil && volume >= 1 && !isMuted }

    static let maxBundleIDLength = 255

    /// Bundle IDs are reverse-DNS: ASCII letters, digits, `.` and `-` (`^[A-Za-z0-9.-]+$`).
    static func isValidBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maxBundleIDLength
            && value.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                    || byte == 0x2E || byte == 0x2D
            }
    }

    static func clampedVolume(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 1
    }

    /// App names come from the app bundle; strip spoofing characters like device names do.
    /// Falls back to the bundle ID when nothing printable is left.
    static func sanitizedAppName(_ raw: String?, bundleID: String) -> String {
        AudioHAL.sanitizedNameIfAny(raw) ?? bundleID
    }

    /// One rule per bundle ID (the first wins) and no neutral rules.
    static func normalized(_ rules: [AppRule]) -> [AppRule] {
        var seen = Set<String>()
        return rules.filter { !$0.isNeutral && seen.insert($0.bundleID).inserted }
    }
}

extension AppRule {
    struct InvalidBundleID: Error {}

    /// Every field but the bundle ID is optional, so a future field never drops existing rules.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bundleID = try c.decode(String.self, forKey: .bundleID)
        guard Self.isValidBundleID(bundleID) else { throw InvalidBundleID() }
        self.bundleID = bundleID
        appName = Self.sanitizedAppName(try c.decodeIfPresent(String.self, forKey: .appName), bundleID: bundleID)
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID).flatMap { $0.isEmpty ? nil : $0 }
        deviceName = AudioHAL.sanitizedNameIfAny(try c.decodeIfPresent(String.self, forKey: .deviceName))
        volume = Self.clampedVolume(try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1)
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// Decodes one array element without failing the array: an unreadable rule is dropped, never the settings.
private struct LossyAppRule: Decodable {
    let rule: AppRule?

    init(from decoder: any Decoder) throws { rule = try? AppRule(from: decoder) }
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
    /// Per-app output device and volume rules. Never contains neutral rules or duplicate bundle IDs.
    var appRules: [AppRule] = []
    var showAppsInMenu = true

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
        // A malformed rule list must never cost the user their priority lists: drop it instead of throwing.
        let rules = try? c.decodeIfPresent([LossyAppRule].self, forKey: .appRules)
        appRules = rules.map { AppRule.normalized($0.compactMap(\.rule)) } ?? d.appRules
        showAppsInMenu = (try? c.decodeIfPresent(Bool.self, forKey: .showAppsInMenu)) ?? d.showAppsInMenu
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
