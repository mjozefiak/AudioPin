/// Limits how often AudioPin may correct the system in each direction, so it never ends up
/// in an endless fight with macOS or another app.
struct CorrectionLimiter {
    enum Decision: Equatable {
        case allowed
        /// The limit was just hit and a back-off period started.
        case startedBackoff
        /// Still inside a back-off period.
        case inBackoff
    }

    var maxCorrections = 6
    var window: Duration = .seconds(20)
    var backoff: Duration = .seconds(30)

    private var history: [Direction: [ContinuousClock.Instant]] = [:]
    private var backoffUntil: [Direction: ContinuousClock.Instant] = [:]

    /// Decides whether a correction may happen now. Call `record` after a successful correction.
    mutating func check(_ direction: Direction, now: ContinuousClock.Instant) -> Decision {
        if let until = backoffUntil[direction] {
            if now < until { return .inBackoff }
            backoffUntil[direction] = nil
        }
        let recent = (history[direction] ?? []).filter { now - $0 < window }
        history[direction] = recent
        guard recent.count < maxCorrections else {
            backoffUntil[direction] = now + backoff
            return .startedBackoff
        }
        return .allowed
    }

    mutating func record(_ direction: Direction, now: ContinuousClock.Instant) {
        history[direction, default: []].append(now)
    }

    /// Clears the back-off (e.g. after the user picks a device or the Mac wakes up).
    mutating func reset(_ direction: Direction? = nil) {
        if let direction {
            backoffUntil[direction] = nil
            history[direction] = nil
        } else {
            backoffUntil.removeAll()
            history.removeAll()
        }
    }
}
