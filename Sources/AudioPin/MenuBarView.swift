import AppKit
import SwiftUI

/// Okienko otwierane z ikony w pasku menu.
struct MenuBarView: View {
    @Environment(AudioManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
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
            Image(systemName: manager.settings.isActive ? "pin.fill" : "pin.slash")
                .font(.title3)
                .foregroundStyle(manager.settings.isActive ? Color.accentColor : .secondary)
                .frame(width: 32, height: 32)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text("AudioPin").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Aktywny", isOn: $manager.settings.isActive)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(manager.settings.isActive ? "Wstrzymaj pilnowanie urządzeń" : "Wznów pilnowanie urządzeń")
        }
        .padding(.horizontal, 4)
    }

    private var statusText: String {
        guard manager.settings.isActive else { return "Wstrzymany — system wybiera sam" }
        switch manager.correctionCount {
        case 0: return "Pilnuje Twoich urządzeń"
        case 1: return "Pilnuje · 1 korekta w tej sesji"
        default: return "Pilnuje · korekty w tej sesji: \(manager.correctionCount)"
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                openWindow(id: SettingsWindow.id)
                AppActivation.showWindow()
            } label: {
                Label("Ustawienia…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            Spacer()
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Otwórz ustawienia dźwięku macOS")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Zakończ AudioPin")
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
    }
}

/// Sekcja jednego kierunku: aktualne urządzenie, głośność i podłączone urządzenia wg priorytetu.
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
                    Text("bez pilnowania").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 6)

            VStack(spacing: 2) {
                if rows.isEmpty {
                    Text("Brak podłączonych urządzeń")
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
                    Image(systemName: "nosign").foregroundStyle(.secondary).help("Wyłączone z automatycznego wyboru")
                } else if isCurrent {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Kliknij, aby ustawić jako ulubione (pierwsze na liście)")
        .contextMenu {
            Button("Ustaw jako ulubione") { manager.makeTopPriority(device.uid, direction) }
            Button("Przesuń wyżej") { manager.move(device.uid, direction, by: -1) }
            Button("Przesuń niżej") { manager.move(device.uid, direction, by: 1) }
            Divider()
            Button(device.isEnabled ? "Wyłącz z automatycznego wyboru" : "Włącz automatyczny wybór") {
                manager.setEnabled(!device.isEnabled, uid: device.uid, direction)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let rank { parts.append("#\(rank)") }
        parts.append(DeviceStyle.transportName(device.transport))
        if !device.isEnabled { parts.append("wyłączone") } else if isCurrent { parts.append("w użyciu") }
        return parts.joined(separator: " · ")
    }
}
