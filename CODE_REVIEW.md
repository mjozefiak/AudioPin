# Code review rules

These rules apply in addition to the `om-code-review` built-in checklist. The validation gate is `swift build` followed by `swift test`. A PR that fails it cannot be approved; the failure is a blocker finding reported with the full review.

## Priorities

1. **Correctness of enforcement.** AudioPin must never pick a disabled device. It must fall back to the next connected device in priority order, and it must not fight macOS in a loop.
2. **User data safety.** Stored settings and priority lists survive upgrades and decode failures.
3. **Privacy and permissions.** The app reads and changes device properties only and asks for no permissions, with one exception: the per-app audio router (`AudioRouter` / `CoreAudioRouter`, plus the `#if DEBUG` spike harness in `RouteSpike.swift`) may tap an app's audio through a Core Audio process tap and play it through a private aggregate device. That path runs only after an explicit per-app change by the user (device, volume or mute), needs the macOS System Audio Recording permission, never stores or logs captured audio, and never opens a device's input stream. Nothing else opens audio I/O, and the Microphone permission is never requested.
4. **Contracts.** See `BACKWARD_COMPATIBILITY.md`.

## Repo-specific checks

- **Concurrency.** Code compiles in Swift 6 language mode without new warnings. State touched by UI or HAL code is `@MainActor`. HAL listener callbacks (`@Sendable`, delivered on `AudioPin.hal-listener`) hop to the main actor before mutating anything. Flag any `nonisolated(unsafe)` or `@unchecked Sendable` that comes without a justification.
- **Testability seam.** New hardware access goes through `AudioSystem` and gets a `FakeAudioSystem` counterpart. Per-app routing hardware access (process taps, private aggregates, IOProcs) goes through `AudioRouter` and gets a `FakeAudioRouter` counterpart instead. Real-time IOProc code stays in `RouteIOProc.swift`: no allocation, locks, logging or Swift concurrency on the I/O thread, and its pure buffer functions are unit-tested. New persistence goes through `SettingsStore`. Logic in `AudioManager` or `PriorityPolicy` that changes behavior needs a Swift Testing case. A bug fix needs a regression test in `RegressionTests.swift` or the matching suite.
- **Rate limiting and re-checks.** Changes to `CorrectionLimiter` or to the re-check and verification schedule in `AudioManager` must keep a test showing the loop stops (see `stopsFightingAfterRepeatedSwitches`).
- **Settings decoding.** New `AppSettings` fields use `decodeIfPresent(...) ?? default`. Renamed or removed keys, or a changed `KnownDevice` shape, are breaking (see `BACKWARD_COMPATIBILITY.md`). `UserDefaultsSettingsStore` keeps the backup-on-decode-failure behavior.
- **Device identity.** Devices are matched by Core Audio UID, with the model and name fallback for USB port changes. Do not key on `AudioObjectID`, which is not stable across reconnects.
- **Error handling.** Core Audio calls compare against `noErr` and map failures to `nil`, `false`, or empty results, as `AudioHAL` does. Callers handle those results. Persistence errors go to `os.Logger`. No `try!`, no force unwraps on HAL results, and no `fatalError` in runtime paths.
- **Localization.** New user-facing strings are localizable and have a Polish translation in `Resources/Localizable.xcstrings`. Hard-coded English in SwiftUI views is a finding.
- **Dependencies.** Adding a package dependency is a blocker unless the PR explains why it is needed (README: "keep the app small and dependency-free").
- **Release metadata.** Version bumps change both `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`. Changes to `scripts/` or `release.yml` keep the `AudioPin.dmg` asset name and the tag/version check.
- **Landing page.** Changes under `docs/` keep the download links working and the English and Polish copy in sync (the `data-i18n` strings).

## Severity

- **Blocker**: wrong device selected, an enforcement loop, settings loss or a breaking settings change, a permission prompt introduced (except the System Audio Recording prompt raised by the per-app router after an explicit per-app change; a Microphone prompt or any other new permission is always a blocker), audio I/O opened outside the per-app router or before a user's per-app change, a failing gate, or a broken release asset name.
- **Major**: a missing test for changed enforcement or policy logic, a concurrency isolation violation, an untranslated user-facing string.
- **Minor**: naming, comments, or small simplifications that change no behavior.
