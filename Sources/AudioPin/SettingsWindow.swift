import AppKit
import SwiftUI

/// Settings window: general options, output and input priorities, activity log.
struct SettingsWindow: View {
    static let id = "settings"

    enum Pane: String, CaseIterable, Identifiable {
        case general, output, input, activity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .output: String(localized: "Output")
            case .input: String(localized: "Input")
            case .activity: String(localized: "Activity")
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .output: "speaker.wave.2.fill"
            case .input: "mic.fill"
            case .activity: "clock.arrow.circlepath"
            }
        }
    }

    @State private var pane: Pane = PreviewMode.initialPane.flatMap(Pane.init(rawValue:)) ?? .output

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .output: PriorityPane(direction: .output)
                case .input: PriorityPane(direction: .input)
                case .activity: ActivityPane()
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(width: 720, height: 520)
        .onAppear { AppActivation.showWindow() }
        .onDisappear { AppActivation.windowClosed() }
    }
}

// MARK: General

private struct GeneralPane: View {
    @Environment(AudioManager.self) private var manager
    @Environment(LoginItem.self) private var loginItem
    @State private var notificationsDenied = false

    var body: some View {
        @Bindable var manager = manager
        Form {
            Section {
                Toggle("Pin audio devices", isOn: $manager.settings.isActive)
                Toggle("Pin output (speakers, headphones)", isOn: $manager.settings.enforceOutput)
                    .disabled(!manager.settings.isActive)
                Toggle("Pin input (microphones)", isOn: $manager.settings.enforceInput)
                    .disabled(!manager.settings.isActive)
            } header: {
                Text("Behavior")
            } footer: {
                Text("When macOS switches a device (for example after you connect AirPods), AudioPin immediately restores the first connected, enabled device from your list.")
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { loginItem.isEnabled || loginItem.needsApproval },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.needsApproval {
                    HStack {
                        Text("macOS needs your approval in System Settings.")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Details") {
                Toggle("Alert sounds follow the selected output", isOn: $manager.settings.alertSoundsFollowOutput)
                Toggle("Notify on every correction", isOn: $manager.settings.notifyOnCorrection)
                    .onChange(of: manager.settings.notifyOnCorrection) { _, on in
                        guard on else { return }
                        Task {
                            if await !Notifier.shared.requestAuthorization() {
                                manager.settings.notifyOnCorrection = false
                                notificationsDenied = true
                            }
                        }
                    }
                if notificationsDenied {
                    Text("Notifications are turned off. Allow them in System Settings → Notifications.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show microphone name in the menu bar", isOn: $manager.settings.showNameInMenuBar)
            }

            Section {
                HStack {
                    Button("macOS Sound Settings…") {
                        open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
                    }
                    Button("Bluetooth Settings…") {
                        open("x-apple.systempreferences:com.apple.BluetoothSettings")
                    }
                }
            } footer: {
                Text("Tip: in Zoom, Teams or Discord choose “Same as System” for the microphone and speaker, so these apps follow AudioPin too.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

// MARK: Priorities

private struct PriorityPane: View {
    @Environment(AudioManager.self) private var manager
    let direction: Direction

    private var list: [KnownDevice] { manager.settings.priority(direction) }
    private var inactive: [KnownDevice] { list.filter { !manager.isConnected($0.uid, direction) } }

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, device in
                        PriorityRow(device: device, rank: index + 1, direction: direction)
                    }
                    .onMove { manager.move(direction, from: $0, to: $1) }
                }
                .frame(minHeight: CGFloat(max(list.count, 1)) * 52)
            } header: {
                Text(direction == .input ? String(localized: "Microphone Priority") : String(localized: "Output Priority"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag to reorder. The first connected, enabled device is used. Disabled devices are never selected automatically.")
                    if direction == .input {
                        Text("New Bluetooth microphones (such as AirPods) and iPhone microphones start disabled.")
                    }
                }
                .foregroundStyle(.secondary)
            }

            if !inactive.isEmpty {
                Section {
                    Button("Forget All Disconnected (\(inactive.count))", role: .destructive) {
                        manager.forget(Set(inactive.map(\.uid)), direction)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PriorityRow: View {
    @Environment(AudioManager.self) private var manager
    let device: KnownDevice
    let rank: Int
    let direction: Direction

    private var connected: Bool { manager.isConnected(device.uid, direction) }
    private var isCurrent: Bool { manager.defaultDevice(direction)?.uid == device.uid }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
            Text(rank, format: .number)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Image(systemName: DeviceStyle.symbol(name: device.name, transport: device.transport, direction: direction))
                .font(.title3)
                .frame(width: 34, height: 34)
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.15), in: .circle)
                .opacity(connected ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).fontWeight(.medium)
                        .strikethrough(!device.isEnabled, color: .secondary)
                    if isCurrent {
                        Text("IN USE")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: .capsule)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .opacity(connected ? 1 : 0.6)
            Spacer()
            Toggle("Automatic selection", isOn: Binding(
                get: { device.isEnabled },
                set: { manager.setEnabled($0, uid: device.uid, direction) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(device.isEnabled
                ? String(localized: "Turn off to never select automatically")
                : String(localized: "Include in Automatic Selection"))
            Menu {
                Button("Make Favorite") { manager.makeTopPriority(device.uid, direction) }
                Button("Move Up") { manager.move(device.uid, direction, by: -1) }
                Button("Move Down") { manager.move(device.uid, direction, by: 1) }
                Divider()
                Button("Forget Device", role: .destructive) { manager.forget([device.uid], direction) }
                    .disabled(connected)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More Options")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        var parts = [DeviceStyle.transportName(device.transport)]
        if !device.isEnabled { parts.append(String(localized: "disabled")) }
        parts.append(connected ? String(localized: "connected") : DeviceStyle.lastSeen(device.lastSeen))
        return parts.joined(separator: " · ")
    }
}

// MARK: Activity

private struct ActivityPane: View {
    @Environment(AudioManager.self) private var manager

    var body: some View {
        Form {
            Section {
                if manager.activity.isEmpty {
                    Text("All quiet — AudioPin hasn’t had to correct anything yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(manager.activity) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.direction.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(entry.message)
                        Spacer()
                        Text(entry.date, style: .time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("Recent Activity")
                    Spacer()
                    if !manager.activity.isEmpty {
                        Button("Clear") { manager.clearActivity() }.buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
