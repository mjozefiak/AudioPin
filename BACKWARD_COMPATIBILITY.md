# Backward compatibility

AudioPin is an end-user app with no public API or library product. Its protected surfaces are the data and identifiers that already-installed copies, users, and links depend on.

| Surface | Where | Breaking change | Required path |
|---|---|---|---|
| Stored settings | `UserDefaultsSettingsStore` key `AudioPin.settings.v1` (+ `.backup`), JSON of `AppSettings` / `KnownDevice` in `Sources/AudioPin/Preferences.swift` | Renaming or removing a key, changing a field's type, making a new field required, changing the store key | Add fields only with `decodeIfPresent ?? default`. For an incompatible shape, introduce a new key (e.g. `.v2`) with a migration that reads `.v1`. Add a decode test with old JSON (see `settingsDecodeWithMissingKeysKeepsPriorities`). |
| Bundle identifier | `CFBundleIdentifier` `dev.mjozefiak.AudioPin` in `Resources/Info.plist` | Any change | Not allowed: it orphans the user's `defaults` domain, the launch-at-login registration, and notification permissions. |
| Default device behavior | Seeding rules in `PriorityPolicy.swift` (new Bluetooth and Continuity microphones disabled by default) | Changing which devices start enabled for existing users | Apply new defaults only to newly seen devices. Never rewrite stored `isEnabled` values. Call the change out in release notes. |
| Release asset and version | `AudioPin.dmg` asset name, tag `vX.Y` equal to `CFBundleShortVersionString` (`.github/workflows/release.yml`) | Renaming the asset, changing the tag scheme | README and `docs/index.html` link to `releases/latest/download/AudioPin.dmg`. Keep the name or update every link in the same PR. |
| Debug preview flags | `--preview`, `--pane=…`, `AUDIOPIN_SNAPSHOT_DIR` (`PreviewMode.swift`, debug builds only) | Renaming flags | Internal tooling only. Update `AGENTS.md`, `SDLC.md`, and any QA scripts in the same PR. |
| Platform floor | `platforms: [.macOS(.v27)]`, `LSMinimumSystemVersion` 27.0, Apple silicon | Raising the minimum macOS or dropping an architecture | Needs a minor version bump and a README "Requirements" update. |

Localized strings, the landing page, and internal Swift types are not protected surfaces. Change them freely, within `CODE_REVIEW.md`.
