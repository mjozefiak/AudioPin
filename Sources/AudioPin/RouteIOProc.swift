import CoreAudio
import Synchronization

/// Real-time state of one warm route, shared between the main actor and the HAL I/O thread.
///
/// Every field is an atomic, so neither side ever takes a lock. The main actor writes `targetGain` and
/// `isProbing`; the I/O thread owns `appliedGain` and sets `sawSignal`. Nothing here allocates.
final class RouteIOState: Sendable {
    private let targetGainBits: Atomic<UInt32>
    /// The gain the previous buffer ended on. Read and written only by the I/O thread.
    private let appliedGainBits: Atomic<UInt32>
    private let probing: Atomic<Bool>
    private let signal = Atomic<Bool>(false)

    init(gain: Float, isProbing: Bool) {
        let clamped = RouteKernel.clampedGain(gain)
        targetGainBits = Atomic(clamped.bitPattern)
        appliedGainBits = Atomic(clamped.bitPattern)
        probing = Atomic(isProbing)
    }

    /// The gain the next buffer ramps to (0...1).
    var targetGain: Float {
        get { Float(bitPattern: targetGainBits.load(ordering: .relaxed)) }
        set { targetGainBits.store(RouteKernel.clampedGain(newValue).bitPattern, ordering: .relaxed) }
    }

    /// While probing, the tap is read but the output is silence (the app still plays on its own device).
    var isProbing: Bool {
        get { probing.load(ordering: .relaxed) }
        set { probing.store(newValue, ordering: .relaxed) }
    }

    /// True once any tap buffer carried a non-zero sample, which proves the capture permission is granted.
    var sawSignal: Bool { signal.load(ordering: .relaxed) }

    /// One I/O cycle: tap input in, target output out. Called on the HAL I/O thread.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // The first input buffer with data is the tap: the target's own input streams are switched off.
        var tap: AudioBuffer?
        for buffer in inputs where buffer.mData != nil && buffer.mDataByteSize > 0 {
            tap = buffer
            break
        }

        if let tap, !signal.load(ordering: .relaxed), RouteKernel.containsSignal(RouteKernel.samples(tap)) {
            signal.store(true, ordering: .relaxed)
        }

        guard let tap, !probing.load(ordering: .relaxed), let first = outputs.first else {
            for buffer in outputs { RouteKernel.silence(RouteKernel.mutableSamples(buffer)) }
            return
        }

        let from = Float(bitPattern: appliedGainBits.load(ordering: .relaxed))
        let to = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        appliedGainBits.store(to.bitPattern, ordering: .relaxed)

        RouteKernel.render(
            input: RouteKernel.samples(tap), inputChannels: Int(tap.mNumberChannels),
            output: RouteKernel.mutableSamples(first), outputChannels: Int(first.mNumberChannels),
            fromGain: from, toGain: to)
        // Channels 1–2 of the first output stream carry the app; any further streams stay silent.
        for buffer in outputs.dropFirst() { RouteKernel.silence(RouteKernel.mutableSamples(buffer)) }
    }

    /// The IOProc block for `AudioDeviceCreateIOProcIDWithBlock`.
    ///
    /// Built here, outside any actor, so the closure carries no main-actor isolation: the HAL calls it on
    /// its own real-time thread, where an isolation check would trap.
    nonisolated static func makeIOBlock(_ state: RouteIOState) -> AudioDeviceIOBlock {
        { @Sendable _, inputData, _, outputData, _ in
            state.render(input: inputData, output: outputData)
        }
    }
}

/// Pure, allocation-free buffer math for the route IOProc. Interleaved `Float32` samples throughout.
enum RouteKernel {
    static func clampedGain(_ gain: Float) -> Float {
        gain.isFinite ? min(max(gain, 0), 1) : 0
    }

    static func samples(_ buffer: AudioBuffer) -> UnsafeBufferPointer<Float> {
        guard let data = buffer.mData else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self),
            count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
    }

    static func mutableSamples(_ buffer: AudioBuffer) -> UnsafeMutableBufferPointer<Float> {
        guard let data = buffer.mData else { return UnsafeMutableBufferPointer(start: nil, count: 0) }
        return UnsafeMutableBufferPointer(
            start: data.assumingMemoryBound(to: Float.self),
            count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
    }

    static func containsSignal(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        for sample in samples where sample != 0 { return true }
        return false
    }

    static func silence(_ samples: UnsafeMutableBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        base.update(repeating: 0, count: samples.count)
    }

    /// Gain applied to frame `frame` of `frames` while ramping linearly from `from` to `to`.
    /// The last frame reaches `to` exactly, so consecutive buffers join without a step.
    @inline(__always)
    static func rampGain(frame: Int, frames: Int, from: Float, to: Float) -> Float {
        guard frames > 0, from != to else { return to }
        return from + (to - from) * Float(frame + 1) / Float(frames)
    }

    /// Copies `input` to `output` times a gain ramped across the buffer, mapping channels:
    /// many → mono averages all input channels; mono → many fills channels 1–2;
    /// otherwise channel *n* goes to channel *n* and extra output channels stay silent.
    /// Output frames beyond the input's length are silenced.
    static func render(
        input: UnsafeBufferPointer<Float>, inputChannels: Int,
        output: UnsafeMutableBufferPointer<Float>, outputChannels: Int,
        fromGain: Float, toGain: Float
    ) {
        guard inputChannels > 0, outputChannels > 0, let out = output.baseAddress else {
            silence(output)
            return
        }
        let outFrames = output.count / outputChannels
        let inFrames = input.baseAddress == nil ? 0 : input.count / inputChannels
        let frames = min(inFrames, outFrames)
        let from = clampedGain(fromGain)
        let to = clampedGain(toGain)

        if let inp = input.baseAddress {
            for frame in 0..<frames {
                let gain = rampGain(frame: frame, frames: frames, from: from, to: to)
                let src = inp + frame * inputChannels
                let dst = out + frame * outputChannels
                if outputChannels == 1 {
                    var sum: Float = 0
                    for c in 0..<inputChannels { sum += src[c] }
                    dst[0] = sum / Float(inputChannels) * gain
                } else if inputChannels == 1 {
                    dst[0] = src[0] * gain
                    dst[1] = src[0] * gain
                    for c in 2..<outputChannels { dst[c] = 0 }
                } else {
                    for c in 0..<outputChannels { dst[c] = c < inputChannels ? src[c] * gain : 0 }
                }
            }
        }
        let written = frames * outputChannels
        if written < output.count {
            (out + written).update(repeating: 0, count: output.count - written)
        }
    }
}
