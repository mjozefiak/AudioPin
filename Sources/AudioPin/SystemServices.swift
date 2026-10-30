import AppKit
import ServiceManagement
import UserNotifications

/// Launch at login via `SMAppService`. Opt-in only; the system status is the single source of truth.
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
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Optional notifications about corrections.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setUp() { UNUserNotificationCenter.current().delegate = self }

    /// Asks for permission and reports whether notifications may be shown.
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    func post(_ direction: Direction, _ message: String) {
        let content = UNMutableNotificationContent()
        content.title = direction == .input
            ? String(localized: "Microphone restored") : String(localized: "Sound output restored")
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

/// AudioPin lives in the menu bar. While the settings window is open it temporarily becomes
/// a regular app (Dock icon), otherwise macOS may open the window behind other apps.
@MainActor
enum AppActivation {
    static func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Task { @MainActor in
            // The window is created asynchronously by SwiftUI; bring it forward once it exists.
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue.contains(SettingsWindow.id) == true }?
                .makeKeyAndOrderFront(nil)
        }
    }

    static func windowClosed() {
        NSApp.setActivationPolicy(.accessory)
    }
}
