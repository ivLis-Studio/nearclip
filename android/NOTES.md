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


