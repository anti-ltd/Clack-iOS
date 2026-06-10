<div align="center">

<img src="Resources/banner.png" alt="Clack">

<br>

<img src="https://raw.githubusercontent.com/opensourcevillain/resources/bc6072cd7f49dc155b47c88e79daa9d49ece9b7e/OpenSourceVillain/Banner.png" alt="Open Source Villain">

<br><br>

# Clack

**Push-to-talk for iPhone. Hold, talk, done.**

![Platform](https://img.shields.io/badge/iOS%2017%2B-black?style=flat-square)
![Language](https://img.shields.io/badge/Swift%206.0-orange?style=flat-square&logo=swift)
[![License](https://img.shields.io/badge/license-CLL%20v1.2-blue?style=flat-square)](LICENSE.md)
![Status](https://img.shields.io/badge/status-alpha-yellow?style=flat-square)

![Offline-first](https://img.shields.io/badge/offline--first-✓-22c55e?style=flat-square)
![No accounts](https://img.shields.io/badge/no%20accounts-✓-22c55e?style=flat-square)
![One-time purchase](https://img.shields.io/badge/one--time%20purchase-✓-22c55e?style=flat-square)

</div>

---

> Apple retired Walkie-Talkie in iOS 27. Clack is the replacement — a proper
> push-to-talk app built on Apple's **PushToTalk** framework, so transmissions
> ride the real system UI: the blue status pill, the lock-screen "joined"
> banner, the leading lock-screen talk button, and proper audio-session ducking.

---

## Build

Requires **Xcode 16+** with the **iOS 17+ platform installed** (Xcode →
Settings → Components), and `xcodegen` (`brew install xcodegen`).

Targets **iOS 17+**. Glass (`.glassEffect`) is a progressive enhancement gated
behind `#available(iOS 26, *)` — users below 26 get a clean solid-fill UI.

Depends on **[iUX-ios](../iUX-ios)** — shared iOS design-system library — via
a local path. Check it out as a sibling directory before building:

```
Projects/
├── Clack-iOS/      ← this repo
└── iUX-iOS/        ← shared iOS design system
```

```bash
make icon      # render the app icon from Tools/RenderAppIcon.swift
make project   # regenerate Clack.xcodeproj from project.yml (needs xcodegen)
make build     # xcodebuild for the iOS Simulator
make run       # boot the sim, install, launch
make device    # build, sign, install on the paired iPhone
make clean     # remove build/ and Clack.xcodeproj
make help      # list every target
```

The `.xcodeproj` is generated from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and is gitignored —
**`project.yml` is the source of truth**, never edit the generated `.xcodeproj`
by hand.

> **PushToTalk only works on a physical device.** The framework needs the
> `com.apple.developer.push-to-talk` entitlement and refuses to activate in the
> Simulator. `make run` builds and launches in the sim for UI work; use
> `make device` to exercise the actual PTT system UI.

## Running on your iPhone

```bash
make device          # build, install, launch on the paired phone
make device-install  # build + install (no launch)
make device-launch   # re-launch what's already installed
```

`make device` wraps `xcrun devicectl`. Before the first run: cable the iPhone,
unlock it and accept **"Trust This Computer"**, then `xcrun devicectl list
devices` to confirm it's paired. Override the target with `DEVICE=<udid>` or
`DEVICE_NAME="My iPhone"` when more than one is connected.

`make device` runs `xcodebuild -allowProvisioningUpdates` against Apple
Developer team `8248296AJX` (declared in `project.yml`), which auto-generates a
development profile the first time it sees a new paired phone.

## Architecture

```
Sources/Clack/
├── ClackApp.swift            @main entry point; activates the channel manager
├── AppModel.swift            observable app state + channel directory
├── AppSettings.swift         persisted user settings
├── PushToTalk/
│   └── ChannelManager.swift  bridge to Apple's PTChannelManager
└── UI/
    └── RootView.swift        channel list + press-and-hold talk surface
```

`ChannelManager` owns the `PTChannelManager` lifecycle — join/leave, begin/stop
transmitting, and the APNs token plumbing for incoming transmissions. The
**voice transport itself** (mic capture + shipping audio between peers + the
server sending `pushtotalk` APNs payloads) is the next milestone; the current
code lights up the system PTT UI but does not yet move audio.

`Tools/RenderAppIcon.swift` is a standalone Swift script that renders the app
icon into `Resources/Assets.xcassets` — run it with `make icon`.

## License

Clack is source-available under the **Counter-Limitation License (CLL)
v1.2** — see [LICENSE.md](LICENSE.md).

© 2026 Anti Limited.
