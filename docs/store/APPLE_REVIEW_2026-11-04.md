# Apple metadata correction — 2026-11-04

Status: local preparation only. App Store Connect has not been edited or resubmitted in this run. The user re-selected the Computer Use plugin, but the running session still exposes no browser/computer interaction tool.

The supplied App Store Connect page shows macOS 1.0.0 (1) rejected under Guideline 2.3.10 on November 4. Apple specifically requests removal of Android references from the product description. The earlier uploaded 1.2.0 (3) build and the currently selected review build are separate states; do not report 1.2 as selected without checking the portal.

## Prepared changes

- `app-store.json`: English and Korean descriptions for macOS and iOS/iPadOS now focus on Mac, iPhone, iPad, and Nearclip's own clipboard/history experience. Promotional text, subtitles and keywords are consistent with that focus.
- No production app behavior was changed. Local sharing and optional Tailscale account requirements are described separately. iOS foreground/user-initiated clipboard limitations remain explicit.
- Review notes retain the incoming TCP listener, Bonjour, sandbox entitlement and optional remote-connection explanations needed for the earlier review questions.
- `app-review-reply-2026-11-04.txt` is an unsent draft. Send it only after the corresponding fields have actually been saved for both platforms; adjust its scope if one platform cannot yet be edited.

## Validation and export

```sh
python3 docs/store/check-app-store.py --export dist/store/apple-metadata-2026-11-04
```

The validator checks field lengths and other-platform marketing names. The previous committed copy fails in six fields; the updated copy passes all ten localized fields. The exported 17 text files are local upload/editing inputs, not proof of portal changes.

## Remaining portal work

1. Read the current macOS and iOS/iPadOS version pages, supported listing languages and review status.
2. Save each platform's matching descriptions and promotional text in English and Korean. Preserve support/privacy URLs, contact details and previously accepted technical explanations.
3. Inspect the registered screenshots and previews for other-platform promotional copy. Local `promo/appstore.html` still contains legacy cross-platform captions and film frames, and the old screenshot fixtures include other-platform device names; do not regenerate and upload those legacy assets without adapting and inspecting them first.
4. For a metadata-only correction, reuse the currently selected build unless another verified issue requires a binary change. Do not cancel an unrelated active iOS review unnecessarily.
5. Send the matching reply and resubmit eligible versions. Reopen the review pages and retain the actual resulting state. A saved description, a reply, a build upload and Waiting for Review are separate outcomes.

Apple guidance: [replying to review messages and metadata-only resubmission](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages), [Guideline 2.3.10](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).
