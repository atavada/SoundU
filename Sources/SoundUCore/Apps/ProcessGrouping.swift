import CoreAudio
import Foundation

/// A running application as seen by `NSWorkspace` (regular or accessory activation policy).
public struct RunningApp: Equatable, Sendable {
    public var pid: pid_t
    public var bundleID: String
    public var name: String

    public init(pid: pid_t, bundleID: String, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

/// One user-facing app and the Core Audio processes that make its sound.
public struct AudioApp: Equatable, Identifiable, Sendable {
    /// Owner bundle ID (or executable name for a process with no bundle ID).
    public var id: String
    public var name: String
    /// Sorted by `objectID`.
    public var processes: [ProcessSnapshot]
    public var isPlaying: Bool { processes.contains { $0.isRunningOutput } }

    public init(id: String, name: String, processes: [ProcessSnapshot]) {
        self.id = id
        self.name = name
        self.processes = processes
    }
}

public struct Grouping: Equatable, Sendable {
    /// Sorted by name, then id. Every process appears in exactly one app.
    public var apps: [AudioApp]
    /// Processes that serve more than one app → every owner, the primary one included.
    public var sharedOwners: [AudioObjectID: Set<String>]

    public init(apps: [AudioApp] = [], sharedOwners: [AudioObjectID: Set<String>] = [:]) {
        self.apps = apps
        self.sharedOwners = sharedOwners
    }
}

enum CallServices {
    static let faceTime = "com.apple.FaceTime"
    /// Apps `avconferenced` / `callservicesd` may be serving: FaceTime, Phone, Home,
    /// Screen Sharing, Remote Desktop.
    static let sharingApps: Set<String> = [
        faceTime, "com.apple.mobilephone", "com.apple.Home", "com.apple.ScreenSharing", "com.apple.RemoteDesktop",
    ]

    static func isCallProcess(_ p: ProcessSnapshot) -> Bool {
        let exe = executableName(p)
        return p.bundleID == "com.apple.avconferenced" || exe == "avconferenced" || exe == "callservicesd"
    }
}

func executableName(_ p: ProcessSnapshot) -> String {
    (p.executablePath as NSString).lastPathComponent
}

/// Groups Core Audio processes into apps. Owner = first match of:
/// 1. `avconferenced` / `callservicesd` → FaceTime (shared with every running call-capable app);
/// 2. the responsible PID is a running app;
/// 3. walking parent PIDs (through other audio processes) reaches a running app;
/// 4. a running app's bundle ID is a dotted prefix of the process's bundle ID;
/// 5. the process itself.
/// When (2) and (3) find different apps the process is shared; (2) is its primary owner.
public func groupProcesses(_ procs: [ProcessSnapshot], runningApps: [RunningApp]) -> Grouping {
    let appsByPID = Dictionary(runningApps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    let namesByBundle = Dictionary(runningApps.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
    let procsByPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

    func parentChainApp(_ p: ProcessSnapshot) -> RunningApp? {
        var pid = p.parentPID
        var visited: Set<pid_t> = [p.pid]
        while pid > 1, visited.insert(pid).inserted {
            if let app = appsByPID[pid] { return app }
            guard let next = procsByPID[pid] else { return nil }
            pid = next.parentPID
        }
        return nil
    }

    func prefixApp(_ bundleID: String?) -> RunningApp? {
        guard let bundleID else { return nil }
        return runningApps
            .filter { bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }

    /// Primary owner (ID and display name) plus every owner, the primary included.
    func owners(_ p: ProcessSnapshot) -> (id: String, name: String, all: Set<String>) {
        if CallServices.isCallProcess(p) {
            let id = CallServices.faceTime
            let running = Set(runningApps.map(\.bundleID)).intersection(CallServices.sharingApps)
            return (id, namesByBundle[id] ?? "FaceTime", running.union([id]))
        }
        let responsible = appsByPID[p.responsiblePID]
        let chain = parentChainApp(p)
        if let owner = responsible ?? chain {
            return (owner.bundleID, owner.name, Set([responsible, chain].compactMap { $0?.bundleID }))
        }
        if let owner = prefixApp(p.bundleID) { return (owner.bundleID, owner.name, [owner.bundleID]) }
        if let bundleID = p.bundleID {
            return (bundleID, bundleID.split(separator: ".").last.map(String.init) ?? bundleID, [bundleID])
        }
        let exe = executableName(p)
        let id = exe.isEmpty ? "pid-\(p.pid)" : exe
        return (id, id, [id])
    }

    var members: [String: (name: String, processes: [ProcessSnapshot])] = [:]
    var shared: [AudioObjectID: Set<String>] = [:]
    for p in procs {
        let owner = owners(p)
        members[owner.id, default: (owner.name, [])].processes.append(p)
        if owner.all.count > 1 { shared[p.objectID] = owner.all }
    }

    let apps = members.map { id, member in
        AudioApp(id: id, name: member.name, processes: member.processes.sorted { $0.objectID < $1.objectID })
    }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    return Grouping(apps: apps, sharedOwners: shared)
}
