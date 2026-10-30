import Testing
@testable import AudioPin

@Suite("CorrectionLimiter")
struct CorrectionLimiterTests {
    private let start = ContinuousClock.now

    @Test func allowsUpToTheLimitThenBacksOff() {
        var limiter = CorrectionLimiter(maxCorrections: 3, window: .seconds(20), backoff: .seconds(30))
        for i in 0..<3 {
            let now = start + .seconds(i)
            #expect(limiter.check(.input, now: now) == .allowed)
            limiter.record(.input, now: now)
        }
        #expect(limiter.check(.input, now: start + .seconds(4)) == .startedBackoff)
        #expect(limiter.check(.input, now: start + .seconds(10)) == .inBackoff)
    }

    @Test func backoffExpires() {
        var limiter = CorrectionLimiter(maxCorrections: 1, window: .seconds(20), backoff: .seconds(30))
        limiter.record(.input, now: start)
        #expect(limiter.check(.input, now: start + .seconds(1)) == .startedBackoff)
        #expect(limiter.check(.input, now: start + .seconds(32)) == .allowed)
    }

    @Test func directionsAreIndependent() {
        var limiter = CorrectionLimiter(maxCorrections: 1, window: .seconds(20), backoff: .seconds(30))
        limiter.record(.input, now: start)
        #expect(limiter.check(.input, now: start) == .startedBackoff)
        #expect(limiter.check(.output, now: start) == .allowed)
    }

    @Test func oldCorrectionsFallOutOfTheWindow() {
        var limiter = CorrectionLimiter(maxCorrections: 2, window: .seconds(20), backoff: .seconds(30))
        limiter.record(.output, now: start)
        limiter.record(.output, now: start + .seconds(1))
        #expect(limiter.check(.output, now: start + .seconds(25)) == .allowed)
    }

    @Test func resetClearsBackoff() {
        var limiter = CorrectionLimiter(maxCorrections: 1, window: .seconds(20), backoff: .seconds(30))
        limiter.record(.input, now: start)
        _ = limiter.check(.input, now: start)
        limiter.reset(.input)
        #expect(limiter.check(.input, now: start + .seconds(1)) == .allowed)
    }
}
