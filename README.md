<p align="center">
  <img src="docs/images/icon.png" width="128" alt="SoundU icon">
</p>

<h1 align="center">SoundU</h1>

<p align="center">
  A per-app volume mixer for the macOS menu bar — and it keeps your music at the level you set during calls.
</p>

<p align="center">
  <a href="https://github.com/atavada/SoundU/releases">Download</a> ·
  <a href="docs/ARCHITECTURE.md">How it works</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

> **Beta.** SoundU 0.1.0 is an early release. It works on the developer's Mac, but expect rough edges.
> Please [report problems](https://github.com/atavada/SoundU/issues).

## Features

- **Per-app volume** from 0 to 200 %. Above 100 % a limiter stops the boost from clipping.
- **Per-app mute** that fades instead of clicking.
- **Per-app output device** — send Spotify to your headphones while Chrome plays on the speakers.
- **Live level meters** for every app.
- **Call Guard** — during a WhatsApp or FaceTime call, macOS normally turns every other app down (“ducking”).
  Call Guard keeps them at the volume you chose. The call itself is never touched.
- **System Sounds** strip for notifications and alerts, so you can turn them down or mute them.
- Settings are remembered per app; optional launch at login.

SoundU lives in the menu bar only (no Dock icon). Click its icon to open a small mixing desk: one channel strip per
app that is playing sound, plus a master strip for your output device.

## Requirements

- macOS 14.4 or later (developed and tested on macOS 26).
- Apple silicon or Intel (universal app).

## Install

1. Download `SoundU-<version>.zip` from the [Releases](https://github.com/atavada/SoundU/releases) page and unzip it.
2. Move **SoundU.app** to your **Applications** folder.
3. Open it. SoundU is not notarized by Apple yet, so the first launch is blocked:
   open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the SoundU message.
   (Or run `xattr -dr com.apple.quarantine /Applications/SoundU.app` in Terminal.)
4. Click **Continue** on the welcome window, then **Allow** when macOS asks whether SoundU may record audio from
   other apps. SoundU needs this to change other apps' volume; nothing is recorded or saved.

If the permission prompt doesn't appear, or SoundU shows a permission banner, turn SoundU on under
**System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only**,
then click **Try Again** in SoundU's panel.

## Using SoundU

| To… | Do this |
|---|---|
| Change an app's volume | Drag its fader. Double-click the fader to reset to 100 %. Scroll over a strip to adjust; hold **Option** for fine steps. |
| Mute an app | Click the speaker button on its strip. |
| Send an app to another output | Click the device chip at the bottom of its strip. |
| Turn Call Guard on or off | Click the **Call Guard** pill at the top of the panel. |
| Change which apps count as calls | Call Guard pill → **Edit Call Apps…** (default: WhatsApp, FaceTime, Phone). |
| Allow boost above 100 % | **Settings → General → Boost ceiling**. |

During a call the calling app's strip shows a lock: SoundU never routes, mutes or changes call audio.

## Build from source

Requires Xcode 26 (Swift 6.2).

```bash
git clone https://github.com/atavada/SoundU.git
cd SoundU
swift test                          # unit tests
scripts/build-app.sh                # debug build → build/SoundU.app
scripts/build-app.sh --release      # universal release build
scripts/build-app.sh --install      # release build, copied to /Applications
```

Builds are signed ad-hoc unless `SOUNDU_SIGN_IDENTITY` names a signing identity. With ad-hoc signing every
rebuild is a new app to macOS, so the audio permission must be granted again:

```bash
tccutil reset AudioCapture io.github.atavada.SoundU
```

Debug builds also accept `--selftest` (engine hardware check) and `--headless` (prints each app's routing state
once a second). Run them inside the bundle so macOS attributes the permission correctly:
`open -n -W --stdout /tmp/soundu.out build/SoundU.app --args --headless`.

## Known issues (beta)

- On the first launch after a rebuild, the panel can freeze for up to a minute while macOS shows the permission prompt.
- Each app routed through SoundU gains about 27 ms of audio delay; video lip sync may be very slightly late.
- On AirPods and other Bluetooth outputs, the first instant of a notification can play before the System Sounds volume applies.
- Only WhatsApp and FaceTime calls are covered by default; other calling apps can be added to the call-app list but are untested.
- Call Guard relies on an undocumented macOS audio property; a future macOS update could change its behaviour.

## Privacy

SoundU processes audio in memory to change its volume and sends it straight to your output device.
It never records, saves or uploads audio, and it makes no network connections.

## License

SoundU is free software, licensed under the [GNU General Public License v3.0](LICENSE).

SoundU is an independent project and is not affiliated with Apple or any other audio software vendor.
