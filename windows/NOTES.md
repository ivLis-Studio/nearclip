# Nearclip for Windows — worklog

Running notes (decisions, commands, status) so work can resume after a context reset.

## Layout

- `src/Nearclip.Core` (net10.0, no Windows APIs): crypto, framing, sessions, sync engine, store, pairing URI.
  Engine design mirrors the Swift reference (`apple/NearclipKit/Sources/NearclipKit/{Session,Node}.swift`):
  one serial queue (`SerialQueue`) owns all state; socket reads/writes run on tasks and post back.
- `src/Nearclip.Cli` — PROTOCOL §9 peer. `tests/Nearclip.Core.Tests` — xUnit v3 (MTP runner, see global.json).
- `src/Nearclip.App` — WinUI 3 app (built in the Parallels guest only).

## Commands (Mac)

- Tests: `cd windows && dotnet test --project tests/Nearclip.Core.Tests/Nearclip.Core.Tests.csproj`
- CLI: `dotnet build src/Nearclip.Cli/Nearclip.Cli.csproj -c Release` → `src/Nearclip.Cli/bin/Release/net10.0/Nearclip.Cli`
- Interop: `python3 tools/interop/run.py --only swift,dotnet`

## Status log

- 2026-10-24: Core + CLI + tests written. 24/24 tests pass on macOS (all vectors + 12 loopback scenarios).
  Interop runner swift×dotnet: 9/9 PASS (pair-qr+sync and pair-code both directions, mesh swift→dotnet→swift).
  Kotlin CLI not built yet by the Android worker.

## Decisions / interpretations

- Dialing: all endpoints of a peer are raced in parallel (first TCP connect wins), instead of one endpoint per attempt.
- Redial back-off starts at 20 s (spec: "every 20 s"), doubles to 5 min; first attempt immediately at start/resume.
- Same-client duplicate sessions (tie in §4.4): keep the existing one (same as Swift); duplicate dials to an
  address that already has a live client session are skipped so ties don't arise from this side.
- QR join closed by the inviter right after the hello exchange is reported as `no_ticket` (the inviter silently
  closes on a wrong/used ticket per §5.1, so the joiner can't otherwise tell).
- Sessions of an old group are marked detached on leave/join so a late `bye removed` can't make the device leave twice.
- "Sync images" off: local images are not sent; incoming image clips are skipped (not stored) and not re-requested
  during this run.
- Pause = offline (like Swift): listener + DNS-SD stopped, sessions closed with `bye shutdown`. The app does not
  record clipboard changes while paused.

## WinUI app (src/Nearclip.App) — status 2026-10-24

Builds in the guest with only the .NET 10 SDK (no Visual Studio / Windows SDK install needed): Windows App SDK 2.5.1
NuGet + Microsoft.Windows.SDK.BuildTools. Unpackaged, self-contained, AssemblyName `Nearclip` (exe = Nearclip.exe).
Nearclip.slnx includes the app only for the ARM64/x64 solution platforms (Any CPU on macOS skips it).

### VM workflow (Parallels "Windows 11", ARM64, Korean, dark, user p5e1\namjunseo, IP 10.211.55.6, network Public)

- Guest .NET SDK: C:\dev\dotnet (dotnet-install.ps1, 10.0.402 arm64). Source copy: C:\dev\nearclip\windows.
- Transfer: Mac `python3 -m http.server 8765 --bind 10.211.55.2` in /tmp/nearclip-xfer; zip windows/ + spec/test-vectors.json
  there; guest Invoke-WebRequest + Expand-Archive + robocopy /MIR /XD bin obj.
- Build: `dotnet build src\Nearclip.App\Nearclip.App.csproj -c Debug -r win-arm64 -p:Platform=ARM64` (quit the app first:
  `Nearclip.exe --quit`).
- Guest commands: `prlctl exec 'Windows 11' --current-user powershell -EncodedCommand …` (GUI session); without
  --current-user = SYSTEM (firewall rules).
- Input: SendInput/mouse_event from prlctl exec do NOT reach the desktop. Real keyboard input works with
  `echo '[{"key":115,"event":"press"},…]' | prlctl send-key-event 'Windows 11' --json` (X11-style key codes: Enter 36,
  Esc 9, Tab 23, Win 115, Alt 64, Ctrl 37, V 55, arrows 98/104, Delete 107, digits 10–19, period 60). No mouse.
- App dev hooks (second launch forwards args): `--show flyout|shortcut|add|add:address|settings[:page]|onboarding:N|toast|prompt:Name`,
  `--theme light|dark|system`, `--lang en-US|ko-KR|system` (startup only), `--quit`, `nearclip://pair?…`.
- Screenshots: `prlctl capture 'Windows 11' --file x.png` (2050×1222, 200 %), crop with sips; window rects from
  scripts/vm/ui.ps1 -List (running ui.ps1 steals focus: the flyout closes on deactivation, so capture it first).
- Firewall: first launch prompt dismissed → Windows adds Block rules. Test VM fix (as SYSTEM): delete rules for the exe
  + `netsh advfirewall firewall add rule name="Nearclip (dev build)" dir=in action=allow program=<exe> profile=any protocol=tcp`.
  The app shows Blocked + "Allow…" (elevated netsh) in onboarding/Settings/Add device.
- Tray icon promoted for screenshots: HKCU\Control Panel\NotifyIconSettings\<id>\IsPromoted=1.

### Verified live in the guest (2026-10-24)

- DNS-SD both ways across the Parallels shared network: guest Nearby lists the Mac demo app; Mac `dns-sd -B` sees P5E1.
- QR link pairing with the Swift CLI on the Mac (nearclip:// link → joiner dialogs → paired/peer_up on Swift).
- Mac→Windows text (Get-Clipboard exact, toast), Mac→Windows 1.69 MB PNG (byte-exact sha256 on the guest clipboard),
  Windows→Mac text (Set-Clipboard → Swift clip live) and bitmap (1.23 MB PNG).
- Code pairing: guest as joiner (address 10.211.55.2:45961, SAS shown on both sides, Swift accept) and as inviter
  (Swift pair_code → PairPromptWindow, accept). 3-member mesh with forwarding; catch-up after app restart (live:false,
  clipboard untouched); delete everywhere (Ctrl+Delete) → both Swift peers `deleted`; pin (Ctrl+P), search, ↑↓ Enter.
- Win+Alt+V via real key events opens the centered flyout.

### Fixed during VM testing

- DNS-SD: TXT update before the first registration completed orphaned it (9701) → "P5E1 (1)". Now a serialized state
  machine (one register/deregister in flight), Dispose waits for the deregistration at quit.
- Korean line breaking: Loc.S applies keep-all (U+2060 between Hangul word characters); Loc.Raw for Win32 menu/tooltips.
- Firewall card texts per state; Add-device firewall link wraps; headers aligned; port box wider; Enter submits.
- Pair prompt window: Add gets keyboard focus on activation (was Decline), Esc declines.
- Received images without w/h: size read from the PNG/JPEG header.
- Light theme (lead review): brushes read in code from Application.Current.Resources resolved against the *system*
  theme (dark guest) → washed-out captions/link paths/tiles in light mode. All code-built elements now use keyed
  ThemeResource styles from App.xaml (Controls/Themed.cs); no brush lookups in code remain. Toast/prompt backdrops
  are recreated on theme change.
- A pair_failed arriving after the user cancelled no longer resurfaces as a stale "Couldn't connect"; finished join
  results are dismissed when Add device closes.

### Core change (lead, PROTOCOL §4.3 re-add)

- SessionEstablished no longer answers a tombstoned peer with `bye removed`; welcome is always sent and the removal
  check runs only after merging the peer's welcome (SessionWelcome), like Swift/Kotlin. New loopback test
  ReAddedDevice_IsNotRemovedAgain_ByMemberThatMissedTheReAdd (fails with the old check, passes now). 26/26 on macOS.
- Interop (Swift + Kotlin + C# CLIs, 2026-10-24 05:38): `python3 tools/interop/run.py` → 30/30 PASS incl. 6 re-add permutations.

### Real macOS app ↔ Windows app (2026-10-24, demo instance on port 45900)

- Code pairing guest→Mac app by address 10.211.55.2:45900; same code (083 524) on both; accepted in the Mac app's
  prompt (Computer Use click on 추가); Windows showed "You're connected".
- Mac app pasteboard (demo pasteboard studio.ivlis.nearclip.demo-pasteboard) text → guest Get-Clipboard exact + toast;
  guest Set-Clipboard → Mac app pasteboard exact + its history ("P5E1 · 방금"); 1.69 MB PNG Mac app → guest clipboard
  byte-identical (sha256 aad0354d…e423).

### Gotchas

- Long -EncodedCommand payloads (~>4–5 kB) make `prlctl exec` hang on the host; ship scripts via the HTTP server and start
  long jobs with Win32_Process.Create (processes started from prlctl exec are killed when the client exits).
- Running the test project in the guest triggers a Windows Firewall prompt for Nearclip.Core.Tests.exe (loopback
  listeners); dismissing it adds block rules (removed again; loopback tests pass regardless).
- The guest shows the "Windows 정품 인증" (activate Windows) watermark in the bottom-right corner after a while; some
  late screenshots (flyout paused / published build) have it over the flyout footer. VM licensing, not the app.

### Single instance (changed 2026-10-24 06:15)

- The Windows App SDK AppInstance key of an unpackaged app turned out to be scoped to the exe path: the published
  build and the Debug build ran side by side on the same data directory (second one fell back to a random port and
  its hotkey was taken). Replaced by a named mutex `Local\Nearclip.<user>.<hash(data dir)>` + WM_COPYDATA to the primary's
  hidden window (class NearclipMessageWindow, title = instance key). Verified: published exe launched while the Debug
  build runs → forwarded (Add device opened in the running instance, one process); `--quit` + immediate
  `--relaunch --show settings:devices` → new instance takes over 0.2 s after the old one exits.

### Release builds / publish in the guest (2026-10-24 06:16, from the final source)

- `dotnet build Nearclip.slnx -c Release -p:Platform=ARM64` → Core, Cli, Tests, App: 0 warnings, 0 errors.
- `dotnet build src\Nearclip.App\Nearclip.App.csproj -c Release -p:Platform=x64` → 0/0 (x64 compile verified, not run).
- `dotnet publish … -p:Platform=ARM64|x64 -o C:\dev\nearclip-publish\<rid>` → win-arm64 531 files / 246.4 MB,
  win-x64 535 files / 231.1 MB, Nearclip.exe present. The published ARM64 build ran in the guest (flyout, tray).
- Guest `dotnet test` (ARM64 Windows): 26/26.

### Tray (real keyboard input)

- Win+B focuses the notification area; Shift+F10 on the Nearclip icon opens the native menu (status line, Open,
  Add device…, Pause syncing, Settings…, Quit). Pause from the menu → icon dimmed, flyout InfoBar "Syncing paused"
  with Resume, menu item checked; resume → peers reconnect. Screenshots ko-dark-tray-menu*.png, ko-dark-flyout-paused.png.

## Remote connection (2026-10-24)

- Core: Tailnet.cs (P/Invoke to nctailnet.dll; NEARCLIP_TAILNET_LIB for the macOS test CLI), Dialer.RaceAsync (LAN
  first, tailnet +400 ms, through the bridge proxy or directly when the OS has a tailnet address). Tests 28/28.
- App: AppModel remote members, Settings › General remote card (status + sign in / try again / sign out), route text
  on device rows, suggestion link, About license rows + "View license texts" (THIRD_PARTY_NOTICES.txt next to the exe).
  NetworkChange (debounced) tells the node and redials. Debug-only hook `%LOCALAPPDATA%\Nearclip\tailnet-control.txt`.
- Verified in the guest with tools/acceptance/windows_remote.py (throwaway control server at 10.211.55.2): Settings
  "켜짐 · …", Devices "MacBook Pro · 연결됨 · 원격", `Get-Clipboard` = the peer's clip.
- Release (13:15, from this source): Debug ARM64 0 warnings / 0 errors; publish win-arm64 533 files, win-x64 537 files,
  each with nctailnet.dll and THIRD_PARTY_NOTICES.txt. The zips put everything under `Nearclip/`; .NET Framework's
  ZipFile writes backslash separators, so dist/ gets copies with `/` (rewritten on the Mac, CRCs checked).
- The published exe is a new path, so its first start shows the Windows Defender Firewall prompt (left unanswered in
  the test VM). About › "View license texts" checked with UI Automation: Notepad opened THIRD_PARTY_NOTICES.txt.

## Large-image progress (2026-10-24, PROTOCOL §6.6)

- Core: `incoming` messages, `NodeEvent.TransferChanged` (preparing / receiving / failed), transfers per session set,
  `AnnounceImage` / `CancelImage`, `SendImage(…, id)`; CLI `transfer` / `announced` events, `announce_image` /
  `cancel_image`. Tests 28/28.
- App: ClipboardService announces an image before encoding it; a generation counter drops an encode that a newer copy
  replaced (and cancels its announcement). AppModel shows a transfer still running after 0.3 s. ToastWindow: device
  glyph, "…에서 이미지 받는 중…", ProgressBar with "3.1 / 10.6 MB" (indeterminate with "준비 중…" first) and a thumbnail
  slot; stays up while it runs and turns into "…에서 복사됨" in place ("…에서 받은 이미지 · 기록에 저장됨" with
  auto-copy off); failures get a caution circle and "이미지를 받지 못했습니다 · …에서 다시 복사해 보세요." Clicking it
  during a transfer opens the history and keeps the progress away until the image is in. Sizes in the units of the
  history list and File Explorer (1 MB = 1024 KB), so the toast and the flyout agree.
- Verified in the guest with `tools/acceptance/windows_transfer.py` (Swift peer "Galaxy S25" at `--pace 900000`):
  "준비 중…", cancel → toast gone without a message, 3.0 → 7.0 / 10.1 MB (same size as the flyout row), "Galaxy S25에서
  복사됨" with the thumbnail and a 3200×3200 image on the guest clipboard after 14.4 s, peer killed mid-transfer →
  warning, auto-copy off → "기록에 저장됨". A real click (SendInput) on the toast mid-transfer opened the flyout and the
  toast stayed away until "Galaxy S25에서 복사됨".
- Release (17:20, from this source): Debug ARM64 0 warnings / 0 errors; publish win-arm64 533 files, win-x64 537 files;
  dist zips rewritten with `/` separators (earlier zips in ~/.Trash/nearclip-windows-zips-*).

## x64 build with remote connection on, under emulation (found in the final test, 2026-10-24)

- Symptom (Windows 11 ARM64 VM, x64 build emulated): with remote connection on, Nearclip.exe logged "starting" and
  within 3 s was left with one thread that `Stop-Process -Force` could not end; its main thread was gone, so the
  single-instance mutex was abandoned and the next launch became a second primary (one on 45821, one on a fallback
  port, same state directory). No .NET or WER crash record. Remote connection off: the x64 build ran normally.
- Cause: Go's asynchronous preemption in nctailnet.dll (it suspends threads and rewrites their context) kills an x64
  process emulated on ARM64. The x64 CLI with `--tailnet` behaved the same; with `GODEBUG=asyncpreemptoff=1` both
  ran. Fix: TailnetBridge sets that GODEBUG before the DLL loads, only for an x64 process on an ARM64 machine
  (IsWow64Process2); the arm64 build and real x64 PCs are unchanged. Not verified on a real x64 PC.
- Also found: the CLI had no application manifest, so GetVersionEx reported Windows 8 and the embedded node panicked
  ("incoherent Windows version -- missing/outdated manifest?", tailscale.com/net/tshttpproxy via wingoes) on the
  arm64 CLI with `--tailnet`. The app always had the manifest. Nearclip.Cli now has one (supportedOS Windows 10).
- After the fix, in the VM: x64 build with remote on keeps running (51 threads, advertises on 45821, node state
  written); published arm64 and x64 builds pair through a nearclip:// link and sync text both ways through the
  Windows clipboard; x64 and arm64 CLIs with `--tailnet` reach needsLogin without errors and exit cleanly. The stuck
  processes from before the fix only went away with a VM restart.
