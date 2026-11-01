# Execution plan: per-app output routing and volume (pre-spike increment)

Source doc: .ai/specs/2026-11-01-per-app-output-routing.md
Spec PR: #12 (design-only; the spec merges through it)

## Goal

Land the part of the per-app audio spec that the spec itself allows before its Phase 0 hardware spike: amend the repo rules (owner decision Q1), add the debug-only `--route-test` spike harness, and add the pure model and policy layer (spec Phase 1). Release builds behave exactly as today.

## Scope

- `AGENTS.md`, `CODE_REVIEW.md`: narrow the "never open an audio stream / no permissions" rules as spec Phase 0 step 1 describes.
- `Sources/AudioPin/RouteIOProc.swift`: the real-time copy × gain kernel (per-buffer linear ramp, channel mapping, probe silence) as pure, allocation-free functions plus an atomic gain box. Used by the spike now and by `CoreAudioRouter` in spec Phase 2.
- `Sources/AudioPin/RouteSpike.swift` (`#if DEBUG` only): `--route-test=<bundleID>:<deviceUID|default>:<volume>` builds one warm route (process tap by bundle ID → private aggregate → IOProc) and logs status, so the owner can run the spike measurements of spec Phase 0 steps 2–5.
- `Sources/AudioPin/Preferences.swift`: `AppRule`, `AppSettings.appRules`, `AppSettings.showAppsInMenu` with tolerant decoding.
- `Sources/AudioPin/AppAudioPolicy.swift`: `warmRoutes(...)`, `gain(forVolume:muted:)`, helper-process assignment.
- `Sources/AudioPin/RouteDeviceFilter.swift` and the `AudioManager` device refresh.
- Swift Testing cases for all of the above.

## Non-goals

- **Spike measurements** (spec Phase 0 steps 2–5, the manual part): they need real hardware (AirPods, a USB headset), real apps (Spotify, Discord, Chrome, Safari, Music) and the System Audio Recording prompt on the owner's Mac. An unattended run cannot do them. The harness lands; the run notes are the owner's.
- **Spec Phases 2–4** (router, controller, Settings → Apps, popover): the spec gates Phase 2 on the spike results ("Phase 2 is gated on both results"; "If the spike disproves the warm-route design, this spec is revised rather than worked around"). They continue after the spike results are appended to the spec.
- No `NSAudioCaptureUsageDescription` in the committed `Info.plist` (spec: it lands in Phase 3; the spike uses a local, uncommitted key).
- No README / landing page change (spec: Phase 3).
- No `CorrectionLimiter` generalisation yet (spec Phase 2 step 3; it has no consumer until the controller exists).

## Implementation Plan

### Phase 1: Agent rules (spec Phase 0 step 1)

1.1 Amend `AGENTS.md` (Core Audio row) and `CODE_REVIEW.md` (Priority 3, Severity, testability rule) per Q1.

### Phase 2: Spike harness (spec Phase 0 step 2, code part)

2.1 Add `RouteIOProc` kernel (ramp, channel mapping, probe silence, atomic gain) with unit tests on in-memory buffers.
2.2 Add the debug-only `--route-test` flag (`RouteSpike`) with a tested argument parser; wire it in `AppDelegate` under `#if DEBUG`.

### Phase 3: Model and policy (spec Phase 1)

3.1 Add `AppRule`, `AppSettings.appRules`, `AppSettings.showAppsInMenu` with tolerant decoding. Tests: old JSON, round-trip, partial rule, bundle-ID validation, `isNeutral`.
3.2 Add `AppAudioPolicy.warmRoutes(rules:processes:recentBundleIDs:connectedOutputs:defaultOutputUID:)` and `gain(forVolume:muted:)` with the table-driven cases listed in spec Phase 1 step 2.
3.3 Add `RouteDeviceFilter.isOwnRouteDevice(uid:)` and apply it in `AudioManager`'s device refresh. Tests: pure filter + an `AudioManagerTests` case.

## Risks

- The spike harness touches real Core Audio tap APIs that cannot be exercised unattended (running it raises the System Audio Recording prompt). It is compiled and its pure parts are unit-tested; the hardware path is verified by the owner's spike run, as the spec plans.
- `AppAudioPolicy`'s types (`AudioProcess`, `WarmRoute`, `RouteMode`) follow the spec's API contract; the spike may still change them. They are internal and have no consumer outside tests yet, so a revision is cheap.
- Spec PR #12 is still open, and its rows Q3–Q9 are autonomous defaults "to correct before merge". This plan follows the spec as written on its branch.

## Progress

> Convention: `- [ ]` pending, `- [x]` done. Append ` — <commit sha>` when a step lands. Do not rename step titles.

### Phase 1: Agent rules

- [ ] 1.1 Amend AGENTS.md and CODE_REVIEW.md per Q1

### Phase 2: Spike harness

- [ ] 2.1 Add RouteIOProc kernel with tests
- [ ] 2.2 Add debug-only --route-test spike flag

### Phase 3: Model and policy

- [ ] 3.1 Add AppRule and settings fields
- [ ] 3.2 Add AppAudioPolicy
- [ ] 3.3 Add RouteDeviceFilter and apply it in AudioManager
