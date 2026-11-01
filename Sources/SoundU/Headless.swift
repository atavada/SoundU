#if DEBUG
import Foundation
import SoundUCore

/// `SoundU --headless [--script] [--target <substring>]`: debug command for the M1 manual check.
/// Runs the controller without UI and prints the strips once per second (level = loudest meter
/// reading in that second). `--script` uses a throwaway settings file and applies a fixed
/// sequence to the routed apps whose ID contains `--target` (all routed apps when omitted):
/// t=2 s volume 0.3, t=4 s mute, t=6 s unmute, t=8 s volume 1.0, then exits at t=10 s.
/// SIGINT/SIGTERM shut the controller down cleanly.
@MainActor
enum Headless {
    static func run(arguments: [String]) async -> Int32 {
        setlinebuf(stdout)
        let script = arguments.contains("--script")
        let target = arguments.firstIndex(of: "--target").flatMap { i in
            arguments.indices.contains(i + 1) ? arguments[i + 1] : nil
        }
        let store = script
            ? SettingsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("soundu-headless-\(getpid())/settings.json"))
            : SettingsStore.standard

        let controller = SoundUController(store: store)
        let signals = [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    print("SIGNAL \(sig): shutting down")
                    controller.shutdown()
                    exit(0)
                }
            }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }

        controller.start()
        controller.setMetering(true) // no panel here; levels are printed
        print("START pid=\(getpid()) script=\(script) target=\(target ?? "all routed")")

        var steps: [(at: Int, name: String, apply: (String) -> Void)] = script ? [
            (2, "volume 0.3", { controller.setVolume($0, 0.3) }),
            (4, "mute", { id in if controller.apps.first(where: { $0.id == id })?.muted == false { controller.toggleMute(id) } }),
            (6, "unmute", { id in if controller.apps.first(where: { $0.id == id })?.muted == true { controller.toggleMute(id) } }),
            (8, "volume 1.0", { controller.setVolume($0, 1.0) }),
        ] : []

        var maxLevels: [String: Float] = [:]
        let begin = ContinuousClock.now
        var second = 0
        while true {
            try? await Task.sleep(for: .seconds(1.0 / 30))
            for strip in controller.apps { maxLevels[strip.id] = max(maxLevels[strip.id] ?? 0, controller.levels[strip.id] ?? 0) }
            let elapsed = ContinuousClock.now - begin
            guard elapsed >= .seconds(second + 1) else { continue }
            second += 1
            printStrips(controller, second: second, levels: maxLevels)
            maxLevels = [:]

            while let step = steps.first, step.at <= second {
                steps.removeFirst()
                let ids = controller.apps.filter { strip in
                    (strip.state == .routed || strip.state == .lingering)
                        && (target.map { strip.id.contains($0) } ?? true)
                }.map(\.id)
                ids.forEach(step.apply)
                print("SCRIPT t=\(second) \(step.name) -> \(ids.isEmpty ? "(no routed apps)" : ids.joined(separator: ","))")
            }
            if script, second >= 10 {
                controller.shutdown()
                try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent())
                print("DONE script finished")
                return 0
            }
        }
    }

    private static func printStrips(_ controller: SoundUController, second: Int, levels: [String: Float]) {
        let device = controller.devices.first { $0.uid == controller.defaultDeviceUID }?.name ?? "none"
        print("t=\(second) permission=\(controller.permission) default=\(device) strips=\(controller.apps.count)")
        for strip in controller.apps {
            let output = strip.outputDeviceUID ?? "default"
            print(String(format: "  %@ [%@] %@ vol=%.0f%% muted=%@ out=%@ level=%.4f", strip.name, strip.id,
                         "\(strip.state)", strip.volume * 100, strip.muted ? "yes" : "no", output,
                         levels[strip.id] ?? 0))
        }
    }
}
#endif
