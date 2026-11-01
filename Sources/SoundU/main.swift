// SoundU app entry point: placeholder until the menu-bar UI task replaces it.
// `SoundU --selftest` runs the engine hardware self-test and `SoundU --headless` the controller
// debug command; the app entry point must keep both dispatches.
import Foundation

if CommandLine.arguments.contains("--selftest") {
    exit(await SelfTest.run())
}
if CommandLine.arguments.contains("--headless") {
    exit(await Headless.run(arguments: CommandLine.arguments))
}
