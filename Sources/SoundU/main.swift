// SoundU app entry point: placeholder until the menu-bar UI task replaces it.
// `SoundU --selftest` runs the engine hardware self-test; the app entry point must keep this dispatch.
import Foundation

if CommandLine.arguments.contains("--selftest") {
    exit(await SelfTest.run())
}
