import AppKit

/// Development aid for checking the UI without clicking the menu bar.
///
/// Debug builds only: `AudioPin --preview [--pane=general|output|input|activity]` opens the settings
/// window and a copy of the menu bar popover. With `AUDIOPIN_SNAPSHOT_DIR` set, it also saves both
/// windows as PNG files. In release builds `isEnabled` is always false and nothing else is compiled.
enum PreviewMode {
    #if DEBUG
    static let isEnabled = CommandLine.arguments.contains("--preview")

    static var initialPane: String? {
        CommandLine.arguments.first { $0.hasPrefix("--pane=") }.map { String($0.dropFirst("--pane=".count)) }
    }

    @MainActor
    static func scheduleSnapshot() {
        guard let dir = ProcessInfo.processInfo.environment["AUDIOPIN_SNAPSHOT_DIR"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("window-\(index).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
    #else
    static let isEnabled = false
    static let initialPane: String? = nil
    #endif
}
