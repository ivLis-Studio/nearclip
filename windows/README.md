# Nearclip for Windows

Native Windows app (WinUI 3 / Windows App SDK, C#), the shared C# protocol engine, its tests and the interop CLI.
Nearclip keeps the clipboard of your own devices in sync over the local network and, with Remote connection on, across
networks through an embedded Tailscale node: no Nearclip server, no Nearclip account (see ../docs/PROTOCOL.md and
../docs/DESIGN.md).

```
windows/
  Nearclip.slnx                     solution (the app builds only for the ARM64 / x64 solution platforms)
  Directory.Build.props, global.json, NuGet.Config
  src/Nearclip.Core/                net10.0, no Windows APIs: crypto, framing, sessions, sync engine, store, pairing URI
  src/Nearclip.Cli/                 net10.0 console peer for tools/interop (PROTOCOL.md §9)
  src/Nearclip.App/                 WinUI 3 app (net10.0-windows10.0.22621.0, unpackaged, self-contained, x64 + ARM64)
  tests/Nearclip.Core.Tests/        xUnit v3: every spec/test-vectors.json value + real loopback scenarios
  native/win-{x64,arm64}/           nctailnet.dll, the embedded Tailscale node (tailnet/build.sh windows; gitignored)
  scripts/vm/                       UI helpers used for screenshots in the Parallels test VM
  NOTES.md                          worklog: decisions, VM workflow, verification history
```

## Build and test on macOS (or Linux / Windows)

Requires the .NET 10 SDK.

```sh
cd windows
dotnet test --project tests/Nearclip.Core.Tests/Nearclip.Core.Tests.csproj   # 28 tests
dotnet build Nearclip.slnx                                                   # Core + CLI + tests (the app is skipped for Any CPU)
dotnet build src/Nearclip.Cli/Nearclip.Cli.csproj -c Release
```

### Interop CLI

```sh
windows/src/Nearclip.Cli/bin/Release/net10.0/Nearclip.Cli --state /tmp/nc-a --name "MacBook (C#)" [--port 45950]
```

The apphost runs directly (no `dotnet run`); `dotnet windows/src/Nearclip.Cli/bin/Release/net10.0/Nearclip.Cli.dll …` works too.
It speaks PROTOCOL.md §9 exactly: one JSON event per line on stdout, one JSON command per line on stdin, log on
stderr; `--port 0` picks a free port; it never touches a clipboard and does no DNS-SD. `tools/interop/run.py` finds
this path automatically:

```sh
python3 tools/interop/run.py                     # swift, kotlin and dotnet if built
python3 tools/interop/run.py --only swift,dotnet
```

## Build, run and publish the app (Windows 10 1809+ / Windows 11)

Only the .NET 10 SDK is required — the XAML compiler and the Windows SDK projections come from NuGet
(Microsoft.WindowsAppSDK 2.5.1, Microsoft.Windows.SDK.BuildTools). No Visual Studio workload is needed.
The app also needs `native\win-x64\nctailnet.dll` and `native\win-arm64\nctailnet.dll` (remote connection), built on a Mac
with `tailnet/build.sh windows` (Go + llvm-mingw). The build copies the one for its RID next to Nearclip.exe together
with `tailnet/notices/THIRD_PARTY_NOTICES.txt` (Settings › About › View license texts), and stops with a message when the
DLL is missing.

```powershell
cd windows
dotnet build Nearclip.slnx -c Release -p:Platform=ARM64          # everything, ARM64
dotnet build src\Nearclip.App\Nearclip.App.csproj -c Debug -p:Platform=x64
src\Nearclip.App\bin\x64\Debug\net10.0-windows10.0.22621.0\win-x64\Nearclip.exe

dotnet publish src\Nearclip.App\Nearclip.App.csproj -c Release -p:Platform=x64   -o artifacts\app\win-x64
dotnet publish src\Nearclip.App\Nearclip.App.csproj -c Release -p:Platform=ARM64 -o artifacts\app\win-arm64
```

The output folder is self-contained (the .NET runtime and Windows App SDK are inside it), so it can be zipped and run
on a clean PC (about 250–270 MB, 535 files). The executable is `Nearclip.exe`. Nearclip runs once per user and data
directory, from whatever folder: a second launch sends its command line to the running instance (named mutex +
WM_COPYDATA to its hidden window) and exits.

| Argument | Effect |
|---|---|
| `nearclip://pair?…` | pair with the device that showed this QR link (also registered as the `nearclip:` URL handler) |
| `--background` | start in the notification area only (used by "Open at login") |
| `--show <surface>` | open a surface: `flyout`, `shortcut`, `add`, `add:address`, `settings` or `settings:<general, devices, privacy, history, about>`, `onboarding:<0, 1, 2>`, and the screenshot previews `toast` and `prompt:<name>` |
| `--theme <light, dark, system>`, `--lang <en-US, ko-KR, system>` | theme now; language at the next start (`--lang` is applied at startup) |
| `--login <on, off>` | turn Open at login on or off (the Run key; the startup task in the Microsoft Store edition) |
| `--quit` | quit the running instance (sends `bye` and withdraws the DNS-SD advertisement) |

Environment: `NEARCLIP_DATA` (data directory, default `%LOCALAPPDATA%\Nearclip`), `NEARCLIP_PORT` (default 45821, any free port
if taken), `NEARCLIP_TAILNET_CONTROL` (a test Tailscale control server; Debug builds also read
`%LOCALAPPDATA%\Nearclip\tailnet-control.txt`), `NEARCLIP_TAILNET_LOG` (the node's log file). Data: `settings.json`,
`state\` (identity, group, members, history, blobs, tombstones; the group key is encrypted with DPAPI for the current
user), `tailnet\` (the embedded node's keys and state), `logs\nearclip.log`.

**Windows Firewall.** The first time Nearclip listens, Windows asks whether to allow it. If that prompt is dismissed,
Windows adds block rules and other devices cannot connect to this PC (this PC can still connect out). Onboarding,
Settings › Devices and Add device show the state ("Blocked") and offer **Allow…**, which asks for elevation and
replaces the rules with one inbound allow rule for Nearclip.exe. On a network marked Public (common in VMs), the
allow rule must cover the Public profile; the app's rule covers all profiles.
Remote connection only connects out, so it works without the rule; when a direct path is blocked, Tailscale relays
the traffic instead.

### Microsoft Store edition (MSIX)

The Store edition is the same app packed as MSIX: identity `ivLis-STUDIO.Nearclip` (Store ID 9PNQ3Z9S83QS, package family
`ivLis-STUDIO.Nearclip_hxw094hmzvn72`), manifest `packaging\Package.appxmanifest`, logos `packaging\Images` (made by
`design/make-icons.mjs`). On Windows:

```powershell
cd windows
scripts\package-msix.ps1 -Version 1.0.0                    # artifacts\store\Nearclip-1.0.0.msixbundle (+ one .msix per arch)
scripts\package-msix.ps1 -Version 1.0.0 -TestCertificate   # ...plus test-signed copies and a .cer to sideload on a test PC
```

Upload the unsigned bundle to Partner Center (the Store signs it); bump `Version` in the manifest first for every update.
At run time `Platform\PackageInfo.cs` tells the editions apart by package identity. The packaged app:

* opens at login through the `NearclipStartup` startup task, off until the user turns it on (Windows may also let the
  user turn it off in Settings › Apps › Startup); the GitHub build keeps using the Run key and turns it on at first start;
* gets `nearclip:` links through the manifest's protocol declaration instead of a registry handler;
* adds its inbound firewall rules on install (TCP and UDP, all profiles), so the first-run firewall prompt does not appear;
* keeps its data in the same `%LOCALAPPDATA%\Nearclip` as the GitHub build, so switching editions keeps the pairing.

The listing (copy, screenshots, art and trailers) is built from `docs/store/microsoft-listing.json` and `promo/store.sh`:
export the listing CSV in Partner Center, run `python3 docs/store/build-listing-csv.py EXPORT.csv`, then use Import listings ›
Upload folder with `promo/out/store/import/nearclip-listing`.

## Architecture

```
            ┌──────────────── Nearclip.App (UI thread) ─────────────────┐
 tray / hotkey / clipboard ──► AppModel (port of apple/Shared/AppModel.swift) ──► views
 (message-only window)           │  ▲ NodeEvent (marshalled to the UI thread)
                                 ▼  │
            ┌──────────── Nearclip.Core.NearclipNode (one serial queue) ───────────┐
            │ store (JSON + blobs) · dialer/back-off · inventory/want · forwarding │
            │ PeerSession × n: framing, handshakes, AES-GCM, chunks, ping/pong      │
            └──────────── IDiscovery (DnsSdDiscovery) · ISecretStore (DPAPI) ──────┘
```

* **Core** mirrors the Swift reference engine (`apple/NearclipKit/Sources/NearclipKit/{Session,Node}.swift`): all state is
  owned by one serial queue; socket reads/writes run on tasks and post back. Crypto uses .NET primitives only
  (ECDiffieHellman P-256 raw agreement, HKDF, AesGcm, HMACSHA256, SHA256).
* **Clipboard** (`Platform/ClipboardService.cs`): AddClipboardFormatListener on a message-only window. Reads text and images
  (PNG, else DIB → PNG; JPEG at quality 0.9 when the PNG would exceed 32 MiB). Writes incoming clips with a private
  `Nearclip.ClipId` format so they are not sent back out. Never records items carrying
  `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory=0`, `CanUploadToCloudClipboard=0` or
  "Clipboard Viewer Ignore", nor copies from ignored apps (matched by the clipboard owner's executable; defaults:
  1Password, Bitwarden, KeePassXC, KeePass).
* **Discovery** (`Platform/DnsSdDiscovery.cs`): advertises with DnsServiceRegister (mDNS) and browses with the Windows
  DNS-SD association-endpoint watcher; both work unpackaged. TXT updates are serialized (one register/deregister in
  flight).
* **Tray** (Shell_NotifyIcon, light/dark glyph, pulse on send/receive, dimmed while paused), **flyout** (360 × 520 Mica,
  anchored above the tray, closes on deactivation), **hotkey** (RegisterHotKey, Win+Alt+V by default),
  **toast** (borderless always-on-top Mica window, 2.5 s, hover keeps it, click opens history),
  **Settings** (NavigationView + Windows 11 settings cards), **Add device** (QR with the app glyph and countdown,
  Nearby list, connect by address, paste a link, numeric-comparison dialogs for both roles), **Onboarding**
  (welcome, quick setup: firewall, shortcut, open at login; add devices), **open at login** (HKCU Run).
* **Localization**: `Strings/en-US` and `Strings/ko-KR` `Resources.resw` (Korean wording from apple/tools/ko.json). Korean
  text uses keep-all line breaking (word joiners between Hangul characters), like the Apple apps.
* **Theming**: light, dark and high contrast follow the Windows setting or the app's own choice. Brushes in code come
  from keyed ThemeResource styles (`Controls/Themed.cs`), never from `Application.Current.Resources` directly.

## Testing in a VM (how the screenshots were made)

The app was built and run in a Parallels "Windows 11" ARM64 guest with only the .NET SDK installed; the steps, the
`prlctl` commands and the keyboard-injection approach (`prlctl send-key-event --json`) are in NOTES.md.
Screenshots of every surface in English/Korean × light/dark are in ../docs/screenshots/windows/.

## Known limitations

* The app itself builds and runs only on Windows; the Mac builds and tests Core, CLI and tests.
* "Paste after choosing" (sending Ctrl+V to the previous app) is off by default and is not covered by the VM tests.
* Ignoring apps matches the executable name of the clipboard owner; apps that copy through a helper process are not
  matched. Password managers that set the exclusion formats are always skipped.
* Pairing screens were exercised in an ARM64 VM at 200 % scale; x64 was build-verified (not run).
* Remote connection was verified in the ARM64 VM against a throwaway control server (Devices showed the Mac as
  *Connected · Remote*, its clip reached the clipboard). Against the real Tailscale service and on x64 it is untested.
* The unpackaged app has no MSIX/Store identity: no Start-menu tile is created by the build; use the published folder
  (or the Store edition above). The Store package was sideload-tested on ARM64 only; the x64 package is build-verified.
