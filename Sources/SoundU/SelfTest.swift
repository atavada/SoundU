#if DEBUG
import CoreAudio
import Foundation
import SoundUCore

/// `SoundU --selftest`: exercises the real engine against the default output device with
/// `afplay` tones. Runs inside the app bundle so Audio Capture permission is attributed to it.
/// Prints `PASS <name> <detail>` / `FAIL <name> <detail>` per check; returns the exit code.
@MainActor
enum SelfTest {
    private static let latencyTargetMs = 30.0
    private static let peakRange: ClosedRange<Float> = 0.05...0.2

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [EngineEvent] = []
        var all: [EngineEvent] { lock.lock(); defer { lock.unlock() }; return _all }
        func append(_ e: EngineEvent) { lock.lock(); _all.append(e); lock.unlock() }
    }

    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String, _ detail: String) {
        print("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
        if !ok { failures += 1 }
    }

    static func run() async -> Int32 {
        setlinebuf(stdout)
        let system = CoreAudioSystem()
        guard let uid = system.defaultOutputDeviceUID(),
              let device = system.outputDevices().first(where: { $0.uid == uid }) else {
            check(false, "setup", "no default output device")
            return 1
        }
        print("INFO device \(device.name) uid=\(uid) rate=\(device.sampleRate)")

        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("soundu-selftest-440.wav")
        do { try writeTone(to: wav) } catch {
            check(false, "setup", "cannot write \(wav.path): \(error)")
            return 1
        }
        var players: [Process] = []
        defer { players.forEach { $0.terminate() } }

        guard let first = await startPlayer(wav, system, &players) else {
            check(false, "setup", "afplay did not start playing within 3 s")
            return 1
        }
        let one = TapSpec(appID: "selftest.afplay.1", processObjectIDs: [first])

        let events = Events()
        let engine = AudioEngine(system: system)
        engine.onEvent = { events.append($0) }
        engine.setDuckingExempt(true)
        engine.apply(RoutingPlan(byDevice: [uid: [one]], excluded: [:]))
        defer { engine.stopAll() }

        guard let aggregate = engine.runningAggregates[GraphKey(deviceUID: uid, appID: one.appID)] else {
            check(false, "start", "no graph started: \(events.all)")
            return 1
        }

        // (a) The tap captures the tone.
        try? await Task.sleep(for: .seconds(1))
        let peak = engine.takePeaks()[one.appID] ?? 0
        if peak == 0 {
            try? await Task.sleep(for: .seconds(1.5))
            engine.checkIO() // the app's controller runs this watchdog on every re-plan
            if events.all.contains(.permissionPending) {
                check(false, "permission", "no IO callbacks within 2 s (Audio Capture permission pending or denied)")
                return 1
            }
        }
        check(peakRange.contains(peak), "tap-captures-tone", String(format: "peak=%.4f", peak))

        // (b) Added latency.
        let latency = events.all.compactMap { e -> Double? in
            if case .deviceStarted(uid, _, let ms) = e { return ms } else { return nil }
        }.first ?? .infinity
        let latencyOK = latency <= latencyTargetMs
        check(latencyOK, "added-latency", String(format: "%.2f ms (target <= %.1f, buffer 128, drift on)",
                                                 latency, latencyTargetMs))

        // (c) A second app on the same device gets its own aggregate; the first one's is untouched.
        if let second = await startPlayer(wav, system, &players) {
            let two = TapSpec(appID: "selftest.afplay.2", processObjectIDs: [second])
            engine.apply(RoutingPlan(byDevice: [uid: [one, two]], excluded: [:]))
            let after = engine.runningAggregates[GraphKey(deviceUID: uid, appID: one.appID)]
            let secondAggregate = engine.runningAggregates[GraphKey(deviceUID: uid, appID: two.appID)]
            _ = engine.takePeaks()
            try? await Task.sleep(for: .seconds(1))
            let peaks = engine.takePeaks()
            let p1 = peaks[one.appID] ?? 0, p2 = peaks[two.appID] ?? 0
            check(after == aggregate && secondAggregate.map { $0 != aggregate } == true
                  && peakRange.contains(p1) && peakRange.contains(p2), "aggregate-per-app",
                  String(format: "first %u -> %u, second %u, peak1=%.4f peak2=%.4f",
                         aggregate, after ?? 0, secondAggregate ?? 0, p1, p2))
        } else {
            check(false, "aggregate-per-app", "second afplay did not start playing within 3 s")
        }

        // (d) 'nodk' on the physical sub-device while running, cleared after stopAll.
        let noDuckRunning = noDuck(device.id)
        let aggregatesRunning = soundUAggregates().count
        engine.stopAll()
        let noDuckStopped = noDuck(device.id)
        check(noDuckRunning == 1 && noDuckStopped == 0, "nodk",
              "running=\(noDuckRunning.map(String.init) ?? "nil") stopped=\(noDuckStopped.map(String.init) ?? "nil")")

        // (e) stopAll leaves no SoundU aggregates.
        let left = await aggregatesAfterSettling()
        check(aggregatesRunning > 0 && left.isEmpty, "no-leftover-aggregates",
              "while running=\(aggregatesRunning) after stopAll=\(left.count)")

        // Latency alternatives, for the record (the target itself is not changed).
        for (frames, drift) in [(UInt32(64), true), (128, false), (64, false)] {
            let ms = await measureLatency(uid: uid, spec: one, bufferFrames: frames, drift: drift)
            print("INFO latency buffer=\(frames) drift=\(drift ? 1 : 0): "
                  + (ms.map { String(format: "%.2f ms", $0) } ?? "no graph started"))
        }
        let leftAfterProbes = await aggregatesAfterSettling()
        check(leftAfterProbes.isEmpty, "no-leftover-aggregates-after-probes",
              leftAfterProbes.isEmpty ? "none" : leftAfterProbes.joined(separator: ","))

        print("DONE \(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")")
        return failures == 0 ? 0 : 1
    }

    private static func measureLatency(uid: String, spec: TapSpec, bufferFrames: UInt32, drift: Bool) async -> Double? {
        let engine = AudioEngine(system: CoreAudioSystem(tapDriftCompensation: drift), bufferFrames: bufferFrames)
        let events = Events()
        engine.onEvent = { events.append($0) }
        engine.apply(RoutingPlan(byDevice: [uid: [spec]], excluded: [:]))
        try? await Task.sleep(for: .milliseconds(300))
        engine.stopAll()
        // Let the HAL drop the destroyed aggregate before the next probe creates one.
        _ = await aggregatesAfterSettling()
        return events.all.compactMap { e -> Double? in
            if case .deviceStarted(_, _, let ms) = e { return ms } else { return nil }
        }.first
    }

    // MARK: - afplay

    /// Starts `afplay` and waits until its Core Audio process object is running output.
    private static func startPlayer(_ wav: URL, _ system: AudioSystem, _ players: inout [Process]) async -> AudioObjectID? {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wav.path]
        do { try player.run() } catch { return nil }
        players.append(player)
        for _ in 0..<60 {
            if let obj = system.processes().first(where: { $0.pid == player.processIdentifier && $0.isRunningOutput }) {
                return obj.objectID
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// 30 s, 48 kHz, 16-bit stereo, 440 Hz at -20 dBFS (amplitude 0.1).
    private static func writeTone(to url: URL) throws {
        let rate = 48_000, seconds = 30, channels = 2
        let frames = rate * seconds
        var data = Data(capacity: 44 + frames * channels * 2)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * channels * 2)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate)
        u32(rate * channels * 2); u16(channels * 2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(frames * channels * 2)
        var samples = [Int16](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = Int16((0.1 * sin(2 * Double.pi * 440 * Double(f) / Double(rate)) * 32767).rounded())
            samples[f * 2] = v
            samples[f * 2 + 1] = v
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    // MARK: - Raw HAL reads

    /// This process's SoundU aggregates once the device list settles (polls up to 2 s).
    private static func aggregatesAfterSettling() async -> [String] {
        for _ in 0..<40 {
            if soundUAggregates().isEmpty { return [] }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return soundUAggregates()
    }

    private static func noDuck(_ device: AudioObjectID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: 0x6e6f646b /* 'nodk' */, mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// UIDs of this process's SoundU aggregates in the raw device list.
    private static func soundUAggregates() -> [String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let prefix = "SoundU-Agg-\(getpid())-"
        return ids.compactMap { id in
            var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
                  let value = uid?.takeRetainedValue() as String?, value.hasPrefix(prefix) else { return nil }
            return value
        }
    }
}
#endif
