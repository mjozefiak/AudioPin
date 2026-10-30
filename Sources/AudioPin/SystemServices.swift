import AppKit
import ServiceManagement
import UserNotifications

/// Uruchamianie przy logowaniu (SMAppService). Stan zawsze czytamy z systemu.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                // Po przebudowaniu aplikacji podpis się zmienia — rejestrujemy od nowa.
                if status == .enabled { try? SMAppService.mainApp.unregister() }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Przy starcie: jeśli autostart był włączony, odśwież rejestrację (ścieżka/podpis mogły się zmienić).
    func ensureRegisteredIfWanted() {
        refresh()
        if UserDefaults.standard.object(forKey: "AudioPin.launchAtLoginWanted") == nil {
            // Pierwsze uruchomienie: włącz autostart domyślnie.
            UserDefaults.standard.set(true, forKey: "AudioPin.launchAtLoginWanted")
            setEnabled(true)
        }
    }

    func setWanted(_ wanted: Bool) {
        UserDefaults.standard.set(wanted, forKey: "AudioPin.launchAtLoginWanted")
        setEnabled(wanted)
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Powiadomienia o korektach (opcjonalne).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setUp() { UNUserNotificationCenter.current().delegate = self }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(_ direction: Direction, _ message: String) {
        let content = UNMutableNotificationContent()
        content.title = direction == .input ? "Przywrócono mikrofon" : "Przywrócono wyjście dźwięku"
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

/// Aplikacja żyje w pasku menu; na czas otwartego okna ustawień pokazujemy ją w Docku,
/// żeby okno zawsze wychodziło na wierzch.
@MainActor
enum AppActivation {
    static func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.contains(SettingsWindow.id) == true }?
                .makeKeyAndOrderFront(nil)
        }
    }

    static func windowClosed() {
        NSApp.setActivationPolicy(.accessory)
    }
}
