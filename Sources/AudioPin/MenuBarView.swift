import AppKit
import SwiftUI

/// Popover shown from the menu bar icon.
struct MenuBarView: View {
    @Environment(AudioManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(LoginItem.self) private var loginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !manager.settings.didOfferLaunchAtLogin && !loginItem.isEnabled {
                LaunchAtLoginOffer()
            }
            DirectionSection(direction: .output)
            DirectionSection(direction: .input)
            Divider().padding(.horizontal, 4)
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        @Bindable var manager = manager
        return HStack(spacing: 10) {
            Image(nsImage: manager.settings.isActive ? BrandMark.active : BrandMark.paused)
                .renderingMode(.template)
                .foregroundStyle(manager.settings.isActive ? Color.accentColor : .secondary)
                .frame(width: 32, height: 32)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text("AudioPin").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Active", isOn: $manager.settings.isActive)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(manager.settings.isActive ? String(localized: "Pause AudioPin") : String(localized: "Resume AudioPin"))
        }
        .padding(.horizontal, 4)
    }

    private var statusText: String {
        guard manager.settings.isActive else { return String(localized: "Paused — macOS chooses devices") }
        switch manager.correctionCount {
        case 0: return String(localized: "Keeping your devices pinned")
        case 1: return String(localized: "Pinned · 1 correction this session")
        default: return String(localized: "Pinned · \(manager.correctionCount) corrections this session")
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                openWindow(id: SettingsWindow.id)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            Spacer()
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .accessibilityLabel("macOS Sound Settings")
            }
            .help("Open macOS Sound Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .accessibilityLabel("Quit AudioPin")
            }
            .help("Quit AudioPin")
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
    }
}

/// One direction: connected devices in priority order and the volume of the current one.
private struct DirectionSection: View {
    @Environment(AudioManager.self) private var manager
    let direction: Direction
    @State private var volume: Float = 0
    @State private var hasVolume = false

    private var rows: [KnownDevice] {
        manager.settings.priority(direction).filter { manager.isConnected($0.uid, direction) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(direction.longTitle, systemImage: direction.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !manager.settings.enforces(direction) {
                    Text("not pinned").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 6)

            VStack(spacing: 2) {
                if rows.isEmpty {
                    Text("No connected devices")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                ForEach(rows) { device in
                    DeviceRow(device: device, direction: direction)
                }
                if hasVolume {
                    HStack(spacing: 8) {
                        Image(systemName: direction == .input ? "mic" : "speaker.fill")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                        Slider(value: Binding(
                            get: { Double(volume) },
                            set: { volume = Float($0); manager.setVolume(Float($0), direction) }
                        ), in: 0...1)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(4)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        }
        .onAppear(perform: loadVolume)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in loadVolume() }
        .onChange(of: manager.currentDefault[direction]) { loadVolume() }
    }

    private func loadVolume() {
        if let value = manager.volume(direction) {
            volume = value
            hasVolume = true
        } else {
            hasVolume = false
        }
    }
}

private struct DeviceRow: View {
    @Environment(AudioManager.self) private var manager
    let device: KnownDevice
    let direction: Direction
    @State private var hovering = false

    private var isCurrent: Bool { manager.defaultDevice(direction)?.uid == device.uid }
    private var rank: Int? {
        manager.settings.priority(direction).firstIndex(where: { $0.uid == device.uid }).map { $0 + 1 }
    }

    var body: some View {
        Button {
            manager.makeTopPriority(device.uid, direction)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: DeviceStyle.symbol(name: device.name, transport: device.transport, direction: direction))
                    .font(.body)
                    .frame(width: 26, height: 26)
                    .foregroundStyle(isCurrent ? Color.white : device.isEnabled ? Color.primary : Color.secondary)
                    .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.15), in: .circle)
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.name)
                        .lineLimit(1)
                        .foregroundStyle(device.isEnabled ? .primary : .secondary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !device.isEnabled {
                    Image(systemName: "nosign").foregroundStyle(.secondary)
                        .help("Excluded from automatic selection")
                        .accessibilityLabel("Excluded from automatic selection")
                } else if isCurrent {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                        .accessibilityLabel("In use")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to make this your favorite (first in the list)")
        .contextMenu {
            Button("Make Favorite") { manager.makeTopPriority(device.uid, direction) }
            Button("Move Up") { manager.move(device.uid, direction, by: -1) }
            Button("Move Down") { manager.move(device.uid, direction, by: 1) }
            Divider()
            Button(device.isEnabled
                ? String(localized: "Exclude from Automatic Selection")
                : String(localized: "Include in Automatic Selection")) {
                manager.setEnabled(!device.isEnabled, uid: device.uid, direction)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let rank { parts.append("#\(rank)") }
        parts.append(DeviceStyle.transportName(device.transport))
        if !device.isEnabled {
            parts.append(String(localized: "disabled"))
        } else if isCurrent {
            parts.append(String(localized: "in use"))
        }
        return parts.joined(separator: " · ")
    }
}

/// One-time question shown in the popover: launch at login is opt-in.
private struct LaunchAtLoginOffer: View {
    @Environment(AudioManager.self) private var manager
    @Environment(LoginItem.self) private var loginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Open AudioPin at login?", systemImage: "power.circle")
                .font(.callout.weight(.medium))
            Text("Otherwise your devices are only pinned after you open the app yourself.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Not Now") { manager.settings.didOfferLaunchAtLogin = true }
                Spacer()
                Button("Turn On") {
                    loginItem.setEnabled(true)
                    manager.settings.didOfferLaunchAtLogin = true
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}
