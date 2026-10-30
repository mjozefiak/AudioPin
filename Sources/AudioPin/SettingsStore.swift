import Foundation

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

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
