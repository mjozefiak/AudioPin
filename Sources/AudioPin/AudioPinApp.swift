import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = AudioManager()
    let loginItem = LoginItem()
    private var observers: [any NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one instance at a time.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Notifier.shared.setUp()
        manager.onCorrection = { [weak self] direction, message in
            guard let self, self.manager.settings.notifyOnCorrection else { return }
            Notifier.shared.post(direction, message)
        }
        manager.start()
        observeWorkspace()
        loginItem.refresh()
        #if DEBUG
        if PreviewMode.isEnabled { PreviewMode.scheduleSnapshot() }
        #endif
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, @MainActor (AudioManager) -> Void)] = [
            (NSWorkspace.didWakeNotification, { $0.systemDidWake() }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.setSuspended(true) }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.setSuspended(false) }),
        ]
        observers = events.map { name, action in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self.manager)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AudioPinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(delegate.manager)
                .environment(delegate.loginItem)
        } label: {
            MenuBarLabel()
                .environment(delegate.manager)
        }
        .menuBarExtraStyle(.window)

        Window("AudioPin Settings", id: SettingsWindow.id) {
            SettingsWindow()
                .environment(delegate.manager)
                .environment(delegate.loginItem)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(PreviewMode.isEnabled ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        #if DEBUG
        Window("Menu Preview", id: "menu-preview") {
            MenuBarView()
                .environment(delegate.manager)
                .environment(delegate.loginItem)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(PreviewMode.isEnabled ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        #endif
    }
}

/// Shows a check mark in the menu bar for a moment after each correction.
struct MenuBarLabel: View {
    @Environment(AudioManager.self) private var manager

    var body: some View {
        let symbol = !manager.settings.isActive ? "pin.slash"
            : manager.isFlashing ? "checkmark.circle.fill" : "pin.fill"
        if manager.settings.showNameInMenuBar, let name = manager.defaultDevice(.input)?.name {
            Label(name, systemImage: symbol).labelStyle(.titleAndIcon)
        } else {
            Image(systemName: symbol)
                .accessibilityLabel("AudioPin")
        }
    }
}
