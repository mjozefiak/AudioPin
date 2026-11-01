# AudioPin agent guide

AudioPin is a small, dependency-free macOS 27 menu bar app (Swift 6.4, SwiftPM, SwiftUI, Core Audio HAL) that keeps the user's preferred input and output devices as the system defaults. It listens for Core Audio change notifications and reverts unwanted switches according to per-direction priority lists. It runs as an `LSUIElement` agent (no Dock icon), ships as an ad-hoc signed, non-notarized DMG, and has a static landing page in `docs/`.

## Task routing

| When the task involves… | Read first | Key rules |
|---|---|---|
| Device selection rules (priority, fallback, merge, seeding) | `Sources/AudioPin/PriorityPolicy.swift`, `Tests/AudioPinTests/PriorityPolicyTests.swift` | Keep these as pure functions with no Core Audio calls. Every rule change gets a Swift Testing case. |
| Enforcement, re-checks, verification, back-off | `Sources/AudioPin/AudioManager.swift`, `Sources/AudioPin/CorrectionLimiter.swift`, `Tests/AudioPinTests/AudioManagerTests.swift`, `Tests/AudioPinTests/CorrectionLimiterTests.swift`, `Tests/AudioPinTests/RegressionTests.swift` | `AudioManager` depends on the `AudioSystem` and `SettingsStore` protocols. Test it with `FakeAudioSystem` (`Tests/AudioPinTests/Fakes.swift`), never real devices. Do not loosen the rate limit (6 corrections per 20 s, then a 30 s back-off) without a regression test. |
| Core Audio access | `Sources/AudioPin/AudioHAL.swift`, `Sources/AudioPin/AudioSystem.swift` | Add HAL calls behind `AudioSystem` and mirror them in `FakeAudioSystem`. The listener callback arrives on its own queue; hop to the main actor before touching state. Never open an audio stream, with one exception: the per-app router (`AudioRouter` / `CoreAudioRouter`, mirrored in `FakeAudioRouter`; the `#if DEBUG` spike in `RouteSpike.swift`) may tap an app's output through a Core Audio process tap, only after an explicit per-app change by the user and only under the System Audio Recording permission. It never opens a device's input stream, and nothing may ever trigger the microphone permission prompt. |
| Settings model and persistence | `Sources/AudioPin/Preferences.swift`, `Sources/AudioPin/SettingsStore.swift`, `BACKWARD_COMPATIBILITY.md` | `AppSettings` decoding is tolerant: each new field uses `decodeIfPresent` with a default. Never rename keys or the `AudioPin.settings.v1` store key. |
| Menu bar popover and settings window (SwiftUI) | `Sources/AudioPin/MenuBarView.swift`, `Sources/AudioPin/SettingsWindow.swift`, `Sources/AudioPin/DeviceStyle.swift`, `Sources/AudioPin/PreviewMode.swift` | Every user-facing string goes through the String Catalog, with a Polish translation (see Localization). Check UI changes with a debug build run with `--preview` (and `AUDIOPIN_SNAPSHOT_DIR` for screenshots). |
| App lifecycle, launch at login, notifications | `Sources/AudioPin/AudioPinApp.swift`, `Sources/AudioPin/SystemServices.swift` | Launch at login stays opt-in. Enforcement pauses during fast user switching. |
| Brand mark and icons | `Sources/AudioPin/BrandMark.swift`, `scripts/make-icon.swift`, `Resources/AppIcon.icns`, `docs/assets/brand/` | `Tests/AudioPinTests/BrandMarkTests.swift` covers the drawn mark. |
| Localization | `Resources/Localizable.xcstrings`, `Resources/Info.plist`, README "Localization" | Supported languages are English (source) and Polish. A new language also goes into `CFBundleLocalizations`. |
| Packaging and release | `scripts/build-app.sh`, `scripts/make-dmg.sh`, `scripts/install.sh`, `.github/workflows/release.yml`, `Resources/Info.plist` | A release tag `vX.Y` must equal `CFBundleShortVersionString` (CI enforces this). Bump `CFBundleVersion` alongside it. The release asset stays named `AudioPin.dmg`. |
| Landing page | `docs/index.html`, `.github/workflows/pages.yml` | Static HTML deployed from `docs/` on pushes to `main`. Download links point at `releases/latest/download/AudioPin.dmg`. |

## Validation gate

Run these in order; any non-zero exit fails the gate (`.ai/agentic.config.json`):

```bash
swift build
swift test
```

The tests use Swift Testing and touch no real audio devices. A release build is `./scripts/build-app.sh` (writes `dist/AudioPin.app`).

## Conventions

- Swift 6 language mode with strict concurrency. Types that touch UI or hardware state are `@MainActor`.
- No third-party dependencies: `Package.swift` declares none. Keep it that way.
- Log through `os.Logger` with subsystem `dev.mjozefiak.AudioPin`.

## Process docs

- `SDLC.md`: ticket flow, labels, QA gate, claim protocol.
- `CODE_REVIEW.md`: review rules for this repo.
- `BACKWARD_COMPATIBILITY.md`: protected surfaces.
- `.ai/agentic.config.json`: pipeline config. `.ai/trackers/github.md` and `.ai/browsers/agent-browser.md` define the tracker and browser operations.
