import XCTest
@testable import SoundUCore

final class SettingsTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundUSettingsTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTrip() throws {
        let store = SettingsStore(url: url)
        var snapshot = SettingsSnapshot()
        snapshot.apps["com.spotify.client"] = AppSetting(volume: 0.5, muted: true, outputDeviceUID: "BuiltIn")
        snapshot.global.boostCeiling = 1.5
        snapshot.global.firstRunDone = true
        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
    }

    func testUnknownDeviceUIDKept() throws {
        let store = SettingsStore(url: url)
        var snapshot = SettingsSnapshot()
        snapshot.apps["com.apple.Music"] = AppSetting(volume: 1, muted: false, outputDeviceUID: "Gone-Device")
        try store.save(snapshot)
        XCTAssertEqual(store.load().apps["com.apple.Music"]?.outputDeviceUID, "Gone-Device")
    }

    func testVolumeClampedToCeiling() {
        var snapshot = SettingsSnapshot()
        snapshot.apps["com.apple.Music"] = AppSetting(volume: 2.0, muted: false, outputDeviceUID: nil)
        snapshot.global.boostCeiling = 1.5
        XCTAssertEqual(snapshot.setting(for: "com.apple.Music").volume, 1.5)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x7B]).write(to: url)
        let store = SettingsStore(url: url)
        XCTAssertEqual(store.load(), SettingsSnapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("settings.corrupt-") && $0.hasSuffix(".json") }.count, 1)
    }

    func testMissingAppReturnsDefault() {
        XCTAssertEqual(SettingsSnapshot().setting(for: "com.unknown.App"), AppSetting.default)
    }
}
