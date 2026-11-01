#if DEBUG
import CoreAudio
import Foundation
import os

/// `--route-test=<bundleID>:<deviceUID|default>:<volume>` from the command line.
///
/// `volume` is a percentage (0–100). Device UIDs may contain colons, so the bundle ID is everything
/// before the first colon and the volume everything after the last one.
struct RouteSpikeRequest: Equatable {
    static let flag = "--route-test="

    let bundleID: String
    /// `nil` = follow the current system default output.
    let deviceUID: String?
    /// Slider position 0...1.
    let volume: Float

    static func fromArguments(_ arguments: [String]) -> RouteSpikeRequest? {
        arguments.first { $0.hasPrefix(flag) }.flatMap { parse(String($0.dropFirst(flag.count))) }
    }

    static func parse(_ value: String) -> RouteSpikeRequest? {
        guard let first = value.firstIndex(of: ":"), let last = value.lastIndex(of: ":"), first < last else {
            return nil
        }
        let bundleID = String(value[..<first])
        let device = String(value[value.index(after: first)..<last])
        guard AppRule.isValidBundleID(bundleID), !device.isEmpty,
              let percent = Float(value[value.index(after: last)...]), (0...100).contains(percent)
        else { return nil }
        return RouteSpikeRequest(bundleID: bundleID, deviceUID: device == "default" ? nil : device, volume: percent / 100)
    }
}

/// Debug-only spike for the per-app audio spec (Phase 0): builds one warm route for one app
/// (process tap by bundle ID → private aggregate with the target device → IOProc copy × gain) and logs
/// what happens, so the design can be checked on real hardware before the router is written.
///
/// It needs the System Audio Recording permission, so run it from an app bundle that has a local,
/// uncommitted `NSAudioCaptureUsageDescription` in its `Info.plist`. Follow the output with
/// `log stream --level info --predicate 'subsystem == "dev.mjozefiak.AudioPin" && category == "route-spike"'`
/// or run the binary from a terminal.
@MainActor
final class RouteSpike {
    private static let logger = Logger(subsystem: "dev.mjozefiak.AudioPin", category: "route-spike")
    /// No-signal window before a probe is reported as "permission probably missing" (spec: 10 s).
    private static let probeTimeout: Duration = .seconds(10)

    private let request: RouteSpikeRequest
    private let state: RouteIOState
    private let clock = ContinuousClock()
    private var tapDescription: CATapDescription?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false
    private var monitor: Task<Void, Never>?

    init(_ request: RouteSpikeRequest) {
        self.request = request
        state = RouteIOState(gain: AppAudioPolicy.gain(forVolume: request.volume, muted: false), isProbing: true)
    }

    func start() {
        let started = clock.now
        guard let target = resolveTarget() else {
            say("Target device \(request.deviceUID ?? "default") is not a connected output; nothing built")
            return
        }
        let isPassthrough = target.objectID == AudioHAL.defaultDeviceID(.output) && request.volume >= 1
        say("Route for \(request.bundleID) → \(target.name) [\(target.uid)], volume \(Int(request.volume * 100))%, "
            + "planned mode \(isPassthrough ? "passthrough" : "routing")")

        guard createTap(), createAggregate(target: target), createIOProc(target: target) else {
            stop()
            return
        }
        logLatency()
        let status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            say("AudioDeviceStart failed: \(status)")
            stop()
            return
        }
        isRunning = true
        say("Probing (tap unmuted, output silent) after \(clock.now - started) setup")
        monitor = Task { [weak self] in await self?.watchProbe(passthrough: isPassthrough) }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        if let procID {
            if isRunning { AudioDeviceStop(aggregateID, procID) }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        isRunning = false
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        if aggregateID != kAudioObjectUnknown || tapID != kAudioObjectUnknown { say("Route torn down") }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Building the route

    private func resolveTarget() -> AudioDevice? {
        let outputs = AudioHAL.devices(.output)
        if let uid = request.deviceUID { return outputs.first { $0.uid == uid } }
        let id = AudioHAL.defaultDeviceID(.output)
        return outputs.first { $0.objectID == id }
    }

    private func createTap() -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.bundleIDs = [request.bundleID]
        description.isProcessRestoreEnabled = true
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "AudioPin route spike"
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            say("AudioHardwareCreateProcessTap failed: \(status)")
            tapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        tapDescription = description
        say("Tap \(tapID) created for bundle IDs \(description.bundleIDs)")
        return true
    }

    private func createAggregate(target: AudioDevice) -> Bool {
        guard let tapUID = AudioHAL.string(tapID, kAudioTapPropertyUID) else {
            say("Could not read the tap UID")
            return false
        }
        let uid = "\(RouteDeviceFilter.uidPrefix)spike.\(UUID().uuidString)"
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioPin Route (spike)",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: target.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: target.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: false,
        ]
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            say("AudioHardwareCreateAggregateDevice failed: \(status)")
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        say("Aggregate \(aggregateID) [\(uid)] created")
        return true
    }

    private func createIOProc(target: AudioDevice) -> Bool {
        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, aggregateID, nil, RouteIOState.makeIOBlock(state))
        guard status == noErr, let id else {
            say("AudioDeviceCreateIOProcIDWithBlock failed: \(status)")
            return false
        }
        procID = id
        return disableTargetInputs(target: target, procID: id)
    }

    /// Switches off every aggregate input stream that belongs to the target device, so its microphone
    /// never opens. The tap's streams are told apart by channel count (`RouteStreamLayout`); when that is
    /// ambiguous the route is refused rather than risk opening the microphone.
    private func disableTargetInputs(target: AudioDevice, procID: AudioDeviceIOProcID) -> Bool {
        let aggregate = streamChannels(aggregateID)
        let targetInputs = streamChannels(target.objectID)
        let tapChannels = tapFormatChannels()
        say("Aggregate input stream channels \(aggregate); target input streams \(targetInputs); tap \(tapChannels) ch")
        guard let layout = RouteStreamLayout.tapStreams(
            aggregate: aggregate, targetInputs: targetInputs, tapChannels: tapChannels)
        else {
            say("Cannot tell the tap stream from the target's input streams; refusing (deviceUnavailable)")
            return false
        }
        guard !targetInputs.isEmpty else { return true }
        let total = aggregate.count

        let header = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let size = header + total * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: max(size, MemoryLayout<AudioHardwareIOProcStreamUsage>.size),
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(total)

        var addr = AudioHAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var dataSize = UInt32(size)
        var status = AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &dataSize, raw)
        guard status == noErr else {
            say("Reading IOProc stream usage failed: \(status); refusing (deviceUnavailable)")
            return false
        }
        let flags = (raw + header).bindMemory(to: UInt32.self, capacity: total)
        for index in 0..<total { flags[index] = layout[index] ? 1 : 0 }
        status = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(size), raw)
        guard status == noErr else {
            say("Setting IOProc stream usage failed: \(status); refusing (deviceUnavailable)")
            return false
        }
        say("Input stream usage: " + (0..<total).map { flags[$0] == 0 ? "off" : "on" }.joined(separator: ", "))
        return true
    }

    // MARK: Probe → active

    private func watchProbe(passthrough: Bool) async {
        let started = clock.now
        var reportedTimeout = false
        while !Task.isCancelled, state.isProbing {
            if state.sawSignal {
                say("Permission confirmed: first non-zero frame after \(clock.now - started)")
                activate(passthrough: passthrough)
                break
            }
            if !reportedTimeout, clock.now - started > Self.probeTimeout {
                reportedTimeout = true
                say("No signal after \(Self.probeTimeout); app isRunningOutput=\(isAppRunningOutput()). "
                    + "Permission missing, or the app is silent. Still probing.")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            say("Status: \(state.isProbing ? "probing" : passthrough ? "passthrough" : "routing"), "
                + "gain \(state.targetGain), app isRunningOutput=\(isAppRunningOutput())")
        }
    }

    /// Fixed order, so a switch can only cause silence, never doubled audio:
    /// routing mutes the tap first and then lets the IOProc write; passthrough stops the IOProc
    /// (the tap stays unmuted).
    private func activate(passthrough: Bool) {
        let started = clock.now
        if passthrough {
            if let procID { AudioDeviceStop(aggregateID, procID) }
            isRunning = false
            state.isProbing = false
            say("Passthrough: IOProc stopped in \(clock.now - started)")
            return
        }
        guard let tapDescription else { return }
        tapDescription.muteBehavior = .muted
        // The property value is an object reference, so its size is a pointer's.
        var description = tapDescription
        var addr = AudioHAL.address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &description) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<UnsafeRawPointer>.size), $0)
        }
        guard status == noErr else {
            tapDescription.muteBehavior = .unmuted
            say("Muting the tap in place failed: \(status); staying in probe (app keeps playing on its device)")
            return
        }
        state.isProbing = false
        say("Routing: tap muted in place and IOProc writing after \(clock.now - started)")
    }

    // MARK: Diagnostics

    /// Channel count of each input stream of a device, in the device's stream order.
    private func streamChannels(_ device: AudioObjectID) -> [UInt32] {
        var addr = AudioHAL.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.prefix(Int(size) / MemoryLayout<AudioStreamID>.size).map { stream in
            format(stream, kAudioStreamPropertyVirtualFormat)?.mChannelsPerFrame ?? 0
        }
    }

    private func tapFormatChannels() -> UInt32 {
        format(tapID, kAudioTapPropertyFormat)?.mChannelsPerFrame ?? 0
    }

    private func format(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
        var addr = AudioHAL.address(selector)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func isAppRunningOutput() -> Bool {
        var addr = AudioHAL.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioHAL.system, &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioHAL.system, &addr, 0, nil, &size, &ids) == noErr else { return false }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).contains { id in
            guard let bundleID = AudioHAL.string(id, kAudioProcessPropertyBundleID),
                  bundleID == request.bundleID || bundleID.hasPrefix(request.bundleID + ".")
            else { return false }
            return AudioHAL.uint32(id, kAudioProcessPropertyIsRunningOutput) == 1
        }
    }

    private func logLatency() {
        let scope = kAudioObjectPropertyScopeOutput
        let latency = AudioHAL.uint32(aggregateID, kAudioDevicePropertyLatency, scope) ?? 0
        let safety = AudioHAL.uint32(aggregateID, kAudioDevicePropertySafetyOffset, scope) ?? 0
        let buffer = AudioHAL.uint32(aggregateID, kAudioDevicePropertyBufferFrameSize, scope) ?? 0
        var addr = AudioHAL.address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &rate)
        let frames = Double(latency + safety + buffer)
        let ms = rate > 0 ? frames / rate * 1000 : 0
        say("Aggregate output: latency \(latency) + safety \(safety) + buffer \(buffer) frames at \(Int(rate)) Hz "
            + "≈ \(String(format: "%.1f", ms)) ms")
    }

    private func say(_ message: String) {
        Self.logger.notice("\(message, privacy: .public)")
        print("[route-spike] \(message)")
    }
}
#endif
