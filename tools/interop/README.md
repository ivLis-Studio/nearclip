# Nearclip interop tests

`run.py` starts the headless peer of each implementation (PROTOCOL.md §9) on localhost and runs, for
every ordered pair of implementations:

* **pair-qr+sync** — QR pairing, live text both ways (Korean + emoji), a 2.6 MB image (3 chunks),
  delete propagation, catch-up after the joiner restarts with the same state, removal → `left`.
* **pair-code** — numeric comparison: one decline, then accept; catch-up of an earlier clip; rename gossip.
* **mesh forward** — A ⇄ B ⇄ C where A and C never connect directly: clips and deletes must be
  forwarded by B (every permutation of three implementations).
* **readd** — A removes C and adds it again while B is offline; when C later meets B, which still holds C's old
  tombstone, C must stay in the group (PROTOCOL §4.3).
* **remote** — X and Y pair on the LAN with remote connection off, then restart with it on and new ports. They must
  find each other through the tailnet (a throwaway control server, `tailnet/out/nctestcontrol`), report the session
  route as `remote` and carry clips both ways. Needs `tailnet/build.sh desktop testcontrol`: the Swift CLI links the
  bridge statically, the Kotlin and C# CLIs load `tailnet/out/desktop/libnctailnet.dylib`.

```sh
python3 tools/interop/run.py                 # auto-detects built CLIs
python3 tools/interop/run.py --only swift,kotlin
python3 tools/interop/run.py --scenarios remote
python3 tools/interop/run.py --impl dotnet="dotnet /path/Nearclip.Cli.dll"
```

## Building the peers

| Implementation | Build | Auto-detected path |
|---|---|---|
| Swift (reference) | `cd apple/NearclipKit && swift build -c release` | `apple/NearclipKit/.build/release/nearclip-cli` (or `debug`) |
| Kotlin | `cd android && ./gradlew :cli:installDist` | `android/cli/build/install/cli/bin/cli` |
| C# | see `windows/README.md` | `windows/artifacts/cli/Nearclip.Cli` or `windows/src/Nearclip.Cli/bin/{Release,Debug}/net10.0/Nearclip.Cli` |

Any other location works with `--impl name=command`.

