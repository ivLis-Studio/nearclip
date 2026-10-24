# Nearclip tailnet bridge (embedded Tailscale)

Remote connection (docs/PROTOCOL.md §10) embeds a Tailscale node in every Nearclip app so a
user's devices reach each other across networks — no Tailscale app needed, no Nearclip server.
This directory is the Go side: `bridge/` (the node + loopback bridge), `capi/` (C ABI + JNI),
`cmd/nctestcontrol` (throwaway control server for tests) and `build.sh`.

Built on `tailscale.com/tsnet` v1.104.2 (BSD-3-Clause), default feature set.

## Build

```
tailnet/build.sh apple android windows desktop testcontrol   # or: all
```

| Target | Output (gitignored) |
|---|---|
| apple | `apple/NearclipKit/Binaries/NCTailnet.xcframework` — static, macOS arm64+x86_64, iOS arm64, iOS Simulator arm64+x86_64; Swift module `NCTailnet` |
| android | `android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libnctailnet.so` — JNI, 16 KB pages |
| windows | `windows/native/win-{x64,arm64}/nctailnet.dll` — C ABI (UCRT only) |
| desktop | `tailnet/out/desktop/libnctailnet.dylib` — this Mac, C ABI **and** JNI (Kotlin/C# test CLIs) |
| testcontrol | `tailnet/out/nctestcontrol` |

Needs Go (go.mod), Xcode, the Android NDK and llvm-mingw (`LLVM_MINGW`, default
`~/Library/Caches/nearclip-toolchains/llvm-mingw-20261020-ucrt-macos-universal`).
`go test ./...` runs the bridge end-to-end against an in-process control server.

## C interface (`include/nctailnet.h`)

One node per process. Every `char*` result is a JSON **status** (below) that the caller frees with
`NCTailnetFree`. Calls block (up to ~15 s for `Login`), so call them off the UI thread.

| Function | |
|---|---|
| `NCTailnetStart(config)` | start (or keep) the node; returns at once, poll status for login |
| `NCTailnetStatus()` | current status |
| `NCTailnetLogin()` | make sure a login URL exists (waits for it) |
| `NCTailnetLogout()` | sign this node out (it needs a new login afterwards) |
| `NCTailnetStop()` | stop the node; its login stays in `dir` |
| `NCTailnetSetNetwork(netInfo)` | Android: report interfaces + default route (see below), implies NetworkChanged |
| `NCTailnetNetworkChanged()` | the device's network changed |
| `NCTailnetFree(p)` | free a result |

JNI (Android, desktop JVM): `object studio.ivlis.nearclip.core.tailnet.TailnetNative` with
`@JvmStatic external fun nativeStart(config: String): String`, `nativeStatus()`, `nativeLogin()`,
`nativeLogout()`, `nativeStop()` (all `String`), `nativeSetNetwork(info: String): String`,
`nativeNetworkChanged()` (Unit). Library name `nctailnet`.

### Config

```json
{"dir":"/…/tailnet","deviceId":"3f2b8c1e-…","deviceName":"MacBook Pro","ports":[45821],
 "forward":"127.0.0.1:50123",
 "controlURL":"http://127.0.0.1:61234","testMode":true,"ephemeral":true,"logPath":"/…/tailnet.log"}
```

`dir`, `deviceId`, `deviceName`, `forward` (the engine's loopback listener) are required; `ports` adds
tailnet ports besides 45821 (pass the LAN listener port). The last four fields are for tests/debugging
(`logPath` "-" = stderr). Calling Start again with the same config is a no-op; a different config restarts.

### Status

```json
{"state":"running","backend":"Running","ip":"100.64.0.7","ip6":"fd7a:…","hostname":"nearclip-macbook-pro-3f2b8c1e",
 "dnsName":"nearclip-macbook-pro-3f2b8c1e.tail1234.ts.net","account":"me@gmail.com","tailnet":"me@gmail.com",
 "proxyPort":50124,"token":"9c0e…","ports":[45821],
 "peers":[{"host":"nearclip-galaxy-s25-bbbb2222","idPrefix":"bbbb2222","ip":"100.64.0.8","online":true,"os":"android","direct":true}],
 "health":[],"error":"","version":"1.104.2"}
```

`state`: `off` · `starting` · `needsLogin` (open `authURL` in a browser) · `needsApproval` (an admin must
approve the device) · `running` · `stopped` · `error` (`error` says why). `peers` lists only Nearclip nodes.
JSON is pure ASCII.

### Proxy (outbound)

Connect to `127.0.0.1:<proxyPort>`, send `NCTN1 <token> <tailnet-ip>:<port>\n`, read one byte:
`0` connected (raw stream follows), `1` bad request, `2` unreachable, `3` not running.

### NetInfo (Android)

```json
{"interfaces":[{"name":"wlan0","index":30,"mtu":1500,"up":true,"multicast":true,"addrs":["192.168.0.23/24","fe80::1/64"]}],
 "defaultInterface":"wlan0","gateway":"192.168.0.1"}
```

## Fixes for known embedding problems

| Issue | What goes wrong | Here |
|---|---|---|
| [tailscale#17311](https://github.com/tailscale/tailscale/issues/17311) | Android apps: `netlinkrib: permission denied`, the node never starts (Tailscale's fallback is compiled out of cgo Android builds) | `bridge/network_android.go` registers an interface getter fed by the app (`NCTailnetSetNetwork`), with a synthetic-interface fallback |
| [tailscale#20060](https://github.com/tailscale/tailscale/issues/20060) | iOS: after suspension the loopback LocalAPI socket is dead and status calls fail forever | status uses tsnet's in-memory LocalAPI; apps stop the node when networking pauses and start a fresh one when active |
| [tailscale#20992](https://github.com/tailscale/tailscale/issues/20992) | TailscaleKit has no privacy manifest (ITMS-91053) and no macOS build | no TailscaleKit: own static xcframework incl. macOS; the apps ship `PrivacyInfo.xcprivacy` |
