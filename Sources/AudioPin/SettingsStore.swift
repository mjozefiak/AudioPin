import Foundation
import os

/// Where `AppSettings` are persisted. Abstracted so tests can use an in-memory store.
@MainActor
protocol SettingsStore {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// Stores settings as JSON in `UserDefaults`.
@MainActor
struct UserDefaultsSettingsStore: SettingsStore {
    var defaults: UserDefaults = .standard
    var key = "AudioPin.settings.v1"

    private static let logger = Logger(subsystem: "dev.mjozefiak.AudioPin", category: "settings")

    var backupKey: String { key + ".backup" }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Never silently overwrite data we could not read: keep a copy for recovery.
            Self.logger.error("Could not decode settings, keeping a backup: \(error.localizedDescription, privacy: .public)")
            defaults.set(data, forKey: backupKey)
            return AppSettings()
        }
    }

    func save(_ settings: AppSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: key)
        } catch {
            Self.logger.error("Could not encode settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
