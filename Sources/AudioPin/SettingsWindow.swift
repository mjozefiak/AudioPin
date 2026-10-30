import AppKit
import SwiftUI

/// Okno ustawień: ogólne, priorytety wyjścia, priorytety wejścia, historia.
struct SettingsWindow: View {
    static let id = "settings"

    enum Pane: String, CaseIterable, Identifiable {
        case general, output, input, activity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "Ogólne"
            case .output: "Wyjście"
            case .input: "Wejście"
            case .activity: "Historia"
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

    @State private var pane: Pane = CommandLine.arguments
        .first { $0.hasPrefix("--pane=") }
        .flatMap { Pane(rawValue: String($0.dropFirst(7))) } ?? .output

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

// MARK: Ogólne

private struct GeneralPane: View {
    @Environment(AudioManager.self) private var manager
    @Environment(LoginItem.self) private var loginItem

    var body: some View {
        @Bindable var manager = manager
        Form {
            Section {
                Toggle("Pilnuj urządzeń audio", isOn: $manager.settings.isActive)
                Toggle("Pilnuj wyjścia (głośniki, słuchawki)", isOn: $manager.settings.enforceOutput)
                    .disabled(!manager.settings.isActive)
                Toggle("Pilnuj wejścia (mikrofony)", isOn: $manager.settings.enforceInput)
                    .disabled(!manager.settings.isActive)
            } header: {
                Text("Działanie")
            } footer: {
                Text("Gdy macOS przełączy urządzenie (np. po podłączeniu AirPods), AudioPin od razu przywróci pierwsze dostępne i włączone urządzenie z Twojej listy.")
                    .foregroundStyle(.secondary)
            }

            Section("Uruchamianie") {
                Toggle("Uruchamiaj po zalogowaniu", isOn: Binding(
                    get: { loginItem.isEnabled || loginItem.needsApproval },
                    set: { loginItem.setWanted($0) }
                ))
                if loginItem.needsApproval {
                    HStack {
                        Text("macOS wymaga zatwierdzenia w Ustawieniach systemowych.")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Otwórz") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Szczegóły") {
                Toggle("Dźwięki systemowe idą za wybranym wyjściem", isOn: $manager.settings.alertSoundsFollowOutput)
                Toggle("Powiadomienie przy każdej korekcie", isOn: $manager.settings.notifyOnCorrection)
                    .onChange(of: manager.settings.notifyOnCorrection) { _, on in
                        if on { Notifier.shared.requestAuthorization() }
                    }
                Toggle("Pokazuj nazwę mikrofonu w pasku menu", isOn: $manager.settings.showNameInMenuBar)
            }

            Section {
                HStack {
                    Button("Ustawienia dźwięku macOS…") {
                        open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
                    }
                    Button("Ustawienia Bluetooth…") {
                        open("x-apple.systempreferences:com.apple.BluetoothSettings")
                    }
                }
            } footer: {
                Text("Wskazówka: w Zoom, Teams czy Discord wybierz mikrofon „Taki jak systemowy”, żeby te aplikacje też korzystały z urządzeń wybranych przez AudioPin.")
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

// MARK: Priorytety

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
                Text("Kolejność \(direction == .input ? "mikrofonów" : "wyjść dźwięku")")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Przeciągnij, aby zmienić kolejność. Używane jest pierwsze podłączone i włączone urządzenie. Wyłączone urządzenia nigdy nie są wybierane automatycznie.")
                    if direction == .input {
                        Text("Nowe mikrofony Bluetooth (np. AirPods) i iPhone'a są domyślnie wyłączone.")
                    }
                }
                .foregroundStyle(.secondary)
            }

            if !inactive.isEmpty {
                Section {
                    Button("Zapomnij wszystkie odłączone (\(inactive.count))", role: .destructive) {
                        inactive.forEach { manager.forget($0.uid, direction) }
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
                .help("Przeciągnij, aby zmienić kolejność")
            Text("\(rank)")
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
                        Text("W UŻYCIU")
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
            Toggle("Automatyczny wybór", isOn: Binding(
                get: { device.isEnabled },
                set: { manager.setEnabled($0, uid: device.uid, direction) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(device.isEnabled ? "Wyłącz — nigdy nie wybieraj automatycznie" : "Włącz automatyczny wybór")
            Menu {
                Button("Ustaw jako ulubione") { manager.makeTopPriority(device.uid, direction) }
                Button("Przesuń wyżej") { manager.move(device.uid, direction, by: -1) }
                Button("Przesuń niżej") { manager.move(device.uid, direction, by: 1) }
                Divider()
                Button("Zapomnij urządzenie", role: .destructive) { manager.forget(device.uid, direction) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        var parts = [DeviceStyle.transportName(device.transport)]
        if !device.isEnabled { parts.append("wyłączone") }
        parts.append(connected ? "podłączone" : DeviceStyle.lastSeen(device.lastSeen))
        return parts.joined(separator: " · ")
    }
}

// MARK: Historia

private struct ActivityPane: View {
    @Environment(AudioManager.self) private var manager

    var body: some View {
        Form {
            Section {
                if manager.activity.isEmpty {
                    Text("Na razie spokojnie — AudioPin nie musiał niczego poprawiać.")
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
                    Text("Ostatnie zdarzenia")
                    Spacer()
                    if !manager.activity.isEmpty {
                        Button("Wyczyść") { manager.clearActivity() }.buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
