# Google Play first release — 2026-11-28

App: Nearclip (`studio.ivlis.nearclip`), Android 1.2.1, version code 6.

## Artifact and validation

- Signed App Bundle SHA-256: `7d0de8fba53262d3019a1bd2a1b018a497630112080c2c8ad5300775a2bcf638`.
- Min SDK 26, target SDK 36. Bundletool validation and JAR signature verification passed.
- Limit ABIs to arm64-v8a, armeabi-v7a and x86_64: CameraX also included x86, for which the Tailscale JNI is not built. Every offered ABI now includes that JNI library.
- All 8 bundled 64-bit native ELF files have LOAD segments supporting 16 KB pages.
- Google pre-review checks flagged the old HiddenApiBypass SDK in code 5. Android 1.2.1 removes that dependency entirely and moves opt-in clipboard access to Shizuku's documented UserService; the ordinary app uses its own AIDL. DEX inspection confirms the bypass SDK is absent.
- InstantCaptureTest passed on the disposable Android 16/API 36.1 emulator with real Shizuku 13.6.0: **OK (1 test)**, 18.913 seconds. It covers background text, sensitive and own-origin filters, pause/resume, actual helper exit after pause/opt-out, and helper termination/rebinding. Test preparation grants Shizuku's runtime permission, then restarts its server so its configuration reflects that grant; this does not change end-user permission behavior.
- 34 Android core tests passed. Release lint: no errors, one existing DiscouragedApi warning.
- PR #6 native Apple, Windows and iPhone UI checks passed before merge.
- ConnectedDeviceServiceTest ran on a new Android 16/API 36.1 emulator against a real Swift protocol peer: **OK (1 test)**, 42.906 seconds on 1.2.1 (also passed on 1.2.0). It verified foreground service startup, connected-device declaration, delivery of unique peer text and a new image while the Activity was in the background, and service shutdown after opting out. It uses a debug test build; this is distinct from validating the signed production AAB.
- Instrumentation setup drives app APIs. The recorded clipboard transfers and native app UI are real. No user device, notification-reading access, or Tailscale account was used. Shizuku was separately tested only for opt-in clipboard import; the connected-device transfer test leaves that feature off.
- The integration test requires explicit `pairingUri` and `expectedText` arguments and is skipped without them. `reviewCapture=true` additionally waits for a new image and holds native screens for recording. Run it only on a disposable emulator with the debug app, test APK and notification-posting permission installed.

## Listing and declarations

- English and Korean descriptions, 512 px icon, localized 1024×500 feature graphics, and four native Android screenshots per language were saved. Screenshots preserve the full native screen inside a 1080×1920 RGB canvas.
- Newly designed feature graphics are individually labelled AI-assisted in Play Console; native captures and the existing icon are not labelled as generated.
- Free, no ads, no advertising ID. Category: Productivity. Audience: 13–15, 16–17 and 18+; not directed at children under 13.
- IARC questionnaire completed with the owner's explicit agreement; ESRB Everyone and PEGI 3 were issued.
- Local pairing requires no account. App access notes explain two-device LAN pairing and disclose optional external Tailscale sign-in.
- Data safety declares optional device/other identifiers and network diagnostics used for remote connectivity. Tailscale client diagnostic log upload is disabled in the bridge. External authentication is in the system browser; Nearclip has no account registration. Clipboard payloads use the end-to-end encryption exception. User-initiated Tailscale connection is covered by Google's sharing exception, rather than advertised as developer-hosted storage.
- Privacy policy now documents local deletion, external Tailscale node/account deletion, retention, and support. Public deletion URL: https://ivlis-studio.github.io/nearclip/privacy.html#delete-data
- Government, financial and health declarations: no relevant features.
- Distribution: 177 territories; France remains excluded consistently with the existing Apple encryption distribution restriction. No new French filing or approval is claimed.

## Public contact and developer address

The existing developer account is Personal and Non-trader. The app is free, with no ads or in-app purchases. The app-specific public contact uses `support@ivl.is` and the Nearclip website; optional telephone is blank. No physical address was added to the app contact fields. The account's private legal address was not altered. Play Console says choosing monetization makes the full legal address public. This is not proof that the unpublished public listing hides every address field in every jurisdiction; verify the actual public listing once available.

## Foreground-service review video

https://ivlis-studio.github.io/nearclip/assets/media/nearclip-connected-device-review.mp4

Backup download: https://github.com/ivLis-Studio/nearclip/releases/download/v1.2.0/Nearclip-connected-device-review.mp4

44-second H.264 1920×1080 video, with captions explaining the live Android integration run. The native app recording is from the 1.2.0 development test build of the unchanged connected-device transfer flow; 1.2.1 re-ran this integration test successfully. The 1.2.1 change is the separate optional Shizuku path; the test is not shipped inside the production bundle.

Submission status is recorded after the final Play Console confirmation below.
