# Nearclip Protocol v1

Nearclip keeps the clipboard and clipboard history in sync between a user's own devices
(macOS, Windows, Android, iOS). By default it works **on the local network only**: devices discover
each other with DNS-SD (Bonjour/mDNS) and talk directly over TCP. Optionally (section 10) each app runs
an embedded Tailscale node so the same devices also reach each other across networks; Nearclip itself
never runs or needs a server.
All application data is end-to-end encrypted with keys that only paired devices hold.

This document is normative. The Swift (`apple/`), Kotlin (`android/`) and C# (`windows/`)
implementations MUST follow it byte for byte; `spec/test-vectors.json` pins every
cryptographic step and `tools/interop/` runs live cross-implementation tests.

## 0. Conventions

* Integers on the wire are **big-endian**.
* `b64u(x)` = base64url **without padding** (RFC 4648 §5). Decoders MUST accept input with or without padding.
* `hex(x)` = lowercase hexadecimal.
* `utf8("...")` = the UTF-8 bytes of a string literal, no terminator.
* `||` = byte concatenation.
* Times are Unix epoch **milliseconds** (int64).
* IDs (device ids, clip ids, group ids) are **lowercase** RFC 4122 UUID strings, 36 chars,
  e.g. `3f2b8c1e-9a4d-4c47-b0d2-6c1f5e8a9b10`. Implementations MUST lowercase UUIDs they generate
  (Swift's `uuidString` is uppercase) and SHOULD lowercase ids they receive before comparing.
* JSON is UTF-8, RFC 8259. Unknown fields MUST be ignored. Optional fields MAY be omitted; `null`
  MUST be treated as omitted. Non-ASCII characters MAY be escaped or raw.
* Crypto primitives (all available natively on every platform):
  * ECDH over **P-256** (secp256r1). Public keys are **uncompressed X9.63** (65 bytes, `0x04||X||Y`).
    The shared secret `Z` is the raw 32-byte X coordinate (CryptoKit `sharedSecretFromKeyAgreement`,
    .NET `DeriveRawSecretAgreement`, Java `KeyAgreement("ECDH").generateSecret()`).
    Implementations MUST reject public keys that are not 65 bytes / not on the curve.
  * **HKDF-SHA256** (RFC 5869).
  * **HMAC-SHA256**, **SHA-256**.
  * **AES-256-GCM** with 12-byte nonces and 16-byte tags, empty AAD.
  * A CSPRNG for all random values.

`derive(K, label, n)` is shorthand for `HKDF-SHA256(ikm = K, salt = utf8("nearclip-v1"), info = utf8(label), L = n)`.

## 1. Device identity and the group

Every installation has:

| Item | Description |
|---|---|
| `deviceId` | UUID generated on first launch, never changes. |
| `deviceName` | User-visible, editable (≤ 64 chars). Defaults to the OS device/computer name. |
| `platform` | `mac`, `win`, `android`, `ios` (`cli` for test tools). |

Every installation always belongs to exactly **one group**. On first launch it creates a solo group:

| Item | Description |
|---|---|
| `groupId` | UUID |
| `groupKey` K | 32 random bytes. Secret. Store in Keychain / Android Keystore-wrapped / DPAPI. |
| `groupTag` | `hex(derive(K, "group-tag", 8))` — 16 hex chars, public, used in discovery. |
| `authKey` | `derive(K, "auth", 32)` — used as HKDF salt for member sessions. |

Pairing (section 5) copies an existing group's `groupId` + `groupKey` to the new device, which then
abandons its previous group. Every device of a group can add more devices.

### 1.1 Member records

Each device keeps the list of members of its group (including itself):

```json
{"id":"<deviceId>","name":"MacBook Pro","platform":"mac","model":"Mac15,7","app":"1.0.0",
 "addedAt":1792800000000,"updatedAt":1792800000000,"removed":false}
```

`model` and `app` are optional. Records are merged **last-writer-wins by `updatedAt`** (ties: prefer
the record with `removed: true`, otherwise keep the existing one). A record with `removed: true` is a
tombstone: that device may no longer open member sessions (4.3). A device that learns that its own
record is removed **leaves the group**: it wipes `groupKey`, creates a new solo group and keeps its
local history.

## 2. Discovery (DNS-SD)

* Service type **`_nearclip._tcp`**, domain `local.`.
* Instance name: the device name (DNS-SD may append " (2)" etc. on conflict). Never use the
  instance name as an identity.
* Port: the TCP listener port. Preferred port **45821**; if it is taken, use any free port (the
  SRV record carries the real one).
* TXT record keys (all values UTF-8 strings):

| Key | Value |
|---|---|
| `v` | `1` |
| `id` | deviceId |
| `nm` | device name, truncated to ≤ 60 UTF-8 bytes on a character boundary |
| `pf` | platform |
| `gt` | groupTag |
| `pm` | `1` while the device shows its "Add device" UI (pairing mode); otherwise absent or `0` |

A device advertises while its listener runs and browses continuously while it is active (mobile:
while in the foreground; Android also while its background service runs).

Discovered services whose `gt` equals our groupTag are **members**; the others are **nearby
devices** (candidates for code pairing).

mDNS is often unreliable (guest Wi-Fi, VLANs, emulators, VMs), so implementations MUST also dial
explicit `host:port` endpoints: the addresses in a pairing QR code, the addresses a peer reported in
`welcome.addrs` (remembered per member), addresses the user types in and, with remote connection on,
the members found in the tailnet (10.2).

## 3. Transport and framing

* One TCP connection per session. The dialer is the **client (C)**, the listener the **server (S)**.
* Every frame is `u32 length || payload` with `1 ≤ length ≤ 17 825 792` (17 MiB). A receiver MUST
  close the connection on a length outside that range.
* **Handshake frames** are plaintext UTF-8 JSON objects (sections 4 and 5).
* After the handshake every frame is **encrypted**: `payload = ciphertext || tag` from AES-256-GCM
  with the direction key and `nonce(counter)`, empty AAD.
  * Each direction has its own key (`kC2S` for frames the client sends, `kS2C` for frames the server
    sends) and its own 64-bit counter that starts at **0** and increments by 1 after every frame.
  * `nonce(counter) = 0x00000000 || u64(counter)` (12 bytes).
  * A frame that fails to decrypt is fatal: close the connection.
* Encrypted plaintext starts with a **type byte**:
  * `0x01` JSON message: `0x01 || utf8(json)`.
  * `0x02` blob chunk: `0x02 || clipId (36 ASCII bytes) || u32(chunkIndex) || data` with
    `1 ≤ len(data) ≤ 1 048 576` (1 MiB).
  * Unknown type bytes MUST be ignored.
* Keep-alive: each side sends `{"t":"ping"}` when it has sent nothing for **15 s** and answers every
  `ping` with `{"t":"pong"}`. A side that has received nothing for **45 s** closes the session.
  TCP keep-alive and `TCP_NODELAY` SHOULD be enabled.

## 4. Member sessions

### 4.1 Handshake

1. C generates an ephemeral P-256 key pair `(eC, EC)` and 16 random bytes `NC`, then sends
   `helloC = {"t":"hello","v":1,"mode":"member","id":<C id>,"gt":<groupTag>,"e":b64u(EC),"n":b64u(NC)}`
2. S compares `gt` with its own groupTag. On mismatch it sends the plaintext frame
   `{"t":"error","code":"group_mismatch"}` and closes. Otherwise it generates `(eS, ES)` and `NS` and sends
   `helloS = {"t":"hello","v":1,"mode":"member","id":<S id>,"gt":<groupTag>,"e":b64u(ES),"n":b64u(NS)}`
3. Both compute, from the **exact payload bytes** of the two hello frames as sent/received (never
   re-serialize):
   * `TH = SHA-256(helloC_bytes || helloS_bytes)`
   * `Z = ECDH(own ephemeral private key, peer ephemeral public key)`
   * `okm = HKDF-SHA256(ikm = Z, salt = authKey, info = utf8("nearclip-session") || TH, L = 64)`
   * `kC2S = okm[0..32)`, `kS2C = okm[32..64)`
4. From now on all frames are encrypted. The **first** encrypted message of each side MUST be
   `welcome` (4.2). A device without the group key derives different keys and fails here.
5. A side MUST close the connection if the peer's hello `id` equals its own deviceId.

### 4.2 welcome

```json
{"t":"welcome","device":{<own member record>},"members":[<all member records it knows>],
 "addrs":[{"h":"192.168.0.12","p":45821}]}
```

`addrs` lists the sender's reachable listener endpoints (IPv4, no loopback, no link-local). The
receiver merges `members` (1.1), remembers `addrs` as the peer's endpoints, then sends its inventory (6.2).
With remote connection on, `addrs` also contains the sender's tailnet endpoint (10.2). A server MAY also
remember the remote address of the TCP connection, but never a loopback address that came from its own
tailnet bridge (10.1).

### 4.3 Removed devices

Both sides always exchange `welcome` first and merge the received records (1.1). Only **after** merging the
peer's `welcome`, a side whose record of the peer is (still) a tombstone sends
`{"t":"bye","reason":"removed"}` and closes. Merging first matters: a device that was removed and later
re-added carries a newer record of itself than a member that was offline during the re-add, so the stale
tombstone loses; a device that was removed while it was offline still loses against the newer tombstone.
A side that receives an **encrypted** `bye` with reason `removed` leaves the group (1.1). Only a group
member can produce that frame.

### 4.4 One session per peer

If a session with peer P completes while another session with P is open, keep the session whose
**client has the lexicographically smaller deviceId** and close the other after sending
`{"t":"bye","reason":"duplicate"}`. Both sides apply the same rule and therefore agree.

### 4.5 Dialing policy (SHOULD)

* On discovering a member that is not connected: dial at once if `ownId < peerId`, otherwise dial
  if it is still not connected 3 s later.
* Every 20 s, dial disconnected members at their remembered endpoints (exponential back-off per
  member up to 5 min; reset when discovery sees the member again).
* A dial attempt starts **all** candidate endpoints of the member at once (the discovered service,
  every remembered endpoint, tailnet candidates) and keeps the first connection that opens; the other
  attempts are cancelled. Tailnet candidates (10.3) start 400 ms after the others so a reachable LAN
  path wins. Pairing connections (section 5) race their targets the same way.
* Remember up to 6 LAN endpoints and up to 2 tailnet endpoints per member (newest first).
* On a network change (interface up/down, Wi-Fi ↔ cellular, wake from sleep, app back in the
  foreground): close sessions that received nothing for 20 s, reset all back-off and dial at once.
* Never dial tombstoned members.

## 5. Pairing

Pairing gives a new device (the **joiner**, always the TCP client) the group credentials of an
existing member (the **inviter**, the TCP server). Pairing connections are separate from member
sessions and are closed once the result is delivered; the joiner then opens a normal member session.

### 5.1 QR pairing

The inviter creates a **ticket**: 16 random bytes `T`, valid for 10 minutes, single use. Only the
most recent ticket is valid. It shows a QR code with the URI

```
nearclip://pair?v=1&id=<inviter id>&nm=<name>&pf=<platform>&h=<ip1>,<ip2>&p=<port>&s=<b64u(T)>
```

(query values percent-encoded; `h` is a comma-separated list of IPv4 addresses and may be empty).
With remote connection on, `h` also lists the inviter's tailnet IPv4 (its tailnet node listens on `p`
as well, 10.1), so a joiner in the same tailnet can pair from another network.

1. The joiner dials one of the addresses (or the discovered service with that `id`) and sends
   `helloC = {"t":"hello","v":1,"mode":"pair-qr","id":<joiner id>,"e":b64u(EC),"n":b64u(NC)}`
2. Without a valid ticket the inviter answers `{"t":"error","code":"no_ticket"}` and closes; otherwise
   `helloS = {"t":"hello","v":1,"mode":"pair-qr","id":<inviter id>,"e":b64u(ES),"n":b64u(NS)}`.
3. `TH = SHA-256(helloC_bytes || helloS_bytes)`,
   `okm = HKDF-SHA256(ikm = Z, salt = T, info = utf8("nearclip-pair-qr") || TH, L = 64)` → `kC2S || kS2C`.
4. Joiner → inviter (encrypted): `{"t":"pair_request","device":{<joiner member record>}}`.
   If it fails to decrypt (wrong `T`) the inviter closes; after 10 failures the ticket is revoked.
5. Inviter → joiner (encrypted):
   `{"t":"pair_accept","group":{"id":<groupId>,"key":b64u(K)},"device":{<inviter record>},"members":[...]}`
   The ticket is consumed. The inviter adds the joiner's record (`addedAt = updatedAt = now`) and
   broadcasts `members`. No confirmation is needed: scanning the QR code proves physical presence.

### 5.2 Code pairing (numeric comparison)

For computers or whenever scanning is impossible. The joiner picks a *nearby device* (section 2) or
enters `host:port`.

1. Joiner: `helloC = {"t":"hello","v":1,"mode":"pair-code","id":<id>,"e":b64u(EC),"nm":<name>,"pf":<platform>}`
2. The inviter generates `NS` (16 random bytes) and replies
   `helloS = {"t":"hello","v":1,"mode":"pair-code","id":<id>,"e":b64u(ES),"c":b64u(commit),"nm":<name>,"pf":<platform>}`
   with `commit = SHA-256(utf8("nearclip-commit") || ES || EC || NS)`.
   An inviter already handling a code request answers `{"t":"error","code":"busy"}` and closes.
3. Joiner → inviter (plaintext): `{"t":"pair_nonce","n":b64u(NC)}` (`NC`: 16 random bytes).
4. Inviter → joiner (plaintext): `{"t":"pair_nonce","n":b64u(NS)}`. The joiner verifies `commit` and
   aborts on mismatch.
5. Both compute
   * `TH = SHA-256(helloC_bytes || helloS_bytes || NC || NS)`
   * `sas = u32(SHA-256(utf8("nearclip-sas") || TH)[0..4)) mod 1 000 000` — six digits with leading
     zeros, displayed as `123 456`
   * `okm = HKDF-SHA256(ikm = Z, salt = utf8("nearclip-pair-code"), info = TH, L = 64)` → `kC2S || kS2C`
6. Joiner → inviter (encrypted): `{"t":"pair_request","device":{<joiner record>}}`
7. The inviter asks its user *"'Pixel 9' wants to join. Make sure it shows 123 456."* [Decline] [Pair];
   the joiner shows the same number and waits. Timeout 120 s.
8. Inviter → joiner (encrypted): `pair_accept` (as in 5.1) or `{"t":"pair_decline"}`.

The commitment prevents an active attacker from choosing keys that make the numbers match (success
probability 10⁻⁶ per attempt). Inviters SHOULD handle one code request at a time and at most 10 per minute.

### 5.3 After pairing

The joiner stores the new group, adopts the received `members`, remembers the inviter's endpoints and
dials a member session. It keeps its local history, but clips that belong to its previous group are
never advertised to the new group (each locally stored clip remembers its `groupId`).

## 6. Messages inside member sessions

All are JSON messages (type byte `0x01`); `t` is the message type.

### 6.1 Clips

```json
{"t":"clip","live":true,"clip":{"id":"<uuid>","ts":1792800000000,"src":"<origin id>","kind":"text","text":"hello"}}
```

| Field | Kind | Meaning |
|---|---|---|
| `id` | all | clip id (UUID), globally unique |
| `ts` | all | creation time at the origin |
| `src` | all | origin deviceId |
| `kind` | all | `text` or `image` (unknown kinds MUST be ignored) |
| `text` | text | the text, ≤ 4 MiB UTF-8 |
| `otp` | text | `true`: a verification code found in a message (6.7); optional, absent otherwise |
| `mime` | image | `image/png` or `image/jpeg` |
| `size` | image | blob length in bytes, 1 … 33 554 432 (32 MiB) |
| `sha` | image | `hex(SHA-256(blob))` |
| `w`, `h` | image | pixel size (optional) |

For `image` the `clip` message is followed (possibly interleaved with other messages) by
`ceil(size / 1 MiB)` chunk frames with indexes `0 … n-1` in order. The receiver assembles them, checks
`size` and `sha`, and only then accepts the clip. If the session closes mid-transfer the partial blob
is discarded.

`live: true` marks a clip that was just copied; `live: false` marks history catch-up.

**Receiving** a clip whose `id` is neither known nor tombstoned:
1. Store it in history (associated with the current group).
2. Forward it to every *other* open member session with the same `live` value — this makes partially
   connected meshes converge.
3. If it is `live`, newer (`ts`) than the newest clip this device produced or applied, and auto-apply
   is enabled, write it to the system clipboard (platform rules: DESIGN.md). Catch-up clips are never
   auto-applied, except by the mobile "copy latest on open" behaviour (DESIGN.md).

Known or tombstoned ids are ignored and not forwarded.

### 6.2 Inventory and catch-up

Right after the `welcome` exchange each side sends

```json
{"t":"inv","clips":[{"id":"…","ts":1792800000000}],"dels":[{"id":"…","ts":1792800000000}]}
```

with its newest ≤ 200 clips of the current group that are ≤ 7 days old and its tombstones ≤ 30 days
old. The receiver applies `dels` (6.3) and requests the clips it neither has nor has tombstoned with
`{"t":"want","ids":["…"]}`, which is answered with `clip` messages (`live: false`). Images larger
than 16 MiB are skipped during catch-up (the requester MUST NOT re-request them in the same session).

### 6.3 Deletion

```json
{"t":"del","items":[{"id":"…","ts":1792800000000}]}
```

`ts` is the deletion time. The receiver deletes the clips, records tombstones (kept 30 days) and
forwards the message to its other sessions if at least one id was new to it. Clearing history means
deleting every clip. Pins are local and not synced.

### 6.4 Members

`{"t":"members","members":[<changed member records>]}` is sent whenever records change (pairing,
rename, removal). Receivers merge (1.1) and forward when something changed. Removing a device sets
`removed: true` and `updatedAt = now`; members then send `{"t":"bye","reason":"removed"}` on any open
session with it and close. Removal is cooperative; for a full key rotation the user can "Reset group"
on the remaining devices and pair them again.

### 6.5 Other

* `{"t":"ping"}` / `{"t":"pong"}` — keep-alive (section 3).
* `{"t":"bye","reason":"removed|duplicate|leaving|shutdown"}` — sent before an orderly close.
* `{"t":"error","code":"…","msg":"…"}` — plaintext before the handshake, encrypted after it. Codes:
  `group_mismatch`, `no_ticket`, `busy`, `bad_request`, `version`.

### 6.6 Images on their way

A large image takes a moment to encode on the device that copied it and to arrive. So that the other devices can show
it coming ("Receiving an image from iPhone…" with a progress bar) instead of nothing, the sender MAY announce it:

```json
{"t":"incoming","id":"<uuid>","kind":"image"}
{"t":"incoming","id":"<uuid>","cancel":true}
```

* Right after a live image is copied, before reading or encoding it, the sender sends `incoming` on its member
  sessions and then sends the clip (6.1) with the **same** `id`. If the image is not sent after all (unreadable, too
  large, replaced by a newer copy, syncing paused, images turned off) it sends the `cancel` form. Announcements are
  not forwarded; a sender forgets ids it has not used after 5 minutes.
* Receivers take the progress from the `clip` message (`size`) and the chunks that follow it. Only `live` image clips
  report progress, catch-up does not. Implementations that do not know `incoming` ignore it and just receive the clip.

One transfer per clip id, on the receiving device:

| State | When |
|---|---|
| `preparing` | `incoming` arrived; the size is not known yet |
| `receiving` | the `clip` message arrived (`total` = `size`), then after every chunk (`received`) |
| (done) | the clip is accepted (6.1): the transfer ends with the clip itself |
| `failed` | `cancelled` (the announcement was cancelled before the clip message, or the clip was already known), `disconnected` (every session bringing it closed), `corrupt` (bad chunk or checksum), `timeout` (no progress for 60 s) |

A cancel only counts before the clip message; after it the chunks decide. When the same clip comes over several
sessions (forwarding), the transfer fails only when none of them is bringing it any more.

The apps (DESIGN.md) show a transfer only if it is still running 0.3 s after it started, so quick images go straight to
"Copied from …"; when the image is in, the same toast, card or notification turns into "Copied from …" (or "Image from
… · Saved to history" when it was not copied), and failures other than `cancelled` say where to copy it again.

### 6.7 Verification codes

A phone that finds a verification code in a new text message (Android: also KakaoTalk) can send just the code to the
other devices, so that it can be pasted on the computer where it is asked for:

```json
{"t":"clip","live":true,"clip":{"id":"<uuid>","ts":1792800000000,"src":"<phone id>","kind":"text","text":"482915","otp":true}}
```

* A code clip is an ordinary text clip (6.1) with `otp: true`: it is stored, forwarded with the flag, deleted and
  caught up like any other. `otp` is only meaningful on text clips; receivers drop it from other kinds.
* Receivers MUST NOT write a code clip to the clipboard on their own (no auto-apply in 6.1, no mobile "copy latest
  on open"). Instead the apps offer it: "A verification code arrived from Junseo's iPhone. Copy it?" with Copy and
  Not now. A live code is offered when it arrives; a caught-up one only while it is less than 3 minutes old. "Copy"
  writes it to that device's clipboard only.
* Implementations that do not know `otp` treat the clip as an ordinary live text clip (Nearclip 1.0 copies it).
* Only the code travels: the message, its sender and other notification content never leave the phone. The text is
  exactly the code's digits, 4 to 8 of them.

Finding the code (the phones; `spec/otp-vectors.json` holds the cases both implementations agree on): the message
must contain a word that says it carries a code (`인증`, `코드`, `code`, `verification`, `OTP`, `passcode`, …). The
code is the 4–8 digit number (or two groups of 3 joined by a space or a hyphen) nearest to such a word, a number set
off by brackets, a colon or "is" winning ties; numbers that are part of a word, an amount (currency signs, units such
as 원), a phone number, a date or a time, or a longer number are never taken. A message without a keyword has no code.

Sources: Android reads new notifications of the default SMS app, Google Messages, Samsung Messages and KakaoTalk
through notification access; Android 15+ hides codes from listeners it does not trust until the shell allows app op
`RECEIVE_SENSITIVE_NOTIFICATIONS` (with Shizuku from Settings, or `adb shell cmd appops set <package>
RECEIVE_SENSITIVE_NOTIFICATIONS allow`). iOS lets no app read other apps' notifications: a Shortcuts automation on
Message runs the app's "Send Verification Code" action with the message text (text messages only).

## 7. Limits

| Limit | Value |
|---|---|
| Text clip | 4 MiB UTF-8 (larger copies are not synced; the UI says so) |
| Image clip | 32 MiB; send PNG, or JPEG (quality 0.9) when the PNG exceeds the limit |
| Catch-up images | ≤ 16 MiB each |
| Inventory | newest 200 clips ≤ 7 days old |
| Tombstones | kept 30 days |
| Local history | default 1 000 unpinned clips / 30 days (user setting) |

## 8. Security notes

* Clip content, member records and pairing results only travel inside AES-GCM frames whose keys come
  from ephemeral ECDH (forward secrecy) bound to the group key (members) or to the pairing secret.
* Visible on the network: hello frames (ephemeral public keys, nonces, device ids, group tag; device
  name and platform in code pairing) and DNS-SD records (name, platform, id, group tag).
* QR tickets expire after 10 minutes and are single use.
* Items that password managers mark as concealed/transient MUST NOT be synced: macOS
  `org.nspasteboard.ConcealedType` / `org.nspasteboard.TransientType` / `org.nspasteboard.AutoGeneratedType`;
  Windows `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory` = 0,
  `CanUploadToCloudClipboard` = 0; Android `ClipDescription.EXTRA_IS_SENSITIVE`.

## 9. Interop CLI (test-harness contract)

Every implementation ships a headless peer that `tools/interop/run.py` drives:

```
<cli> --state <dir> --name <name> [--port <n>]     # port 0 = OS-assigned; no DNS-SD
      [--tailnet <dir> [--tailnet-control <url>]]  # remote connection (section 10) with its own state dir
```

The Swift CLI also takes demo flags: `--platform <mac|win|android|ios>` (look like that device),
`--remote-only` (neither dial nor advertise LAN endpoints, like a phone on mobile data) and `--pace <bytes/s>`
(send image chunks at that rate, like a slow network, so the receiving side's progress can be seen).

It prints one JSON object per line on **stdout** (events, flushed immediately) and reads one JSON
object per line on **stdin** (commands). stderr is free-form logging.

| Event | Fields |
|---|---|
| `ready` | `id`, `port`, `group`, `gt` |
| `ticket` | `uri` |
| `pair_sas` | `sas` (joiner side, 6 digits, no space) |
| `pair_prompt` | `peer`, `name`, `sas` (inviter side) |
| `paired` | `group`, `peer` (the other side's id) — emitted by both sides |
| `pair_failed` | `reason`: `declined`, `no_ticket` (QR ticket expired/used/wrong — the inviter closed after the hellos), `busy`, `commit`, `timeout`, `unreachable` (no address answered), `io` (other connection errors) |
| `peer_up` / `peer_down` | `id` (+ `name` and `route`: `lan` or `remote` for `peer_up`) |
| `tailnet` | `state`, `ip`, `peers` (number of Nearclip nodes seen in the tailnet) — whenever one of them changes |
| `clip` | `id`, `src`, `kind`, `live`, `ts` + `text` (text; `otp: true` on a code, 6.7) or `size`, `sha`, `mime` (image) |
| `transfer` | `id`, `from`, `state` (`preparing`, `receiving`, `failed`), `received`, `total` (+ `reason` when failed) — a live image on its way (6.6); it ends with `clip` |
| `announced` | `id` — answer to `announce_image` |
| `deleted` | `id` |
| `members` | `members` (the full current list) |
| `history` | `clips`: `[{id,ts,src,kind,text?,sha?,size?}]`, newest first |
| `left` | `reason` (this device left its group, e.g. `removed`) |
| `error` | `msg` |

| Command | Fields | Effect |
|---|---|---|
| `ticket` | | create a QR ticket, emit `ticket` |
| `pair_qr` | `uri` | join via a QR URI (dial `h` / `p`) |
| `pair_code` | `host`, `port` | join via code pairing: emit `pair_sas`, then `paired` or `pair_failed` |
| `accept` / `decline` | `peer` | answer a `pair_prompt` |
| `connect` | `host`, `port` | dial a member session |
| `send_text` | `text` (+ `otp`: `true` for a verification code, 6.7) | new live text clip from this device |
| `send_image` | `path`, `mime` (+ `id` from `announce_image`) | new live image clip (the file bytes are the blob) |
| `announce_image` | | announce a live image (6.6), emit `announced` |
| `cancel_image` | `id` | cancel an announcement |
| `delete` | `id` | delete a clip everywhere |
| `remove` | `peer` | tombstone a member |
| `rename` | `name` | rename this device (bumps its record, broadcasts `members`) |
| `list` | | emit `history` |
| `members` | | emit `members` |
| `tailnet` | | emit `tailnet` |
| `quit` | | send `bye` (shutdown) on all sessions and exit 0 |

The CLI keeps all state (identity, group, members, known endpoints, history, blobs, tombstones) in
`--state`, so it can be restarted to test catch-up. It never touches a system clipboard.

With `--tailnet`, the CLI starts the embedded node as soon as its listener is up (node state in the given
directory, verbose node logs in `<dir>/tailnet.log`). `--tailnet-control` points it at a test control
server (`tailnet/out/nctestcontrol`, which approves every node) and enables the node's test mode.

## 10. Remote connections (embedded Tailscale)

Optional, **off by default**. When the user turns on *Remote connection*, the app runs an embedded
Tailscale node (`tailnet/`, built on tsnet) and the user signs in to Tailscale with the **same account on
each device**. Tailscale's coordination service distributes WireGuard keys and endpoints; devices then
connect directly (NAT traversal) or, when no direct path exists, through Tailscale's DERP relays. Nearclip
runs no server. Nearclip frames stay end-to-end encrypted exactly as on the LAN (sections 3–6);
WireGuard is an additional outer layer, and DERP relays only ever see WireGuard ciphertext.

### 10.1 The node and the bridge

* Hostname `nearclip-<slug>-<id8>`: `slug` = the device name in lowercase with every run of characters
  outside `a–z 0–9` replaced by `-` (≤ 40 chars, may be empty), `id8` = the first 8 hex digits of the
  deviceId. Reference: `tailnet/bridge/hostname.go`.
* The node's state (its keys and login) lives in an app-private directory that is excluded from backups.
  No logs are uploaded to Tailscale (`TS_NO_LOGS_NO_SUPPORT`).
* The node accepts tailnet TCP connections on port **45821** and on the device's LAN listener port and
  relays each to the engine's **loopback listener** (`127.0.0.1`, any port). Engines treat sessions accepted
  there as remote and never remember their (loopback) remote address.
* Outbound, the engine connects to the bridge proxy `127.0.0.1:<proxyPort>` and sends one ASCII line
  `NCTN1 <token> <tailnet-ip>:<port>\n` (`proxyPort` and `token` come from the node status). The bridge
  answers one byte: `0` = connected (from now on the socket is a plain TCP stream to the peer), `1` = bad
  request (wrong token or not a tailnet address), `2` = unreachable, `3` = node not running; on non-zero it
  closes. The proxy only reaches tailnet addresses.
* Mobile apps stop the node whenever their networking pauses (backgrounded) and start a fresh one when they
  become active: iOS reclaims the sockets of suspended apps (tailscale/tailscale#20060).
* Android apps report the device's interfaces and default route to the node
  (`NCTailnetSetNetwork`), because Go cannot enumerate them inside the Android app sandbox
  (tailscale/tailscale#17311).

### 10.2 Addresses and discovery

* A **tailnet address** is an address in `100.64.0.0/10` or `fd7a:115c:a1e0::/48`. While its node runs, a
  device adds `{"h":<its tailnet IPv4>,"p":45821}` to `welcome.addrs` and its tailnet IPv4 to QR `h` lists.
* **Tailnet discovery:** the node lists the other nodes of the tailnet. A node whose hostname is a Nearclip
  hostname with an `id8` equal to the first 8 hex digits of a member's id is a candidate `<ip>:45821`
  for that member. (Presence flags are not required; dialing an absent node simply fails.)

### 10.3 Dialing through the tailnet

* Tailnet candidates (remembered tailnet endpoints and discovered nodes) start 400 ms after the LAN
  candidates of the same attempt (4.5).
* Each tailnet candidate is dialed through the bridge proxy when the node is running, and additionally
  directly when the device itself has a tailnet address on an OS interface (the Tailscale app is
  installed and connected to the same tailnet).
* A session is **remote** when it runs over the tailnet (proxied, dialed at a tailnet address, accepted on
  the loopback listener or accepted from a tailnet address) and **lan** otherwise. Apps show the route of
  every connected device.

### 10.4 Network changes

In addition to 4.5, a network change tells the node (`NCTailnetNetworkChanged`; on Android
`NCTailnetSetNetwork` with the current interfaces) so it re-binds its sockets and finds new paths at once.



## 11. Policy and privacy extensions (2026-10-28)

`welcome.features` advertises `policy1` and `rekey1`. An absent array means neither extension is supported; the v1 handshake and existing cryptographic vectors remain unchanged.

`clip.recipients`, when present, is an allowlist of destination device UUIDs chosen by the origin. A peer must not store, apply or forward the clip if it is not a recipient. A sender must not send such a clip to a peer without `policy1`, including during inventory/want catch-up. A relay preserves this field. Local per-peer preferences additionally gate outgoing content and incoming content by its original `src`. Policy changes cannot recall data already stored on another device.

All implementations expire `otp` text clips at `ts + 180000`, even when pinned, and refuse codes with `ts > now + 60000`. Pruning broadcasts ordinary deletion tombstones. Receipt, forwarding, inventory and copy actions also enforce expiry rather than depending on a timely timer tick. Clients predating these checks cannot provide this guarantee.

Device removal rotates the group key. A `rekey` message contains `previous` (the old group tag), `groupId`, `key` (base64url of the new 32-byte key) and the updated `members`. It travels only inside an already registered member session. A receiver checks the old tag and group, verifies it remains a member, persists the key, forwards the message to eligible registered sessions excluding removed peers, installs the new derived tag/auth key, then closes old sessions. Fresh handshakes use the new key. Old keys are not kept for recovery. Offline peers and peers without `rekey1` require re-pairing; simultaneous independent rotations may also require re-pairing. Group members remain trusted administrators; this does not make previously shared information retractable.

The local disk envelope is unrelated to the wire protocol: `NCV1 || nonce[12] || ciphertext || tag[16]`, AES-256-GCM with the file's basename as associated data. Each installation uses its own local-history key, separate from the rotatable sync key.
