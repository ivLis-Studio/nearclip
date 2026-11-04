# Apple review update — 2026-11-04

Status: macOS and iOS/iPadOS **1.2.0 (build 3)** were submitted in App Store Connect. Both platform version pages were observed **Waiting for Review** on November 4, 2026 (KST). This confirms submission, not approval or public availability.

The supplied rejection was for macOS 1.0.0 (1), Guideline 2.3.10. Apple specifically requested removing Android references from the description. After correcting the metadata, the user requested using the latest uploaded builds on both platforms. The earlier 1.0 submissions were withdrawn and superseded by 1.2.0 (3).

## Saved listing changes

- English and Korean descriptions, promotional text and keywords now focus on Mac, iPhone, iPad and Nearclip itself. The shared localized subtitles were also saved.
- The descriptions distinguish account-free local sharing from optional Tailscale sign-in and describe iOS clipboard access as user initiated.
- Review notes preserve the incoming TCP listener, Bonjour, sandbox entitlement and optional remote-connection explanation. They explicitly identify 1.2.0 (3) as the current review target.
- A reply explaining the metadata correction was sent to the original macOS review conversation. `app-review-reply-2026-11-04.txt` records that sent reply; its reference to build 1.0.0 describes the selection at the time of that reply, before the later request to use 1.2.0. The final submitted build is 1.2.0 (3).
- English and Korean screenshots were replaced for Mac, iPhone medium/large displays, and iPad 13-inch displays: two images per device class and language, 16 images in total. Third-party-platform promotional captions and launch-film frames were removed from the Apple renderer. Existing source assets remain separate.

## Selected builds and distribution

- macOS: 1.2.0 (3), build ID `f4c0f057-7c09-4d8c-81dc-b6a45f2beb3d`.
- iOS/iPadOS: 1.2.0 (3), build ID `78e7fcc5-8742-4486-addf-9dea042b21e6`.
- Both uploaded builds were observed Ready to Submit before selection. No replacement release binaries were uploaded in this run. The local Mac debug/CLI builds were used to prepare screenshot fixtures.
- The existing availability settings showed 174 available territories and France as the sole unavailable territory. Availability was preserved. The missing macOS build export-compliance answers were completed with standard encryption used alongside OS cryptography and no French distribution. No ANSSI approval or new French filing is claimed.

## Verification and artifacts

```sh
python3 docs/store/check-app-store.py --export dist/store/apple-metadata-2026-11-04
```

All ten localized text fields passed character limits and the other-platform-reference check. All 16 rendered screenshots passed RGB/no-alpha and size checks. OCR found no blocked platform names in the rendered files; representative exports were visually inspected. The Mac app and CLI builds succeeded. Python compilation, shell syntax and `git diff --check` passed.

The capture helpers now use Apple-focused fixture peers. The Mac helper seeds the device name before encrypted-state migration. The mobile helper creates and cleans up its own simulator instead of erasing an existing user simulator; its updated capture workflow was syntax-checked, not executed end to end during this store operation. The mobile images used here are curated existing native captures, and the Mac images are native preview captures with synthetic clipboard fixtures. These are marketing artifacts, not new physical-device interoperability acceptance.

Local assets and portal evidence are under `dist/store/apple-metadata-2026-11-04/` (ignored by Git), including `upload/`, `artwork-ocr.txt`, and `evidence/`. The 1.0 submission evidence is superseded by the `mac-1.2-review-*` and `ios-1.2-review-*` records. The original missing working-directory issue was repaired with a compatibility symlink; Computer Use succeeded after the desktop app restarted.

Authoritative version pages: [macOS](https://appstoreconnect.apple.com/apps/6826568136/distribution/macos/version/inflight), [iOS/iPadOS](https://appstoreconnect.apple.com/apps/6826568136/distribution/ios/version/inflight).

Apple guidance: [Guideline 2.3.10](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata), [export compliance workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/).
