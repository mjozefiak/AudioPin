import CoreAudio
import Testing
@testable import AudioPin

@Suite("RouteIOProc")
struct RouteIOProcTests {
    /// Runs `RouteKernel.render` on arrays and returns the output.
    private func render(
        _ input: [Float], inChannels: Int, outFrames: Int, outChannels: Int, from: Float, to: Float
    ) -> [Float] {
        var output = [Float](repeating: 9, count: outFrames * outChannels)
        input.withUnsafeBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { out in
                RouteKernel.render(input: inp, inputChannels: inChannels, output: out, outputChannels: outChannels,
                                   fromGain: from, toGain: to)
            }
        }
        return output
    }

    @Test func constantGainScalesEverySample() {
        let out = render([1, -1, 0.5, -0.5], inChannels: 2, outFrames: 2, outChannels: 2, from: 0.25, to: 0.25)
        #expect(out == [0.25, -0.25, 0.125, -0.125])
    }

    @Test func rampEndsExactlyOnTheTargetGain() {
        let out = render([1, 1, 1, 1], inChannels: 1, outFrames: 4, outChannels: 1, from: 0, to: 1)
        #expect(out == [0.25, 0.5, 0.75, 1])
    }

    @Test func rampIsMonotonicWhenTurningDown() {
        let out = render([Float](repeating: 1, count: 8), inChannels: 1, outFrames: 8, outChannels: 1, from: 1, to: 0)
        #expect(out.last == 0)
        #expect(zip(out, out.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func stereoToMonoAverages() {
        let out = render([1, 0, 0.5, 0.5], inChannels: 2, outFrames: 2, outChannels: 1, from: 1, to: 1)
        #expect(out == [0.5, 0.5])
    }

    @Test func stereoToMultichannelFillsChannelsOneAndTwo() {
        let out = render([0.1, 0.2], inChannels: 2, outFrames: 1, outChannels: 4, from: 1, to: 1)
        #expect(out == [0.1, 0.2, 0, 0])
    }

    @Test func monoToStereoDuplicates() {
        let out = render([0.5], inChannels: 1, outFrames: 1, outChannels: 2, from: 1, to: 1)
        #expect(out == [0.5, 0.5])
    }

    @Test func shortInputSilencesTheRest() {
        let out = render([1, 1], inChannels: 2, outFrames: 3, outChannels: 2, from: 1, to: 1)
        #expect(out == [1, 1, 0, 0, 0, 0])
    }

    @Test(arguments: [Float.nan, -1, 2, .infinity])
    func gainIsClamped(gain: Float) {
        #expect((0...1).contains(RouteKernel.clampedGain(gain)))
    }

    @Test func detectsSignal() {
        #expect([0, 0, 0.001].withUnsafeBufferPointer { RouteKernel.containsSignal($0) })
        #expect(![Float](repeating: 0, count: 4).withUnsafeBufferPointer { RouteKernel.containsSignal($0) })
    }

    // MARK: Buffer lists, as the HAL hands them to the IOProc

    private final class Lists {
        let input: UnsafeMutableAudioBufferListPointer
        let output: UnsafeMutableAudioBufferListPointer

        init(tap: [Float], tapChannels: UInt32, outputs: [(frames: Int, channels: UInt32)], disabledInputs: Int = 0) {
            input = AudioBufferList.allocate(maximumBuffers: disabledInputs + 1)
            for i in 0..<disabledInputs { input[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil) }
            input[disabledInputs] = Self.buffer(tap, channels: tapChannels)
            output = AudioBufferList.allocate(maximumBuffers: outputs.count)
            for (i, spec) in outputs.enumerated() {
                output[i] = Self.buffer([Float](repeating: 9, count: spec.frames * Int(spec.channels)), channels: spec.channels)
            }
        }

        private static func buffer(_ samples: [Float], channels: UInt32) -> AudioBuffer {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            data.initialize(from: samples, count: samples.count)
            return AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(samples.count * 4), mData: data)
        }

        func samples(output index: Int) -> [Float] { Array(RouteKernel.samples(output[index])) }

        func run(_ state: RouteIOState) { state.render(input: input.unsafePointer, output: output.unsafeMutablePointer) }

        deinit {
            for list in [input, output] {
                for buffer in list { buffer.mData?.deallocate() }
                free(list.unsafeMutablePointer)
            }
        }
    }

    @Test func probeWritesSilenceButDetectsSignal() {
        let lists = Lists(tap: [0.5, 0.5], tapChannels: 2, outputs: [(1, 2)])
        let state = RouteIOState(gain: 1, isProbing: true)
        lists.run(state)
        #expect(lists.samples(output: 0) == [0, 0])
        #expect(state.sawSignal)
    }

    @Test func digitalSilenceDoesNotCountAsSignal() {
        let lists = Lists(tap: [0, 0], tapChannels: 2, outputs: [(1, 2)])
        let state = RouteIOState(gain: 1, isProbing: true)
        lists.run(state)
        #expect(!state.sawSignal)
    }

    @Test func routingSkipsDisabledInputsAndSilencesExtraOutputStreams() {
        let lists = Lists(tap: [0.5, -0.5], tapChannels: 2, outputs: [(1, 2), (1, 2)], disabledInputs: 1)
        let state = RouteIOState(gain: 0.5, isProbing: false)
        lists.run(state)
        #expect(lists.samples(output: 0) == [0.25, -0.25])
        #expect(lists.samples(output: 1) == [0, 0])
    }

    @Test func gainChangeRampsFromThePreviousBuffer() {
        let lists = Lists(tap: [1, 1, 1, 1], tapChannels: 1, outputs: [(4, 1)])
        let state = RouteIOState(gain: 1, isProbing: false)
        state.targetGain = 0
        lists.run(state)
        #expect(lists.samples(output: 0) == [0.75, 0.5, 0.25, 0])
        lists.run(state)
        #expect(lists.samples(output: 0) == [0, 0, 0, 0])
    }
}
