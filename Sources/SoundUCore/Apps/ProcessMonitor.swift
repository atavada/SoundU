import AppKit
import CoreAudio
import Foundation

/// Keeps a current `Grouping`: re-reads the HAL process list (and running apps) after every
/// `.processes` change, coalescing bursts with a 100 ms trailing debounce that never delays a
/// refresh more than 400 ms past the first pending event.
public final class ProcessMonitor: @unchecked Sendable {
    static let debounce: DispatchTimeInterval = .milliseconds(100)
    static let maxWait: DispatchTimeInterval = .milliseconds(400)

    private let system: AudioSystem
    private let runningApps: @Sendable () -> [RunningApp]
    private let queue = DispatchQueue(label: "io.github.atavada.SoundU.ProcessMonitor")
    private let lock = NSLock()
    private var grouping = Grouping()
    private var _onChange: (@Sendable (Grouping) -> Void)?
    /// Touched only on `queue`.
    private var pending: DispatchWorkItem?
    /// When the first event of the current burst arrived; touched only on `queue`.
    private var burstStart: DispatchTime?
    private var token: AnyObject?

    /// Called on a background queue with the initial grouping on `start()`, then whenever it changes.
    public var onChange: (@Sendable (Grouping) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    public init(system: AudioSystem,
                runningApps: @escaping @Sendable () -> [RunningApp] = ProcessMonitor.workspaceApps) {
        self.system = system
        self.runningApps = runningApps
    }

    /// Reads the current grouping and starts listening. Calling it again is a no-op.
    public func start() {
        guard lock.withLock({ token == nil }) else { return }
        let observation = system.observe { [weak self] change in
            guard change == .processes else { return }
            self?.scheduleRefresh()
        }
        lock.withLock { token = observation }
        queue.sync { refresh(force: true) }
    }

    public func current() -> Grouping {
        lock.withLock { grouping }
    }

    private func scheduleRefresh() {
        queue.async { [weak self] in
            guard let self else { return }
            pending?.cancel()
            let now = DispatchTime.now()
            let start = burstStart ?? now
            burstStart = start
            let work = DispatchWorkItem { [weak self] in
                self?.burstStart = nil
                self?.refresh(force: false)
            }
            pending = work
            queue.asyncAfter(deadline: min(now + Self.debounce, start + Self.maxWait), execute: work)
        }
    }

    /// Runs on `queue`.
    private func refresh(force: Bool) {
        let next = groupProcesses(system.processes(), runningApps: runningApps())
        let (changed, callback) = lock.withLock { () -> (Bool, (@Sendable (Grouping) -> Void)?) in
            let changed = next != grouping
            grouping = next
            return (changed, _onChange)
        }
        if changed || force { callback?(next) }
    }

    /// Regular and accessory apps from `NSWorkspace`.
    public static func workspaceApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited, let bundleID = app.bundleIdentifier else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
    }
}
