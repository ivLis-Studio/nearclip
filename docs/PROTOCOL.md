# Nearclip Protocol v1 (LAN only)

Nearclip keeps the clipboard and clipboard history in sync between a user's own devices
(macOS, Windows, Android, iOS) **on the local network only**. There is no server of any kind:
devices discover each other with DNS-SD (Bonjour/mDNS) and talk directly over TCP.
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
`welcome.addrs` (remembered per member) and addresses the user types in.

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
   `welcome` (4.2) — or `bye` (4.3). A device without the group key derives different keys and fails here.
5. A side MUST close the connection if the peer's hello `id` equals its own deviceId.

### 4.2 welcome

```json
{"t":"welcome","device":{<own member record>},"members":[<all member records it knows>],
 "addrs":[{"h":"192.168.0.12","p":45821}]}
```

`addrs` lists the sender's reachable listener endpoints (IPv4, no loopback, no link-local). The
receiver merges `members` (1.1), remembers `addrs` as the peer's endpoints, then sends its inventory (6.2).

### 4.3 Removed devices

If C's record is a tombstone at S, S completes the handshake, sends `{"t":"bye","reason":"removed"}`
as its first encrypted message instead of `welcome`, and closes. C, on receiving an **encrypted**
`bye` with reason `removed`, leaves the group (1.1). Only a group member can produce that frame.

### 4.4 One session per peer

If a session with peer P completes while another session with P is open, keep the session whose
**client has the lexicographically smaller deviceId** and close the other after sending
`{"t":"bye","reason":"duplicate"}`. Both sides apply the same rule and therefore agree.

### 4.5 Dialing policy (SHOULD)

* On discovering a member that is not connected: dial at once if `ownId < peerId`, otherwise dial
  if it is still not connected 3 s later.
* Every 20 s, dial disconnected members at their remembered endpoints (exponential back-off per
  member up to 5 min; reset when discovery sees the member again).
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
```

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
| `peer_up` / `peer_down` | `id` (+ `name` for `peer_up`) |
| `clip` | `id`, `src`, `kind`, `live`, `ts` + `text` (text) or `size`, `sha`, `mime` (image) |
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
| `send_text` | `text` | new live text clip from this device |
| `send_image` | `path`, `mime` | new live image clip (the file bytes are the blob) |
| `delete` | `id` | delete a clip everywhere |
| `remove` | `peer` | tombstone a member |
| `rename` | `name` | rename this device (bumps its record, broadcasts `members`) |
| `list` | | emit `history` |
| `members` | | emit `members` |
| `quit` | | send `bye` (shutdown) on all sessions and exit 0 |

The CLI keeps all state (identity, group, members, known endpoints, history, blobs, tombstones) in
`--state`, so it can be restarted to test catch-up. It never touches a system clipboard.

