import Foundation

/// One process the HAL reports as an audio client.
struct AudioProcess: Hashable, Sendable {
    let bundleID: String
    let pid: pid_t
    /// True while the process is producing output (`kAudioProcessPropertyIsRunningOutput`).
    let isRunningOutput: Bool
}

/// How a warm route treats its app.
enum RouteMode: Hashable, Sendable {
    /// The app plays to the default as usual: tap unmuted, IOProc stopped.
    case passthrough
    /// The app is muted at the hardware and played by the IOProc to the target at the rule's gain.
    case routing
}

/// A route that must exist for one rule: process tap → private aggregate → IOProc.
struct WarmRoute: Hashable, Sendable {
    let ruleID: String
    /// The rule's bundle ID first, then its running helper processes, sorted.
    let bundleIDs: [String]
    /// The resolved target: the pinned device when connected, otherwise the system default.
    let deviceUID: String
    let mode: RouteMode
    let gain: Float
    /// False = kept for an app that quit earlier in this session: tap and aggregate stay, IOProc stopped.
    let appRunning: Bool
}

/// Pure per-app routing rules, like `PriorityPolicy` for default devices. No Core Audio calls.
enum AppAudioPolicy {
    /// Slider position → linear gain. `gain = position²` so the top half of the slider is not dead.
    static func gain(forVolume volume: Float, muted: Bool) -> Float {
        guard !muted else { return 0 }
        let position = AppRule.clampedVolume(volume)
        return position * position
    }

    /// Processes that cannot be controlled per app: they play for many apps at once
    /// (Safari and every WebKit view play through the shared WebKit GPU process).
    static func isSharedProcess(_ bundleID: String) -> Bool {
        bundleID == "com.apple.WebKit" || bundleID.hasPrefix("com.apple.WebKit.")
    }

    /// False for processes no rule can control: no bundle ID (`afplay`, command-line tools) or a shared process.
    static func isSupported(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && !isSharedProcess(bundleID)
    }

    /// The rule that owns a process, so each process is tapped at most once.
    /// An exact bundle-ID match wins; otherwise the longest rule ID that is a dotted prefix
    /// (`com.google.Chrome` owns `com.google.Chrome.helper`). Disabled rules own nothing.
    static func owner(of bundleID: String, rules: [AppRule]) -> AppRule? {
        guard isSupported(bundleID) else { return nil }
        let enabled = rules.filter(\.isEnabled)
        if let exact = enabled.first(where: { $0.bundleID == bundleID }) { return exact }
        return enabled
            .filter { bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }

    /// The warm routes that must exist right now.
    ///
    /// - Parameters:
    ///   - recentBundleIDs: rule IDs whose app ran earlier in this session; their routes are kept
    ///     (IOProc stopped) so a relaunch is muted from its first buffer.
    ///   - defaultOutputUID: the current system default output; `nil` means no route can be built.
    static func warmRoutes(
        rules: [AppRule],
        processes: [AudioProcess],
        recentBundleIDs: Set<String>,
        connectedOutputs: [AudioDevice],
        defaultOutputUID: String?
    ) -> [WarmRoute] {
        guard let defaultOutputUID else { return [] }
        var owned: [String: Set<String>] = [:]
        for process in processes {
            guard let rule = owner(of: process.bundleID, rules: rules) else { continue }
            owned[rule.bundleID, default: []].insert(process.bundleID)
        }
        let connected = Set(connectedOutputs.map(\.uid))

        return rules.compactMap { rule in
            guard rule.isEnabled, !rule.isNeutral, isSupported(rule.bundleID) else { return nil }
            let running = owned[rule.bundleID] ?? []
            guard !running.isEmpty || recentBundleIDs.contains(rule.bundleID) else { return nil }

            let target = rule.deviceUID.flatMap { connected.contains($0) ? $0 : nil } ?? defaultOutputUID
            let gain = gain(forVolume: rule.volume, muted: rule.isMuted)
            let helpers = running.subtracting([rule.bundleID]).sorted()
            return WarmRoute(
                ruleID: rule.bundleID,
                bundleIDs: [rule.bundleID] + helpers,
                deviceUID: target,
                mode: target == defaultOutputUID && gain >= 1 ? .passthrough : .routing,
                gain: gain,
                appRunning: !running.isEmpty)
        }
    }
}
