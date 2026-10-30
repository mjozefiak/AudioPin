import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = AudioManager()
    let loginItem = LoginItem()
    private var wakeObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tylko jedna instancja naraz.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Notifier.shared.setUp()
        manager.onCorrection = { [weak self] direction, message in
            guard let self else { return }
            if self.manager.settings.notifyOnCorrection { Notifier.shared.post(direction, message) }
        }
        manager.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.manager.systemDidWake() }
        }
        if AudioPinApp.previewMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Self.snapshotWindows() }
        }
        if Bundle.main.bundlePath.hasSuffix(".app") {
            loginItem.ensureRegisteredIfWanted()
        }
    }

    /// Tryb podglądu: zapisuje widoczne okna do PNG (folder z AUDIOPIN_SNAPSHOT_DIR).
    private static func snapshotWindows() {
        guard let dir = ProcessInfo.processInfo.environment["AUDIOPIN_SNAPSHOT_DIR"] else { return }
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window\(index)" : window.title
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
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

        Window("Ustawienia AudioPin", id: SettingsWindow.id) {
            SettingsWindow()
                .environment(delegate.manager)
                .environment(delegate.loginItem)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.previewMode ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        // Tryb podglądu (tylko do testów): `AudioPin --preview` pokazuje zawartość okienka z paska menu w oknie.
        Window("Podgląd menu", id: "menu-preview") {
            MenuBarView()
                .environment(delegate.manager)
                .environment(delegate.loginItem)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.previewMode ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }

    static let previewMode = CommandLine.arguments.contains("--preview")
}

/// Ikona w pasku menu; przez chwilę po korekcie pokazuje znacznik.
struct MenuBarLabel: View {
    @Environment(AudioManager.self) private var manager

    var body: some View {
        let symbol = !manager.settings.isActive ? "pin.slash"
            : manager.isFlashing ? "checkmark.circle.fill" : "pin.fill"
        if manager.settings.showNameInMenuBar, let name = manager.defaultDevice(.input)?.name {
            Label(name, systemImage: symbol).labelStyle(.titleAndIcon)
        } else {
            Image(systemName: symbol)
        }
    }
}
