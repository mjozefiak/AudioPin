# Code review rules

These rules apply in addition to the `om-code-review` built-in checklist. The validation gate is `swift build` followed by `swift test`. A PR that fails it is not reviewable.

## Priorities

1. **Correctness of enforcement.** AudioPin must never pick a disabled device. It must fall back to the next connected device in priority order, and it must not fight macOS in a loop.
2. **User data safety.** Stored settings and priority lists survive upgrades and decode failures.
3. **Privacy and permissions.** The app reads and changes device properties only. It never opens audio I/O and asks for no permissions.
4. **Contracts.** See `BACKWARD_COMPATIBILITY.md`.

## Repo-specific checks

- **Concurrency.** Code compiles in Swift 6 language mode without new warnings. State touched by UI or HAL code is `@MainActor`. HAL listener callbacks (`@Sendable`, delivered on `AudioPin.hal-listener`) hop to the main actor before mutating anything. Flag any `nonisolated(unsafe)` or `@unchecked Sendable` that comes without a justification.
- **Testability seam.** New hardware access goes through `AudioSystem` and gets a `FakeAudioSystem` counterpart. New persistence goes through `SettingsStore`. Logic in `AudioManager` or `PriorityPolicy` that changes behavior needs a Swift Testing case. A bug fix needs a regression test in `RegressionTests.swift` or the matching suite.
- **Rate limiting and re-checks.** Changes to `CorrectionLimiter` or to the re-check and verification schedule in `AudioManager` must keep a test showing the loop stops (see `stopsFightingAfterRepeatedSwitches`).
- **Settings decoding.** New `AppSettings` fields use `decodeIfPresent(...) ?? default`. Renamed or removed keys, or a changed `KnownDevice` shape, are breaking (see `BACKWARD_COMPATIBILITY.md`). `UserDefaultsSettingsStore` keeps the backup-on-decode-failure behavior.
- **Device identity.** Devices are matched by Core Audio UID, with the model and name fallback for USB port changes. Do not key on `AudioObjectID`, which is not stable across reconnects.
- **Error handling.** Core Audio calls compare against `noErr` and map failures to `nil`, `false`, or empty results, as `AudioHAL` does. Callers handle those results. Persistence errors go to `os.Logger`. No `try!`, no force unwraps on HAL results, and no `fatalError` in runtime paths.
- **Localization.** New user-facing strings are localizable and have a Polish translation in `Resources/Localizable.xcstrings`. Hard-coded English in SwiftUI views is a finding.
- **Dependencies.** Adding a package dependency is a blocker unless the PR explains why it is needed (README: "keep the app small and dependency-free").
- **Release metadata.** Version bumps change both `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`. Changes to `scripts/` or `release.yml` keep the `AudioPin.dmg` asset name and the tag/version check.
- **Landing page.** Changes under `docs/` keep the download links working and the English and Polish copy in sync (the `data-i18n` strings).

## Severity

- **Blocker**: wrong device selected, an enforcement loop, settings loss or a breaking settings change, a permission prompt introduced, a failing gate, or a broken release asset name.
- **Major**: a missing test for changed enforcement or policy logic, a concurrency isolation violation, an untranslated user-facing string.
- **Minor**: naming, comments, or small simplifications that change no behavior.
