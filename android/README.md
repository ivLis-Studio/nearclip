# Nearclip for Android

The Android app, the shared Kotlin protocol engine and the interop CLI for Nearclip, the LAN-only universal
clipboard (docs/PROTOCOL.md, docs/DESIGN.md). Native Kotlin + Jetpack Compose / Material 3; no server, no account.

| Module | What it is |
|---|---|
| `:core` | Pure Kotlin/JVM library (no Android APIs): P-256 / HKDF / AES-GCM over JCA, framing, member / QR / code handshakes, encrypted sessions, the sync engine, persistence, pairing URIs. JUnit 5 tests. |
| `:cli` | Headless peer implementing PROTOCOL §9 for `tools/interop/run.py`. |
| `:app` | The phone app (`studio.ivlis.nearclip`, minSdk 26, compile/target SDK 36). |

## Build

Use the JDK 21 bundled with Android Studio (Homebrew's newer JDKs are too new for Gradle 9.7):

```sh
cd android
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :core:test                 # 22 tests: every spec/test-vectors.json value + loopback scenarios
./gradlew :cli:installDist           # → android/cli/build/install/cli/bin/cli
./gradlew :app:assembleDebug         # → android/app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assembleRelease       # R8-minified, unsigned → app/build/outputs/apk/release/
./gradlew :app:lintDebug             # "No issues found."
```

`local.properties` points `sdk.dir` at `~/Library/Android/sdk`. The Gradle wrapper (9.7.1) is checked in;
AGP 9.4.1 with built-in Kotlin 2.4.21, Compose BOM 2026.06.01 (the newest BOM that still compiles against SDK 36).

### Interop CLI

```sh
android/cli/build/install/cli/bin/cli --state /tmp/peer-a --name "Studio PC" [--port 0]
```

One JSON event per line on stdout, one JSON command per line on stdin, logs on stderr (PROTOCOL §9).
`tools/interop/run.py` finds this path automatically:

```sh
python3 tools/interop/run.py --only swift,kotlin   # 9/9
python3 tools/interop/run.py                       # swift × kotlin × dotnet: 24/24
```

### Tests on a device

`app/src/androidTest/…/SensitiveClipTest` runs against the real clipboard and engine: a clip a password
manager marks `EXTRA_IS_SENSITIVE` is never recorded or sent (send-on-open and "Send clipboard"), an
ordinary clip right after it is.

```sh
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb install -r -t app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w -e class studio.ivlis.nearclip.SensitiveClipTest \
    studio.ivlis.nearclip.test/androidx.test.runner.AndroidJUnitRunner
```

## Trying it on the emulator against a CLI peer

The emulator sits behind NAT (its own address is 10.0.2.15; the Mac is 10.0.2.2), so:

* **Phone → Mac** (QR join, Connect by address, member dials): use host `10.0.2.2` and the peer's port.
  For a QR link, replace the `h=` list with `10.0.2.2`:
  `adb shell am start -a android.intent.action.VIEW -d '<nearclip://pair?…&h=10.0.2.2&p=47000&…>'`
  (or `adb reverse tcp:47000 tcp:47000` and `h=127.0.0.1`).
* **Mac → phone** (code pairing with the phone as inviter, member dials to the phone, joining the phone's QR):
  `adb forward tcp:45821 tcp:45821`, then `{"cmd":"pair_code","host":"127.0.0.1","port":45821}`.
  The forward is lost when the emulator reboots.

DNS-SD browsing works on the emulator (real Macs and iPhones on the LAN show up under Nearby); devices on the
LAN cannot reach the emulator's advertised 10.0.2.15, which is an emulator limitation, not an app one.

## Architecture

```
core  ─ crypto/      Crypto.kt (P-256 ECDH, X9.63, HKDF-SHA256, AES-256-GCM, SHA-256), Bytes.kt
      ─ proto/       Framing (u32 length frames), Hello (byte-exact hello JSON), SecureChannel (nonces/counters),
                     Wire (type bytes, 1 MiB chunk frames)
      ─ model/       Group, MemberRecord (LWW merge), Clip, Tombstone, Endpoint, Platform
      ─ pairing/     PairingUri (nearclip://pair build/parse)
      ─ store/       Store abstraction, FileStore (atomic writes), KeyProtector (group-key wrapping hook)
      ─ engine/      NearclipEngine (single engine thread owns all state), MemberSession (reader/writer threads,
                     streamed blob assembly with incremental SHA-256), Conn, Messages, Persistence, Events
cli   ─ Main.kt      §9 adapter around NearclipEngine + FileStore
app   ─ runtime/     Nearclip (process-wide runtime), SettingsStore, KeystoreKeyProtector (AES-GCM key in the
                     Android Keystore wraps the group key), ClipboardBridge, Discovery (NsdManager +
                     MulticastLock), ImageTools, Notifications, DeviceInfo
      ─ service/     SyncService (FGS type connectedDevice), SendClipboardTileService, receivers (notification
                     actions, boot)
      ─ ui/          MainActivity + NavHost (onboarding, history, devices, settings, licenses, scan, my QR),
                     SendActivity (transparent, focus-taking: share target, PROCESS_TEXT, tile/notification sends),
                     home/, devices/, pairing/, settings/, onboarding/, components/, theme/
```

**Engine.** One thread owns groups, members, history, tombstones and sessions; sockets use blocking I/O on
per-session reader/writer threads that post into it. It implements the member / QR / code handshakes with
transcript hashing over the exact bytes sent and received, inventory/want catch-up, live forwarding, deletion
tombstones (30 days), member LWW gossip, removal → `left`, the one-session-per-peer rule, the §4.4 duplicate
rule and dialing with back-off (20 s → 5 min). Semantics follow the Swift reference where the text is silent.

**Clipboard.** Incoming live clips from other devices go to the clipboard with `setPrimaryClip` (works from the
service). Our own writes carry a marker in the ClipDescription extras, so they are never sent back. Android 10+
only lets the focused app *read* the clipboard; sending therefore happens when Nearclip gains focus ("Send
clipboard when Nearclip opens"), from the FAB, or through the transparent SendActivity (Quick Settings tile,
notification action, share sheet, text-selection menu "Send to my devices").

**Background.** With "Stay connected in the background" on (default), SyncService runs the engine and DNS-SD
(`_nearclip._tcp`, TXT v/id/nm/pf/gt/pm, port 45821 or an OS-assigned fallback) and shows
"Connected to N devices" with **Send clipboard** and **Pause**. When it is off, the engine stops 20 s after
the app leaves the screen.

**Security.** The group key is stored wrapped by a non-exportable AES-256-GCM key in the Android Keystore
(`state.json` contains `"keyProtection":"android-keystore"`). Backups and device transfer exclude app data.
Clips marked sensitive by password managers are never recorded or synced.

## Limits (by design)

* Text up to 4 MiB, images (PNG/JPEG) up to 32 MiB live / 16 MiB in catch-up (PROTOCOL §7 limits); larger text
  is kept locally as "Too large to sync".
* Reading the clipboard needs window focus on Android 10+, so a copy in another app reaches the other devices
  when Nearclip opens or through the tile / notification action / share sheet, not silently in the background.
* Pins are local (PROTOCOL §6.3); "Clear history" deletes every clip, pinned ones included, on all devices.

See `NOTES.md` for the worklog, verification evidence and the spec interpretations taken.

