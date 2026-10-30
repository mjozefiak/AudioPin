# AudioPin

**Pin your favorite microphone and speakers on macOS — and keep them pinned.**

AudioPin is a tiny, native menu bar app that stops macOS from hijacking your audio devices. Connect your AirPods and macOS switches the microphone to the AirPods mic; plug in a monitor and the sound jumps to its speakers. AudioPin notices it instantly and puts your preferred devices back.

![Platform](https://img.shields.io/badge/platform-macOS%2027-blue)
![Swift](https://img.shields.io/badge/Swift-6.4-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Why

macOS follows a simple rule: *the last connected device wins*. That is rarely what you want. A typical case:

- You use a good USB microphone for calls.
- You connect AirPods Max to listen.
- macOS switches the **input** to the AirPods mic as well. Your voice now sounds worse, and Bluetooth drops to the low-quality headset profile (HFP), so your music sounds worse too.

AudioPin fixes this once and for all: you choose the order of your devices, and the system sticks to it.

## Features

- **Priority lists, separately for input and output.** The first connected and enabled device in each list is always the system default.
- **Fallback.** If your favorite device is not connected, the next one on the list is used.
- **Disable devices.** Disabled devices are never selected automatically (for example, the AirPods microphone).
- **Sensible defaults.** New Bluetooth microphones (AirPods and other headsets) and iPhone Continuity microphones are disabled by default.
- **Instant correction.** AudioPin listens to Core Audio change notifications, with no polling. When macOS switches a device, AudioPin reverts it in a fraction of a second. After a device connects it re-checks several times over the next few seconds, because Bluetooth devices often trigger a second switch.
- **No endless fights.** If something keeps switching the device back, AudioPin backs off for 30 seconds instead of looping.
- **Remembers devices.** Disconnected devices keep their place in the list.
- **Menu bar quick access.**
  - See the active devices, change volume, and click a device to make it your favorite.
  - A single switch pauses AudioPin.
- **Optional extras.**
  - System alert sounds follow the selected output.
  - Notifications on every correction.
  - The microphone name shown in the menu bar.
- **Launch at login** (opt-in), runs in the background with no Dock icon.
- **Plays nice with fast user switching.** Enforcement pauses while another user's session is active.
- **No permissions needed.** AudioPin only reads and changes device settings. It never opens a microphone, so macOS does not ask for microphone access.

## Requirements

- macOS 27 or later (Apple silicon)
- Xcode 27 or later, to build from source

## Installation

AudioPin is distributed as source code. Building takes about a minute.

```bash
git clone https://github.com/mjozefiak/AudioPin.git
cd AudioPin
./scripts/install.sh
```

The script does three things:

1. Builds a release version with Swift Package Manager.
2. Assembles and ad-hoc signs `AudioPin.app`.
3. Copies it to `~/Applications` and launches it.

A pin icon appears in the menu bar. The first time you open it, AudioPin asks whether it should launch at login. You can change this any time in Settings.

To only build the app bundle without installing it, run `./scripts/build-app.sh`. The app is written to `dist/AudioPin.app`.

> **Note:** the app is ad-hoc signed, not notarized. Because you build it yourself on your own Mac, Gatekeeper does not block it. If you copy the built app to another Mac, right-click it and choose **Open** the first time.

### Uninstall

1. Quit AudioPin from its menu.
2. Delete `~/Applications/AudioPin.app`.
3. Optionally, remove its settings:

```bash
defaults delete dev.mjozefiak.AudioPin
```

## Usage

1. Click the pin icon in the menu bar.
   - The popover shows your connected outputs and inputs in priority order. A checkmark marks the device in use.
   - Click a device to make it your favorite, that is, the first on the list.
   - Right-click a device for more options: move it up or down, or disable it.
2. Open **Settings…** to manage the full lists.
   - Drag devices to reorder them.
   - Use the switch next to a device to disable it.
   - Forget devices you no longer own.
3. In apps like Zoom, Teams or Discord, set the microphone and speaker to **Same as System**. Then they follow AudioPin too.

## How it works

AudioPin talks directly to the Core Audio hardware abstraction layer (HAL):

1. **Listening.** It registers property listeners for the device list and for the default input, output and system output devices.
2. **Reconciling.** Every change triggers a short, debounced *reconcile* step:
   - Resolve each saved device by its stable Core Audio UID.
   - Pick the first connected, enabled device.
   - Set it as the default if it isn't already.
3. **Re-checking.** After a device connects, reconcile runs again at 0.8, 1.6, 3 and 5 seconds. After each correction, the result is verified after 1 and 3 seconds.
4. **Rate limiting.** At most 6 corrections in 20 seconds per direction, then a 30-second back-off.

USB devices get a new UID when plugged into a different port. AudioPin matches them by model and name, so they keep their place in the list.

## Project structure

```
Sources/AudioPin/
├── AudioPinApp.swift      # App entry point, scenes, app delegate
├── AudioHAL.swift         # Thin Core Audio wrapper + property listener
├── AudioSystem.swift      # Protocol over the hardware + Core Audio implementation
├── AudioManager.swift     # Orchestrates enforcement: re-checks, verification, UI state
├── PriorityPolicy.swift   # Pure selection rules (preferred device, merge, seeding)
├── CorrectionLimiter.swift# Rate limit and back-off per direction
├── SettingsStore.swift    # Settings persistence (UserDefaults)
├── Preferences.swift      # Settings model (Codable)
├── DeviceStyle.swift      # SF Symbols and labels for device types
├── MenuBarView.swift      # Menu bar popover (SwiftUI)
├── SettingsWindow.swift   # Settings window (SwiftUI)
└── SystemServices.swift   # Launch at login, notifications, window activation
Tests/AudioPinTests/       # Swift Testing: policy, limiter, manager with a fake AudioSystem
scripts/
├── build-app.sh           # Builds and signs dist/AudioPin.app
├── install.sh             # Builds, installs to ~/Applications, launches
└── make-icon.swift        # Renders the app icon
```

Development commands:

```bash
swift build                 # debug build
swift test                  # unit tests (no real audio devices are touched)
./scripts/build-app.sh      # release app bundle
```

## Localization

AudioPin is available in **English** and **Polish**, and follows the macOS language setting. Strings live in a String Catalog, `Resources/Localizable.xcstrings`, which `build-app.sh` compiles into the app bundle.

To add a language:

1. Open `Resources/Localizable.xcstrings` in Xcode.
2. Add the language and translate the strings.
3. Add the language code to `CFBundleLocalizations` in `Resources/Info.plist`.

To pick up new strings from code, regenerate the catalog keys:

```bash
swift build --scratch-path /tmp/audiopin-loc -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc /tmp/audiopin-loc/strings
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata /tmp/audiopin-loc/strings/*.stringsdata
```

## Limitations

- **Apps that pick their own device.** Some apps (Zoom, Teams, Discord) open a specific device instead of the system default. AudioPin can only control the system default, so set those apps to *Same as System*.
- **Manual changes are reverted.** AudioPin cannot tell whether you or macOS changed the device in Control Center. While it is active, it restores your priority order either way. To switch devices, click one in the AudioPin menu, or pause AudioPin.

## Contributing

Issues and pull requests are welcome. Please keep the app small and dependency-free.

## License

[MIT](LICENSE) © Mikołaj Józefiak
