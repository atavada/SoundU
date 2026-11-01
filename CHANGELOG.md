# Changelog

All notable changes to SoundU are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.0-beta.1] — 2026-11-01

First public beta.

### Added
- Per-app volume (0–200 %, with a limiter above 100 %), mute and output device, with live meters.
- Mixing-desk menu-bar panel, master strip for the default output device, settings window and first-run sheet.
- Call Guard: other apps keep their volume during WhatsApp and FaceTime calls; call audio is never routed.
- Permanent **System Sounds** strip to adjust or mute notification and alert sounds.
- Settings remembered per app; launch at login.
- Universal build (Apple silicon and Intel), macOS 14.4 or later.

### Known issues
- The panel can freeze for up to a minute on the first launch after a rebuild while the permission prompt is pending.
- About 27 ms of added audio delay per routed app.
- Not notarized: the first launch must be approved in System Settings → Privacy & Security.

[0.1.0-beta.1]: https://github.com/atavada/SoundU/releases/tag/v0.1.0-beta.1
