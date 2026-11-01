# How SoundU works

SoundU is a single menu-bar app: no audio driver, no helper process, no admin install. Everything uses
Core Audio APIs that ship with macOS 14.2+ (process taps and private aggregate devices), plus one undocumented
device property for Call Guard.

## The audio path

```
 app (e.g. Spotify) ──► process tap ──► private aggregate device ──► IOProc (C mixer) ──► real output device
                        (muted while        (one per output            gain ramp, limiter,
                         SoundU reads it)    device × app)              mute, meter
```

1. **Find who is playing.** `ProcessMonitor` reads `kAudioHardwarePropertyProcessObjectList` and each process's
   PID, bundle ID and running-output state, re-reading on every change (debounced 100 ms, at most 400 ms).
2. **Group processes into apps.** Helpers are attributed to their app (Chrome's renderer helpers → Chrome,
   WebKit's GPU process → Safari) via the responsible PID, then the parent-PID chain, then bundle-ID prefix.
   FaceTime's call service processes count as FaceTime. A process that serves a calling app is never split.
3. **Plan.** `plan(_:)` is a pure function: every app that is playing (or played in the last 5 s) is routed
   to its chosen output device, or the default. SoundU itself, calling apps during a call, and bare OS daemons
   are excluded. **System Sounds** (`/usr/sbin/systemsoundserverd`) is pinned: routed even while idle, so its
   volume applies from the first sample of a notification (except on Bluetooth outputs, where it is routed only
   on demand to avoid keeping the headphones streaming).
4. **Engine.** For each (output device, app) pair, `AudioEngine` creates
   - a **process tap** — `CATapDescription(stereoMixdownOfProcesses:)`, private, `muteBehavior = .mutedWhenTapped`,
     so the app's own output is silenced only while SoundU is actually reading the tap;
   - a **private aggregate device** whose main sub-device and clock are the real output device and whose tap list
     holds that one tap (drift compensation on, tap auto-start);
   - one **IOProc** on the aggregate's HAL IO thread that calls the C mixer.

   One aggregate per app (not per device) matters: changing an aggregate's tap list restarts its IO, so a shared
   aggregate would glitch every app whenever any app started or stopped (e.g. a notification sound).
5. **Mixing (C, real-time).** `CSoundUDSP` does a 10 ms gain ramp, mute as a ramp to zero, a look-ahead-free peak
   limiter (ceiling 0.995) when gain is above 1.0, peak metering through C11 atomics, and writes stereo to the first
   two output channels. No allocation, locks, logging or Swift/Objective-C calls run on the IO thread.

The device's own input streams are disabled for the IOProc (`kAudioDevicePropertyIOProcStreamUsage`), so routing
to a headset never opens its microphone.

## Call Guard

When a calling app (WhatsApp, FaceTime) starts voice processing, macOS's audio server registers it as a
**ducker** on the output device and turns every other client — a **duckee** — down to about 18 % (−15 dB).
A client can opt out of ducking with the device property `'nodk'` (output scope, `UInt32` 1/0). It is not in the
public headers but is settable from user space.

SoundU sets `'nodk'` = 1 on each real output device it plays to, while it plays. Because the apps it routes are
heard through SoundU's own output, they keep their level; the process tap captures each app *before* the duck is
applied. The calling app itself is detected (input and output both running, with a 5 s grace period for mic
pauses) and never tapped, so call audio is untouched. While VoiceOver runs, the opt-out is skipped so VoiceOver can
still duck other audio.

## Never silent

- Taps are private and `.mutedWhenTapped`: if SoundU quits, crashes or stops reading, apps play directly again.
  Quitting saves settings and exits without tearing down audio objects, which vanish with the process.
- An IO watchdog tears down any graph whose IO stops advancing for 2 s (the app then plays directly) and retries
  with back-off. If no IO is ever seen, SoundU reports that Audio Capture permission is missing.
- A failed tap leaves that app playing directly, with an error on its strip.

## Latency

A routed app gains about 27 ms (128-frame buffer plus the aggregate's input safety offset reported by the HAL).

## Source map

| Path | Role |
|---|---|
| `Sources/CSoundUDSP/` | Real-time DSP in C: ramp, limiter, mixer, meters |
| `Sources/SoundUCore/HAL/` | Core Audio wrapper (`AudioSystem` protocol; `CoreAudioSystem` live implementation) |
| `Sources/SoundUCore/Apps/` | Process monitoring and grouping into apps |
| `Sources/SoundUCore/Routing/` | Pure routing planner |
| `Sources/SoundUCore/Engine/` | Taps, aggregates, IOProcs, watchdog, ducking opt-out |
| `Sources/SoundUCore/CallGuard/` | Call detection and Call Guard status |
| `Sources/SoundUCore/SoundUController.swift` | Main-actor glue between monitors, planner, engine, settings and UI |
| `Sources/SoundU/` | SwiftUI menu-bar app, settings, first-run sheet |
| `Tests/` | XCTest suites; Core Audio is replaced by `FakeAudioSystem` except in opt-in hardware tests (`SOUNDU_HW_TESTS=1`) |
