# Nearclip — Product & UI/UX Design

Nearclip is a universal clipboard for a person's own devices on the **same local network**.
Copy on one device, paste on any other. No server, no account, end-to-end encrypted.
Wire protocol: [PROTOCOL.md](PROTOCOL.md).

## 1. Principles

1. **Invisible when it works.** On computers, copying is enough — the clip is already on the other
   devices. Phones need one tap at most (OS rules forbid background clipboard reads there).
2. **Honest status.** The user can always see whether sync is on and which devices are reachable
   right now ("Connected" vs "Last seen 3 min ago").
3. **Native everywhere.** macOS = menu bar app + floating panel; Windows = tray app + Windows 11
   flyout; Android = Material 3 (Material You); iOS = SwiftUI following the HIG. Use the platform's
   own controls, fonts, icons (SF Symbols / Segoe Fluent Icons / Material Symbols), sheets and dialogs.
4. **Private by default.** LAN only, encrypted, password-manager items are never synced, deleting a
   clip deletes it on every device.
5. **Calm visuals.** Flat surfaces, system materials (Liquid Glass / vibrancy on Apple, Mica on
   Windows, tonal surfaces on Android). No heavy gradients, no confetti. Motion 150–250 ms,
   ease-out, disabled under Reduce Motion.

## 2. Brand

| Token | Value |
|---|---|
| Name | **Nearclip** |
| Tagline | EN "Copy here. Paste there." · KO "여기서 복사하고, 저기서 붙여넣기." |
| Accent (light) | `#4C5BF5` (Iris) |
| Accent (dark) | `#8B96FF` |
| Online / success | `#2FBF71` |
| Warning | `#F5A524` |
| Destructive | platform red |
| App icon | `design/` (glyph, iOS full-bleed, macOS plate, Android adaptive layers, Windows/ICO) |
| Fonts | system only (SF Pro, Segoe UI Variable, Roboto/Google Sans) with system CJK fallback |

On Android, use Material You dynamic color when available (Android 12+) and the Iris scheme otherwise.
Every platform supports light and dark mode.

Languages: **English and Korean** at launch; every user-facing string lives in the platform's
resource system (String Catalog, `strings.xml`, `.resw`). Device-platform words stay native
("Mac", "Windows PC", "Android", "iPhone").

## 3. Vocabulary (use exactly these terms)

| Concept | English | 한국어 |
|---|---|---|
| The set of paired devices | My devices | 내 기기 |
| Pair a device | Add device | 기기 추가 |
| Unpaired devices on the network | Nearby | 주변 기기 |
| Clipboard history | History | 기록 |
| Pinned clips | Pinned | 고정됨 |
| Device reachable | Connected | 연결됨 |
| Device not reachable | Last seen 5 min ago / Not nearby | 5분 전 연결됨 / 주변에 없음 |
| Global pause | Pause syncing / Syncing paused | 동기화 일시정지 / 동기화 일시정지됨 |
| Receive feedback | Copied from iPhone | iPhone에서 복사됨 |
| Send feedback | Sent to 3 devices | 기기 3대로 보냄 |
| Pairing number | Pairing code | 연결 코드 |

## 4. Shared flows

### 4.1 Onboarding (first launch, max 3 steps, skippable after step 1)

1. **Welcome** — app icon, "Copy here. Paste there.", one sentence: "Nearclip keeps the clipboard of
   your devices in sync over your Wi-Fi. Nothing leaves your network." Primary button **Get started**.
2. **Permissions** (only what the platform needs, each with a one-line reason and a live status
   check-mark):
   * macOS: clipboard access → explain the macOS prompt and that "Always Allow" is needed for
     automatic sync (System Settings › Privacy & Security › Paste from Other Apps); local network.
   * Windows: "Allow Nearclip on private networks" when the firewall asks; nothing else.
   * Android: notifications (for the background connection), optional "Don't optimize battery".
   * iOS: local network ("Find devices on your network"); tip about Settings › Nearclip ›
     Paste from Other Apps › Allow for automatic sending.
3. **Add your devices** — the Add-device UI (4.2) embedded, plus **Done / Skip for now**.

### 4.2 Add device (pairing)

* **Computers** open a dialog/window with two columns:
  * Left: **QR code** (≈ 240 pt, Iris modules on white, rounded quiet zone, app glyph in the center)
    — "Scan with your phone's camera or the Nearclip app." Below: expires-in countdown that refreshes
    the code automatically, and the address line ("192.168.0.12 · port 45821") in secondary text.
  * Right: **Nearby** list (devices on the LAN that are not mine) with platform glyph, name and a
    **Pair** button; empty state "Open Nearclip on your other computer — it will appear here."
    Footer link "Connect by address…" (host:port field).
* **Phones** show a sheet with three entries: **Scan QR code** (primary, camera), **Show my QR code**,
  **Nearby** list. Phones also accept the `nearclip://pair?…` link opened by the system camera.
* **Code confirmation** (numeric comparison) — both sides show the same 6-digit code in large
  monospaced digits, grouped "123 456":
  * Inviter: title "Add ‘Pixel 9’?", body "Make sure ‘Pixel 9’ shows this code.", buttons
    **Decline** / **Add** (default). Appears as a modal dialog (computers: a small always-on-top
    window if the app is in the background; phones: a notification that opens the dialog).
  * Joiner: "Confirm on ‘MacBook Pro’", the code, progress indicator, **Cancel**.
* **Success**: check-mark animation, "‘Pixel 9’ is now one of your devices.", list updates live.
* Errors are human: "That code expired. Show a new one on ‘MacBook Pro’." / "‘MacBook Pro’ declined."
  / "Couldn't reach ‘MacBook Pro’. Make sure both devices are on the same Wi-Fi."

### 4.3 Live sync

* Computer copies → clip is sent silently (the menu-bar/tray icon does a brief 300 ms "send" pulse).
* Computer receives → system clipboard updated, small non-activating toast near the menu bar / tray:
  device glyph, "Copied from iPhone", one-line preview or thumbnail; 2.5 s; hover keeps it;
  click opens the history. Setting to turn the toast off.
* Android receives (connected) → clipboard updated in the background (Android ≥ 13 shows its own
  confirmation; the app adds nothing outside the app). In the app: snackbar.
* iOS receives (app open) → clipboard updated, in-app banner "Copied from MacBook Pro".
* Phones send:
  * Android: auto-send when the app opens and the clipboard changed (setting), **Send clipboard**
    FAB, Quick Settings tile, action button on the persistent notification, share sheet target,
    text-selection menu entry "Send to my devices".
  * iOS: when the app opens and the clipboard changed: auto-send if "Paste from Other Apps" is
    allowed, otherwise a prominent card with the system **Paste** button ("Send what you copied").
* Never sync: password-manager items (concealed/transient/sensitive markers), clips larger than the
  limits (show "Too large to sync" in history), anything while **Syncing paused**.
* Loop safety: a clip written by Nearclip is never sent back out as a new clip.

### 4.4 History (main surface on every platform)

* Newest first, grouped **Today / Yesterday / weekday / date**. Pinned clips in their own section at
  the top (or via the Pinned filter on small surfaces).
* Row: leading = content glyph or image thumbnail (rounded 6–8 pt); title = first 2 lines of text
  (links: domain in bold + path; color codes like `#4C5BF5`: swatch); caption = source device glyph +
  name · relative time; trailing = pin indicator. Clips from this device say "This Mac" / "이 Mac".
* Primary action: **copy** (click/tap/Enter). Confirmation: brief check-mark morph + "Copied".
* Secondary: Pin/Unpin, Delete (from all devices; undo snackbar/toast for 4 s on mobile), Share
  (mobile), Open link (URLs), Save image (mobile), Quick Look / preview (Space on macOS).
* Search field always available (⌘F / Ctrl+F); case-insensitive; matches text and device names.
* Filters as a segmented control / chips: **All · Text · Links · Images · Pinned**.
* Empty state: glyph + "Nothing here yet" + "Copy something on any of your devices."
* Desktop keyboard: ↑/↓ select, Enter copy (and close the panel), ⌘/Ctrl+1…9 quick copy,
  ⌘/Ctrl+P pin, ⌘/Ctrl+⌫/Delete delete, Esc close.

### 4.5 Devices

* "This device" card at top with editable name and platform glyph.
* My devices: glyph, name, platform model text, status dot (green Connected / gray Last seen …).
  Context menu / swipe: **Rename** (own only), **Remove…** (confirm: "Remove ‘Pixel 9’? It will stop
  syncing with your devices.").
* **Add device** button (accent).
* Advanced: "Leave my devices" (this device starts a new, empty group) — confirm dialog.

### 4.6 Settings

| Group | Setting | Default |
|---|---|---|
| Sync | Pause syncing | off |
| Sync | Copy incoming clips automatically | on |
| Sync | Sync images | on |
| Desktop | Open at login | on |
| Desktop | Global shortcut for history | macOS ⌃⌘V, Windows Win+Alt+V |
| Desktop | Show a notification when a clip arrives | on |
| Mobile | Send clipboard when Nearclip opens | on |
| Mobile | Copy the newest clip when Nearclip opens (if it arrived ≤ 10 min ago) | on |
| Android | Stay connected in the background (persistent notification) | on |
| Privacy | Skip password managers (always on, explained) | — |
| Privacy | Ignore apps… (macOS/Windows list) | 1Password, Bitwarden, KeePassXC, Keychain Access |
| History | Keep history for | 30 days (1 day / 7 days / 30 days / Forever) |
| History | Clear history (on all devices) | — |
| About | version, "Local network only · End-to-end encrypted", licenses | — |

## 5. Platform blueprints

### macOS (Swift, SwiftUI + AppKit, macOS 14+)

* **Menu bar extra** (template glyph). Click → borderless floating **panel** (NSPanel, 380 × ≤ 560 pt,
  system material / Liquid Glass on macOS 26+, 14 pt corner radius) anchored below the icon:
  header (title + connected-device avatars + gear), search field (focused on open), filter control,
  history list, footer status ("Connected to 2 devices" with green dot · Pause).
* **Global shortcut** (⌃⌘V) opens the same panel centered on the active screen (Spotlight-style).
  Enter copies; optional "Paste after choosing" uses Accessibility to send ⌘V to the previous app.
* Receive toast: small capsule window under the menu bar icon (non-activating NSPanel).
* Settings window (SwiftUI `Settings` scene, toolbar tabs General / Devices / Privacy / History /
  About). Add-device window as in 4.2. Onboarding window on first launch.
* No Dock icon (LSUIElement) — the app lives in the menu bar; launch at login via SMAppService.
* Clipboard: poll `NSPasteboard.general.changeCount` (0.4 s). Respect `accessBehavior`
  (macOS 15.4+): when it is `.alwaysDeny`/`.ask`, show a banner in the panel with "Open System Settings".

### Windows (C#, WinUI 3 / Windows App SDK, Windows 10 1809+, best on Windows 11)

* **Tray icon** (light/dark variants). Left click → **flyout window** like Win+V: 360 × 520, Mica
  (Acrylic fallback), 8 px radius, positioned above the taskbar near the tray; closes on deactivate.
  Same content as the macOS panel. Right click → menu (Open, Add device…, Pause syncing, Settings, Quit).
* **Global hotkey** Win+Alt+V (configurable) opens the flyout near the cursor/center.
* Receive toast: small borderless Mica window above the tray, 2.5 s.
* **Settings window**: NavigationView (General, Devices, Privacy, History, About) with Windows 11
  settings-card rows. Add-device dialog as in 4.2. Onboarding window on first launch.
* Clipboard: `AddClipboardFormatListener`; honour the exclusion formats in PROTOCOL.md §8.
* Startup: HKCU `Run` key. Key storage: DPAPI (CurrentUser). Single instance.

### Android (Kotlin, Jetpack Compose, Material 3, minSdk 26)

* Single activity. Top app bar "Nearclip" + device-status chip (avatars + "2 connected").
  Search bar, filter chips, history list with cards; extended FAB **Send clipboard**.
* Bottom sheet / screen for Devices and Add device (Scan QR with CameraX, show my QR, nearby list).
* Foreground service (type `connectedDevice`) while "Stay connected" is on: notification
  "Nearclip · Connected to 2 devices" with **Send clipboard** and **Pause** actions.
* Quick Settings tile "Send clipboard"; share target (text, images); `PROCESS_TEXT` action
  "Send to my devices". Sending from background surfaces uses a transparent, focus-taking activity
  that reads the clipboard, sends, and finishes instantly with a toast.
* Edge-to-edge, predictive back, dynamic color, haptics on copy.

### iOS (Swift, SwiftUI, iOS 17+)

* NavigationStack "Nearclip" (large title). Under it: status capsule (avatars + "2 connected").
  Hero card "Send what you copied" with the system **PasteButton** (no permission prompt) when the
  clipboard changed. History list with search (`.searchable`), swipe actions, context menus.
* Toolbar: Devices (sheet), Settings (sheet). Add device sheet with QR scanner (AVFoundation), my QR,
  nearby list; handles `nearclip://pair` links from the Camera app.
* Foreground only networking; when the app becomes active: reconnect, catch up, apply 4.3 rules.
* Haptics: `.success` on pair, light impact on copy.

## 6. Accessibility

VoiceOver / Narrator / TalkBack labels on every control (e.g. "Copy ‘hello world’ from iPhone,
2 minutes ago"), Dynamic Type / text scaling without truncating actions, contrast ≥ 4.5:1, full
keyboard access on computers, Reduce Motion and Reduce Transparency respected.

