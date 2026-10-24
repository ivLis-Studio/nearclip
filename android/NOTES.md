# Nearclip Android — worklog

Running notes so work can resume after a context reset. Newest entries at the bottom of each section.

## Layout
- core/  pure Kotlin/JVM: crypto, framing, handshakes, sessions, engine, file store, pairing URI. JUnit 5 tests.
- cli/   PROTOCOL §9 headless peer (installDist → cli/build/install/cli/bin/cli).
- app/   Compose app (studio.ivlis.nearclip).

## Toolchain decisions
- Gradle 9.7.1 wrapper (generated from the cached distribution), AGP 9.4.1 (built-in Kotlin), Kotlin 2.4.21.
- JAVA_HOME = Android Studio JBR 21. Homebrew JDK 27 is too new for Gradle.
- Compose BOM pinned to 2026.06.01 (UI 1.11.4, M3 1.4.0): 2026.08.00+ needs compileSdk 37 (task requires 36).
- core-ktx 1.18.0 (1.19 needs compileSdk 37), activity-compose 1.13.0, lifecycle 2.10.0, navigation 2.9.8, CameraX 1.5.3, ZXing 3.5.4.

## Engine design
- One engine thread (ScheduledThreadPoolExecutor(1)) owns all state; sockets use blocking I/O on worker threads.
- Session reader hands JSON messages to the engine synchronously (call{}), chunks are streamed to a temp file with
  incremental SHA-256 on the reader thread; writer prefers JSON messages over blob chunks.
- Semantics aligned with the Swift reference (apple/NearclipKit/Sources/NearclipKit/Node.swift):
  monotonic ts = max(now, newestLocalTs+1); apply = live && src != me && ts > newestLocalTs;
  deleted events for every fresh tombstone (also own deletes); list = current group only;
  server remembers (observed remote IP, first advertised port) as the client's endpoint;
  inviter bumps joiner record updatedAt = max(now, old+1); joiner bumps own record after joining.
- Extra (documented): joiner announces removed=true to its old group before switching (if it had peers).
  (Clear history deletes every clip incl. pinned ones — changed in session 2 to match PROTOCOL §6.3.)

## Commands / status
All commands run from android/ with JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home".

- 2026-10-24 ./gradlew :core:test → 22 tests green (VectorsTest 12 incl. every frame payload + SAS 231291, ModelTest 5,
  LoopbackTest 5: QR pairing + text both ways + 2.6 MB 3-chunk image + delete + restart catch-up (text + image) +
  removal → left; code pairing decline/accept + catch-up + rename gossip; 3-node mesh forwarding of clips and deletes;
  duplicate dials collapse to one session; single-use tickets + group isolation).
- ./gradlew :cli:installDist → cli/build/install/cli/bin/cli (path auto-detected by tools/interop/run.py).
- python3 tools/interop/run.py --only swift,kotlin → 9/9; full run with dotnet → 24/24 (all mesh permutations).
- ./gradlew :app:assembleDebug → app/build/outputs/apk/debug/app-debug.apk (no warnings after cleanup).
- Gradle file watching disabled (org.gradle.vfs.watch=false): two idle daemons spun at 250–570 % CPU in this shared folder
  and blocked new builds; they had to be killed with SIGKILL.

## Emulator
- New AVD nearclip_pixel_api36 (pixel_9, system-images;android-36.1;google_apis;arm64-v8a); avdmanager wrote
  placeholder values (<build>, <temp>) that were fixed in its config.ini; hw.keyboard=yes, virtualscene back camera, 3 GB.
- Started headless: emulator -avd nearclip_pixel_api36 -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -port 5584
  → serial emulator-5584. Log: /tmp/nc-emulator.log.

## Session 2 (2026-10-24, after context compaction)

### Changes
- Theme: custom Typography with LineBreak (titles Balanced, body HighQuality, both WordBreak.Phrase) — Korean no
  longer strands syllables ("…확인하세 / 요", "클 / 립보드"). LocalContentColor = onSurface so screens drawn outside
  a Scaffold (onboarding) are not black-on-dark.
- Clear history now deletes every clip incl. pinned ones (PROTOCOL §6.3; Swift/Windows do the same); copy updated.
- Korean strings aligned with apple/tools/ko.json wherever the concept exists (87 shared strings identical):
  클립 (not 항목), 받은 클립 자동으로 복사, 영구 보관, 종단 간 암호화, 휴대폰, 암호 관리자, 재개, 기기 추가하기, etc.
- Devices: "Leave my devices" hidden while the group has no other devices.
- Add device sheet + onboarding step 3 show "Name on your other devices · <name> · Rename" (rename before pairing).
- Licenses: the Apache text is reflowed into paragraphs (was 76-column hard-wrapped monospace).
- MemberSession lock: java.lang.Object monitor → ReentrantLock + Condition (removes the Kotlin warning).
- Lint: fixed NewApi (RELEASE_OR_CODENAME on 26–29), LocalContext resource reads → LocalResources/stringResource,
  KTX toUri, removed 41 unused drawables + unused string (moved to /tmp/nc-trash), mipmap-anydpi-v26 → mipmap-anydpi,
  BatteryLife suppressed at the single user-initiated call (Actions.requestUnrestrictedBattery) with rationale,
  app/lint.xml ignores only OldTargetApi / compileSdk-37 (the brief fixes SDK 36). Result: "No issues found."
- New instrumented test app/src/androidTest/…/SensitiveClipTest.kt (androidx.test core/runner 1.7.0, ext-junit 1.3.0).

### Verification (emulator-5584, AVD nearclip_pixel_api36, Android 16)
- ./gradlew :core:test :cli:installDist :app:assembleDebug :app:assembleRelease :app:assembleDebugAndroidTest
  :app:lintDebug → BUILD SUCCESSFUL; core 22/22 (Loopback 5, Model 5, Vectors 12); lint "No issues found.".
- python3 tools/interop/run.py --only swift,kotlin → 9/9; python3 tools/interop/run.py → 24/24.
- SensitiveClipTest on the emulator: OK (1 test) twice; peers received only the ordinary clip.
- Release APK (R8, signed with the local debug key via apksigner into /tmp): live receive + share-send + image
  receive + My QR + scanner + settings worked, no crash in logcat -b crash.
- 6.4 MB PNG (7 chunks) from Swift: SHA-256 on the phone = sender's (475df81b…); Save image → Pictures/Nearclip/
  (MediaStore row, 6418904 bytes, "Saved to Pictures.").
- Reboot: SyncService came back as FGS type 0x10 via the boot receiver; peers saw peer_up without opening the app.
- Clear history from Settings: Swift and Kotlin peers emitted deleted for all 11 clips (incl. pinned), Swift list = [].
- Leave my devices: peers got members with Pixel 9 removed:true + peer_down; phone shows a fresh solo group.
  Re-joined through a fresh Swift QR link; the Kotlin peer converged on the record after connecting (LWW).
- Screenshots: docs/screenshots/android/{en,ko}-{light,dark}/ 00–14 (+15 license text in en-light/ko-dark),
  flows/01–37. All contact sheets inspected.

### Emulator / peers
- Peers in /tmp/nc-peers.ENAfv8 (mac = Swift :47000, pc = Kotlin :47001, imac = Swift :47002, solo group).
- adb forward tcp:45821 tcp:45821 must be re-added after an emulator reboot.

### Protocol issue found (reported to the lead, not changed unilaterally)
Stale tombstone re-removes a re-added device. Repro (/tmp/nc-stale-tombstone.py, uses tools/interop/run.py's Peer):
A+B paired; C paired; A removes C (B stores the tombstone); B goes offline; C re-joins via A's QR (same device id,
A bumps C's record); A goes offline; B restarts; C dials B → B's attach sees C's tombstone → bye removed (§4.3)
→ C leaves again ("left", reason "removed"). Same result for swift/swift/swift, kotlin/kotlin/kotlin and
swift/dotnet/kotlin. Fix options: rotate the device id when a device leaves/is removed (no wire change), or exchange
welcome + member LWW merge before deciding on bye removed.

## Remote connection (2026-10-24)

- Engine: tailnet discovery matches peer hostnames `nearclip-<slug>-<id8>`; candidates are raced (LAN first, tailnet
  +400 ms) through the bridge proxy, or directly when the OS already has a tailnet address; 6 LAN + 2 tailnet endpoints
  remembered; `networkChanged(netInfo)` redials at once. `:core:test` 24/24.
- App: SettingsStore.remoteEnabled, runtime/NetInfo.kt, RemoteRows in Settings, route text in Devices, suggestion
  link, Custom Tab sign-in, licenses section for the embedded node (assets/THIRD_PARTY_NOTICES.txt from
  tailnet/notices). Proguard keeps TailnetNative.
- tsnet panicked inside the app sandbox ("no safe place found to store log state"): the bridge now sets
  TS_LOGS_DIR to the node's directory. Found on the emulator; fixed in tailnet/bridge/bridge.go.
- Verified on emulator-5584 (tools/acceptance/android_remote.py, throwaway control server): Settings "켜짐 · …",
  Devices "MacBook Pro · 연결됨 · 원격", clip from the LAN-unreachable peer shown and applied to the clipboard.
- Real service (login.tailscale.com, real account, tools/acceptance/real_remote.py): emulator and macOS app signed in,
  Devices "남준서의 MacBook Pro · 연결됨 · 원격", clips both ways, direct WireGuard path; sign-out expires the node key.
- The test AVD runs with -no-snapshot-save: restarting the emulator returns the app to its quick-boot snapshot
  (06:26 group), which silently undoes later pairings. Re-pair after an emulator restart (real_remote.py --pair).

## Opt-in Shizuku instant capture (2026-10-24)

- Android 1.0.1, versionCode 2. Sync settings now contains "복사한 항목 바로 Nearclip에 불러오기", default false.
  Tapping it opens install → start → allow guidance. Existing permission does not activate it until Turn on is tapped;
  granting permission from this setup flow activates it. Enabling also enables Stay connected. Switch has a TalkBack label.
- Reviewed ClipStack's ShizukuManager/ShizukuClipboardService at commit 934eb9c:
  https://github.com/liliangxing/ClipStack . Reference for install/start/permission and binder lifecycle; no code copied.
  Nearclip calls the clipboard through ShizukuBinderWrapper instead of running a separate UserService, so no helper
  process is left behind when the user opts out. Clipboard arguments adapt to platform signatures.
- Shizuku API/provider 13.1.5 (MIT), HiddenApiBypass 6.1 (Apache-2.0), license text in the app. 6.2 needs compileSdk 37;
  6.1 works with the app's SDK 36 and Android 16 emulator. Hidden-API exemptions limited to the clipboard interfaces.
- Description-first checks skip own/sensitive clips without content access. Recheck the fetched ClipData flags to
  cover a change between metadata and data reads. Text/links only; no content/file URI reads through shell grants.
  Capture stops while paused, opted out, or when neither UI nor SyncService is active.
- Binder death updates setup and persistent notification ("Shizuku 꺼짐"); restarting Shizuku restores readiness
  without toggling the setting. Non-root users restart Shizuku after reboot. Android's Shell paste-access toast was
  observed and is explained in the sheet. Nearclip does not change global Android privacy settings.
- Verification: debug/release build, lintRelease (no issues), existing core test task (24 tests, up-to-date).
  New InstantCaptureTest against the live Android 16 clipboard/engine: OK (1 test), covering background text capture,
  sensitive/own-marker exclusion, pause/resume and opt-out. Existing SensitiveClipTest: OK (1 test).
- `tools/acceptance/android_capture.py`, debug and signed R8 release on emulator-5584 + Swift LAN peer:
  off → no background send; opt-in → real Contacts copy received exactly once at peer; incoming text reaches Nearclip
  without echo; opt-out → no background send. Uses UI rather than run-as so the signed release is testable.
  Contacts formats names during input, so compare the actual field contents with the peer payload.
- Release 1.0.1 installed in place on emulator; same signer as the previous APK (SHA-256 fecc2790…759cb46).
  Tested Shizuku server termination → settings + notification update, then restart → ready again, on the release.
  Screenshots in docs/screenshots/android/instant-capture/. Galaxy S25 and other Android/OEM versions remain untested.
- `dist/Nearclip-Android.apk` replaced with the signed release. Prior APK is recoverable from
  ~/.Trash/Nearclip-Android-previous.Nm6hF0/Nearclip-Android.apk. macOS installed app and pairing window left untouched.

## Large-image progress (2026-10-24, PROTOCOL §6.6)

- Android 1.0.2, versionCode 3. Engine: `incoming` announcements, one transfer per clip id (preparing / receiving /
  failed: cancelled, disconnected, corrupt, timeout after 60 s without progress), failing only when no session still
  brings the clip. CLI: `transfer` / `announced` events, `announce_image` / `cancel_image`, `send_image` with `id`.
- Sending: `sendImage(uri)` announces before reading and encoding, and cancels when the image cannot be read.
- Receiving in the app: a card on top of the history ("MacBook Pro에서 이미지 받는 중…", indeterminate with "준비 중…",
  then "3.1 / 10.6 MB"), only for transfers still running after 0.3 s; the clip takes its place. Failures: snackbar.
- Outside the app: channel `incoming_images` (high importance, no sound or vibration): a banner when it starts, quiet
  progress updates, then a "…에서 복사됨" banner with the thumbnail (decoded off the main thread) for 4 s, or
  "이미지를 받지 못했습니다 · …에서 다시 복사해 보세요."
- Found while testing: NotificationCompat's setSilent puts notifications into a "silent" group, which bundled the
  progress notification with the persistent one and hid the bar. The channel is silent instead, and the transfer
  notifications do not call setSilent. (The first channel id, `transfers`, only ever existed in debug builds.)
- `tools/acceptance/android_transfer.py` on emulator-5584 with a Swift peer at `--pace 900000`: announce and cancel
  in the app, card progress 5.2 / 10.6 MB then the clip, background start banner + progress in the shade + "Copied
  from" banner with the thumbnail, background failure banner, in-app failure snackbar, and an image shared into
  SendActivity announced first (the peer saw `preparing`, the size 0.2 s later, then the clip with the same id). The
  shell cannot grant MediaStore or document URIs to the app, so the test serves the image from the debug app's own
  FileProvider (run-as). lintRelease: no issues; core tests 24/24.
- `dist/Nearclip-Android.apk`: signed release 1.0.2 (sha256 39e14649…), same signer; the 1.0.1 APK is in
  ~/.Trash/nearclip-apk-1.0.1.Nq8oXJ/.


