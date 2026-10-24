<p align="center"><img src="design/out/nearclip-512.png" width="128" alt="Nearclip"></p>

<h1 align="center">Nearclip</h1>
<p align="center"><b>Copy here. Paste there.</b><br>A universal clipboard for Mac, Windows, Android and iPhone — device to device, with no Nearclip server.</p>

<p align="center"><a href="README.ko.md">한국어</a></p>

---

Copy on one device, paste on any other. Nearclip keeps the clipboard — and a shared, searchable history — in sync
between your own devices on the same Wi-Fi and, with **Remote connection** on, across networks too (home, office,
mobile data). There is **no Nearclip server and no Nearclip account**: on the local network devices find each other with
Bonjour/mDNS and talk directly over TCP; across networks an embedded Tailscale node carries the same connection (you
sign in with a free Tailscale account). Either way everything is **end-to-end encrypted** with keys that only your
devices hold.

| | macOS | Windows | Android | iOS / iPadOS |
|---|---|---|---|---|
| App | menu bar app + Spotlight-style panel | tray app + Win+V-style flyout | Material 3 app + background service | SwiftUI app |
| Language / UI | Swift · SwiftUI + AppKit | C# · WinUI 3 (Windows App SDK) | Kotlin · Jetpack Compose | Swift · SwiftUI |
| Sending | automatic on copy | automatic on copy | open app, tile, notification, share, text selection; optional instant text capture with Shizuku | Paste button / automatic on open |
| Receiving | automatic (+ toast, with progress for large images) | automatic (+ toast, with progress for large images) | automatic in background (+ progress notification for large images) | while open (+ catch-up on open) |
| Folder | `apple/macOS` | `windows/` | `android/` | `apple/iOS` |

All four are native apps (no Electron, no web views).

<table>
<tr>
<td align="center"><img src="docs/screenshots/macos/ko-dark-panel.png" width="230"><br><sub>macOS · menu bar panel (⌃⌘V)</sub></td>
<td align="center"><img src="docs/screenshots/windows/ko-dark-flyout.png" width="230"><br><sub>Windows · tray flyout (Win+Alt+V)</sub></td>
<td align="center"><img src="docs/screenshots/android/ko-light/01-history.png" width="190"><br><sub>Android · history</sub></td>
<td align="center"><img src="docs/screenshots/ios/ko-06-home-history.png" width="190"><br><sub>iPhone · history + Paste bar</sub></td>
</tr>
</table>


## Features

* **Real-time sync** of text, links, colors and images (up to 32 MB).
* **Large images show up right away**: the device that copies an image tells the others before it encodes it, so they
  show *Receiving an image from iPhone…* with a progress bar and the size at once — in the toast on computers, as a card
  in the phone apps, as a quiet banner on Android in the background — and the same place turns into *Copied from
  iPhone* when it is in.
* **Shared history** on every device: search, filters (Text · Links · Images · Pinned), pin, delete everywhere.
* **Pairing without accounts**: scan a QR code with a phone (or the system camera), or pick a nearby computer and compare
  a 6-digit code on both screens. Any paired device can add more devices.
* **Mesh sync**: every device connects to every reachable device; clips are forwarded, so partially connected networks
  still converge. Devices that were away catch up on the last 7 days when they come back.
* **Remote connection** (optional): turn on *Sync across networks* and sign in with the same free Tailscale account on
  each device. Every app embeds its own Tailscale node — nothing else to install, no VPN profile — and the devices reach
  each other through it: directly when NAT traversal works, through Tailscale's relays (DERP) otherwise. Wi-Fi stays
  preferred, and each device shows how it is connected (*Connected · Same network* or *Connected · Remote*).
* **Private by design**: items marked as private by password managers are never synced (macOS `org.nspasteboard.ConcealedType`,
  Windows `ExcludeClipboardContentFromMonitorProcessing`…, Android `EXTRA_IS_SENSITIVE`), per-app ignore list on computers,
  pause switch, delete-everywhere.
* **Native polish**: Liquid Glass on macOS 26+, Mica on Windows 11, Material You on Android, SwiftUI on iOS; light/dark;
  English and Korean; keyboard-first desktop panels (⌃⌘V on Mac, Win+Alt+V on Windows).

<table>
<tr>
<td align="center"><img src="docs/screenshots/macos/ko-light-devices-remote.png" width="230"><br><sub>macOS · Devices</sub></td>
<td align="center"><img src="docs/screenshots/windows/ko-dark-devices-remote.png" width="230"><br><sub>Windows · Devices</sub></td>
<td align="center"><img src="docs/screenshots/android/ko-dark/17-devices-remote.png" width="160"><br><sub>Android · My devices</sub></td>
<td align="center"><img src="docs/screenshots/ios/ko-13-devices-remote.png" width="160"><br><sub>iPhone · Devices</sub></td>
</tr>
</table>
<p align="center"><sub>Remote connection: each app lists a device on another network as <i>Connected · Remote</i> (recorded with a test control server).</sub></p>

## How it works

```
 Mac ──────────── Windows PC         • discovery: DNS-SD service _nearclip._tcp (Bonjour / mDNS)
  │  ╲          ╱    │               • transport: one TCP connection per pair of devices, length-prefixed frames
  │    ╲      ╱      │               • crypto: P-256 ECDH (ephemeral) + HKDF-SHA256 + AES-256-GCM
 iPhone ──── Android                  • a clip received from one peer is forwarded to the others (dedup by id)
```

* Every installation creates a **group** (random 256-bit key). Pairing hands that key to the new device over a channel
  authenticated by the QR secret or by the 6-digit numeric comparison (with a commitment, so a man in the middle
  cannot force matching numbers).
* Each connection runs an ephemeral ECDH handshake bound to the group key (forward secrecy); all clip data, member lists
  and pairing results are encrypted. The wire protocol is specified in [docs/PROTOCOL.md](docs/PROTOCOL.md) and pinned
  by [spec/test-vectors.json](spec/test-vectors.json).
* **Remote connection** ([PROTOCOL.md §10](docs/PROTOCOL.md), [tailnet/](tailnet/README.md)): each app runs a
  [tsnet](https://tailscale.com/kb/1244/tsnet) node in userspace (WireGuard and gVisor's network stack; no system VPN)
  named `nearclip-<device>-<id>`. Devices of a group find each other among the tailnet's machines by that name and
  connect through the node; the Nearclip session and its encryption run unchanged inside WireGuard. Tailscale's
  coordination server sees device names and addresses, never clips. Nearclip itself still runs no server.
* Product and UX decisions are in [docs/DESIGN.md](docs/DESIGN.md).

## Build & run

### Embedded Tailscale library (`tailnet/`, build first)

Remote connection needs a small Go library per platform, built outside Xcode, Gradle and .NET:

```sh
tailnet/build.sh all              # Go (see tailnet/go.mod), Xcode, the Android NDK and llvm-mingw — see tailnet/README.md
```

It writes `apple/NearclipKit/Binaries/NCTailnet.xcframework`, `android/app/src/main/jniLibs/*/libnctailnet.so` and
`windows/native/win-*/nctailnet.dll` (all gitignored) and refreshes the license notices
`tailnet/notices/THIRD_PARTY_NOTICES.txt`. The app builds stop with a clear message when the library is missing.

### macOS and iOS (`apple/`)

Requirements: Xcode 16 or newer (built and tested with Xcode 27 beta), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd apple
xcodegen generate                 # creates Nearclip.xcodeproj (also committed)
open Nearclip.xcodeproj           # schemes: Nearclip (macOS), NearclipiOS
scripts/build-release.sh          # universal, ad-hoc signed dist/Nearclip-macOS.zip
```

* macOS 14+. The app lives in the menu bar (and behind ⌃⌘V). On first copy macOS asks whether Nearclip may read
  the clipboard — choose **Always Allow** (System Settings › Privacy & Security › Paste from Other Apps).
* iOS 17+. To run on an iPhone, select your team in *Signing & Capabilities* of the `NearclipiOS` target.

### Android (`android/`) and Windows (`windows/`)

See [android/README.md](android/README.md) and [windows/README.md](windows/README.md).

## Tests

| Suite | Command |
|---|---|
| Swift engine (vectors + localhost pairing/sync scenarios) | `cd apple/NearclipKit && swift test` |
| Kotlin engine | `cd android && ./gradlew :core:test` |
| C# engine | `cd windows && dotnet test --project tests/Nearclip.Core.Tests/Nearclip.Core.Tests.csproj` |
| Tailnet bridge (Go, against an in-process control server) | `cd tailnet && go test ./...` |
| **Cross-implementation interop** (Swift × Kotlin × C#, 48 scenarios incl. remote and image progress) | `python3 tools/interop/run.py` |
| iOS UI flow (onboarding → pair → catch-up → send; remote; licenses) | `xcodebuild test -scheme NearclipiOS …` (see `apple/iOSUITests`) |
| macOS acceptance demo (real app + simulated peers) | `python3 apple/tools/demo.py` |
| Large-image progress in the real apps (a peer that sends slowly; screenshots) | `tools/acceptance/mac_transfer.py`, `tools/acceptance/windows_transfer.py`, `tools/acceptance/android_transfer.py`, `apple/tools/ios_transfer.py` |
| Remote connection in the real apps (throwaway Tailscale control server) | `apple/tools/remote_demo.py`, `apple/tools/ios_remote.py`, `tools/acceptance/android_remote.py`, `tools/acceptance/windows_remote.py` |
| Remote connection against the real Tailscale service (a person signs in) | `python3 tools/acceptance/real_remote.py` |

## What has been verified

* **Engines**: Swift 12 tests, Kotlin 24 tests, C# 28 tests, Go bridge tests — every value in `spec/test-vectors.json` plus
  real localhost pairing/sync scenarios and the tailnet dialing/discovery logic.
* **Interop**: `tools/interop/run.py` passes **48/48** scenarios across Swift × Kotlin × C# (QR and code pairing in every
  direction, live text in Korean + emoji, multi-chunk images, delete everywhere, catch-up after restart, removal,
  re-adding a removed device, 3-hop mesh forwarding in every permutation, **image progress** for every ordered pair
  (announced → preparing → progress → clip, an image without announcement, cancel, sender gone mid-announcement, no
  progress for catch-up), and **remote**: every ordered pair pairs on the
  LAN, comes back on new ports with remote connection on, finds the other through the tailnet and syncs both ways).
* **Large-image progress in the real apps** (a peer sending a 10.6 MB photo at 0.9 MB/s): the macOS app (isolated
  instance), the Windows 11 ARM64 VM, the Android 16 emulator and the iPhone simulator showed *Receiving an image from …*
  with *Preparing…*, then *3.1 / 10.6 MB*, *7.3 / 10.6 MB* (Windows counts like File Explorer: *3.0 / 10.1 MB*), and
  turned into *Copied from …* in place with the image on the clipboard. Clicking the computer toast mid-transfer hid it
  until the image was in. A cancelled announcement just disappeared; a sender dropping mid-transfer gave *Couldn't receive the
  image · Copy it again on …*; with auto-copy off, *Image from … · Saved to history*. On Android also in the background
  (banner, progress in the shade, *Copied from …* banner with the thumbnail), and an image shared into Nearclip was
  announced before it was read (size known 0.2 s later). **Not verified yet:** real phones and a real Windows PC.
* **Real apps, one group** (macOS app on this Mac, iPhone/iPad simulators, Android 16 emulator, Windows 11 ARM64 VM):
  a clip copied on each platform arrived on all the others —
  Mac → Windows clipboard / Android / iPhone, Windows → Mac clipboard / Android / iPhone,
  Android share → Mac / Windows clipboards / iPhone, iPhone Paste button → Mac / Windows clipboards / Android.
* Discovery over Bonjour/mDNS between Macs, Mac ↔ iOS, Mac ↔ Windows (across the Parallels network) and Android → Mac;
  code pairing with matching 6-digit codes on both screens; password-manager items are skipped (macOS concealed type,
  Android `EXTRA_IS_SENSITIVE` device test).
* **Remote connection in the real apps** against a throwaway Tailscale control server (the real tsnet, WireGuard and DERP
  code; only the coordination server is local): the macOS app, the iPhone simulator, the Android 16 emulator and the
  Windows 11 ARM64 VM each showed *On · ‹account›*, listed a peer that was not reachable over the LAN as
  *Connected · Remote* and received its clip (Windows: on the clipboard). The iPhone came back to *Remote* after 14 s in
  the background.
* **Against the real Tailscale service** (login.tailscale.com, a real account; `tools/acceptance/real_remote.py`): the
  macOS app and the Android app (emulator) signed in and showed *On · ‹account›* with their tailnet addresses. After
  the LAN path was taken away, each listed the other as *Connected · Remote*, a clip went Mac → Android and
  Android → Mac (onto the Mac clipboard), and both nodes reported a direct WireGuard path. *Sign out of Tailscale* in
  each app took the node offline with its key expired.
  **Not verified yet:** two different real networks (both nodes were behind the same router, so NAT traversal across
  the internet and the DERP fallback were not exercised), iPhone and Windows against the real service, phones on
  mobile data, and battery use.
* UI: light/dark × English/Korean screenshots of every main screen in [docs/screenshots](docs/screenshots).

## Downloads

`dist/` (built locally, not committed): `Nearclip-macOS.zip` (universal, ad-hoc signed), `Nearclip-Windows-arm64.zip` /
`Nearclip-Windows-x64.zip` (self-contained; unzip and run `Nearclip\Nearclip.exe`), `Nearclip-Android.apk` (release build
signed with a local debug key). iOS: build and run from Xcode with your own team. The embedded Tailscale node adds
about 20 MB per platform.


## Limitations

* Without Remote connection, devices must be on the **same local network**; guest or corporate Wi-Fi that blocks
  device-to-device traffic or mDNS needs *Connect by address*. Remote connection needs a (free) Tailscale account
  signed in on each device. When no direct path can be made, traffic goes through Tailscale's DERP relays — still
  end-to-end encrypted, but slower. Tailnets with custom access rules must allow TCP 45821 between your devices, and
  tailnets with device approval need each Nearclip device approved in the admin console.
* iOS only syncs while Nearclip is open (iOS does not allow background clipboard access); it catches up instantly when
  opened and can copy the newest clip automatically. The same goes for remote connection: the iPhone's node runs while
  the app is open.
* Signing out of Tailscale in Nearclip works like Tailscale's own apps: the device's key expires and it stays in the
  Tailscale admin console (as expired) until you remove it there.
* Android 10+ only lets the foreground app read the clipboard: sending uses the app, the Quick Settings tile, the
  notification action, the share sheet or the text-selection menu by default. Settings › *Bring copies into Nearclip
  instantly* optionally captures text and links in the background with Shizuku. The setup sheet guides installation,
  starting Shizuku and allowing Nearclip; nothing is enabled until you choose it. Restart Shizuku after reboot
  (non-root devices). Android 12+ may show a Shell clipboard-access notice per copy. Sensitive-marked items are
  skipped; images still use the existing send actions. Receiving works in the background.
* Removing a device is cooperative; for a full key rotation, leave and pair the remaining devices again.
* Builds are not code-signed for public distribution yet: macOS Gatekeeper and Windows SmartScreen will warn on
  downloaded copies, and the Windows build is a self-contained folder (no installer/MSIX yet). On first launch Windows
  asks for firewall access — Nearclip shows the firewall status and an *Allow…* button in onboarding and Settings.

## Third-party software

Remote connection embeds open-source software: Tailscale (BSD-3-Clause), wireguard-go (MIT), gVisor (Apache-2.0), the
Go standard library (BSD-3-Clause) and other Go modules. Their license texts are in
[tailnet/notices/THIRD_PARTY_NOTICES.txt](tailnet/notices/THIRD_PARTY_NOTICES.txt) and in each app under About ›
Open-source licenses.

Optional Android instant capture uses Shizuku API (MIT) and Android Hidden API Bypass (Apache-2.0). Their license
texts are available in the Android app under Settings › Open-source licenses.

## License

MIT © 2026 ivLis Studio

