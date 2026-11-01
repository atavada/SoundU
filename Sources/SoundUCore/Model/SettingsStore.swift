import Foundation
import os

/// Loads and saves `SettingsSnapshot` as JSON at a file URL.
public final class SettingsStore: Sendable {
    public let url: URL

    private static let logger = Logger(subsystem: "io.github.atavada.SoundU", category: "settings")

    public init(url: URL) {
        self.url = url
    }

    /// The store at `~/Library/Application Support/SoundU/settings.json`.
    public static var standard: SettingsStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SettingsStore(url: support.appendingPathComponent("SoundU/settings.json"))
    }

    /// Saved settings (boost ceiling clamped to 1...2); defaults when the file is missing. An unreadable file is
    /// renamed to `settings.corrupt-<date>.json` and defaults are returned.
    public func load() -> SettingsSnapshot {
        guard let data = try? Data(contentsOf: url) else { return SettingsSnapshot() }
        do {
            var snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
            snapshot.global.boostCeiling = GlobalSettings.clampCeiling(snapshot.global.boostCeiling)
            return snapshot
        } catch {
            Self.logger.error("Settings file unreadable, using defaults: \(error.localizedDescription, privacy: .public)")
            quarantineCorruptFile()
            return SettingsSnapshot()
        }
    }

    /// Writes atomically, creating the parent directory if needed.
    public func save(_ snapshot: SettingsSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    private func quarantineCorruptFile() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(url.deletingPathExtension().lastPathComponent).corrupt-\(formatter.string(from: Date())).json"
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            Self.logger.error("Could not rename corrupt settings file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
