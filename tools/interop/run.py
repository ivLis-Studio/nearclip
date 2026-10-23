#!/usr/bin/env python3
"""Cross-implementation interop tests for Nearclip (PROTOCOL.md section 9).

Drives headless peers (Swift, Kotlin, C#) over localhost and checks that every
implementation pairs, syncs, catches up, deletes and removes with every other.

  python3 tools/interop/run.py                      # auto-detects built CLIs
  python3 tools/interop/run.py --impl swift=/path/to/cli --impl kotlin="/path/to/cli"
  python3 tools/interop/run.py --only swift,kotlin  # restrict to some implementations
"""
import argparse, hashlib, itertools, json, os, queue, random, shlex, shutil, subprocess, sys, tempfile, threading, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

def detect():
    found = {}
    for path in ["apple/NearclipKit/.build/release/nearclip-cli", "apple/NearclipKit/.build/debug/nearclip-cli"]:
        p = os.path.join(ROOT, path)
        if os.path.exists(p):
            found["swift"] = shlex.quote(p); break
    for path in ["android/cli/build/install/cli/bin/cli", "android/cli/build/install/nearclip-cli/bin/nearclip-cli"]:
        p = os.path.join(ROOT, path)
        if os.path.exists(p):
            found["kotlin"] = shlex.quote(p); break
    for path in ["windows/artifacts/cli/Nearclip.Cli", "windows/src/Nearclip.Cli/bin/Release/net10.0/Nearclip.Cli",
                 "windows/src/Nearclip.Cli/bin/Debug/net10.0/Nearclip.Cli"]:
        p = os.path.join(ROOT, path)
        if os.path.exists(p):
            found["dotnet"] = shlex.quote(p); break
    return found

class Peer:
    def __init__(self, impl, cmd, name, state=None):
        self.impl, self.cmd, self.name = impl, cmd, name
        self.state = state or tempfile.mkdtemp(prefix=f"nearclip-{impl}-")
        self.events = []
        self.cond = threading.Condition()
        self.cursor = 0
        self.log = []
        self.start()

    def start(self):
        args = f"{self.cmd} --state {shlex.quote(self.state)} --name {shlex.quote(self.name)} --port 0"
        self.proc = subprocess.Popen(args, shell=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        threading.Thread(target=self._read, args=(self.proc.stdout, False), daemon=True).start()
        threading.Thread(target=self._read, args=(self.proc.stderr, True), daemon=True).start()
        ready = self.expect("ready", lambda e: e.get("ev") == "ready", timeout=60)
        self.id, self.port = ready["id"], ready["port"]

    def _read(self, stream, is_err):
        for line in stream:
            line = line.rstrip("\n")
            if is_err:
                self.log.append(line)
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                self.log.append("(non-json stdout) " + line)
                continue
            with self.cond:
                self.events.append(ev)
                self.cond.notify_all()

    def send(self, **cmd):
        self.proc.stdin.write(json.dumps(cmd, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def expect(self, what, pred, timeout=20):
        deadline = time.time() + timeout
        with self.cond:
            while True:
                for i in range(self.cursor, len(self.events)):
                    if pred(self.events[i]):
                        return self.events[i]
                left = deadline - time.time()
                if left <= 0 or self.proc.poll() is not None:
                    tail = "\n      ".join(self.log[-15:])
                    raise AssertionError(f"{self.name}: no '{what}' within {timeout}s (exit={self.proc.poll()})\n      stderr tail:\n      {tail}")
                self.cond.wait(min(left, 0.2))

    def mark(self):
        with self.cond:
            self.cursor = len(self.events)

    def quit(self):
        if self.proc.poll() is None:
            try:
                self.send(cmd="quit")
                self.proc.wait(timeout=10)
            except Exception:
                self.proc.kill()

    def restart(self):
        self.quit()
        self.events, self.cursor = [], 0
        self.start()

def local_uri(uri):
    parts = urlsplit(uri)
    q = [(k, "127.0.0.1" if k == "h" else v) for k, v in parse_qsl(parts.query, keep_blank_values=True)]
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(q), ""))

def is_clip(cid=None, text=None, live=None):
    def p(e):
        if e.get("ev") != "clip": return False
        if cid is not None and e.get("id") != cid: return False
        if text is not None and e.get("text") != text: return False
        if live is not None and e.get("live") != live: return False
        return True
    return p

def history_ids(peer):
    peer.mark()
    peer.send(cmd="list")
    return peer.expect("history", lambda e: e.get("ev") == "history")["clips"]

def pair_qr(inviter, joiner):
    inviter.mark(); joiner.mark()
    inviter.send(cmd="ticket")
    uri = inviter.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"]
    joiner.send(cmd="pair_qr", uri=local_uri(uri))
    joiner.expect("paired (joiner)", lambda e: e.get("ev") == "paired" and e.get("peer") == inviter.id)
    inviter.expect("paired (inviter)", lambda e: e.get("ev") == "paired" and e.get("peer") == joiner.id)
    joiner.expect("peer_up", lambda e: e.get("ev") == "peer_up" and e.get("id") == inviter.id)
    inviter.expect("peer_up", lambda e: e.get("ev") == "peer_up" and e.get("id") == joiner.id)

def pair_code(inviter, joiner, accept=True):
    inviter.mark(); joiner.mark()
    joiner.send(cmd="pair_code", host="127.0.0.1", port=inviter.port)
    prompt = inviter.expect("pair_prompt", lambda e: e.get("ev") == "pair_prompt")
    sas = joiner.expect("pair_sas", lambda e: e.get("ev") == "pair_sas")["sas"]
    assert prompt["sas"] == sas, f"codes differ: inviter {prompt['sas']} joiner {sas}"
    assert prompt.get("peer") == joiner.id, "prompt peer id mismatch"
    if not accept:
        inviter.send(cmd="decline", peer=joiner.id)
        r = joiner.expect("pair_failed", lambda e: e.get("ev") == "pair_failed")
        assert r.get("reason") == "declined", f"reason {r.get('reason')}"
        return
    inviter.send(cmd="accept", peer=joiner.id)
    joiner.expect("paired (joiner)", lambda e: e.get("ev") == "paired" and e.get("peer") == inviter.id)
    joiner.expect("peer_up", lambda e: e.get("ev") == "peer_up" and e.get("id") == inviter.id)

def scenario_pair(x_impl, x_cmd, y_impl, y_cmd, tmp):
    """X invites Y by QR; live text both ways; multi-chunk image; delete; restart catch-up; removal."""
    x = Peer(x_impl, x_cmd, f"{x_impl}-inviter"); y = Peer(y_impl, y_cmd, f"{y_impl}-joiner")
    try:
        pair_qr(x, y)
        for a, b in ((x, y), (y, x)):
            b.mark()
            text = f"hello {a.impl}->{b.impl} 안녕 ✓ {random.randint(0, 1 << 30)}"
            a.send(cmd="send_text", text=text)
            ev = b.expect("live text", is_clip(text=text))
            assert ev.get("live") is True and ev.get("src") == a.id and ev.get("kind") == "text", ev
        img = os.urandom(2_621_440 + 123)
        path = os.path.join(tmp, f"img-{x_impl}-{y_impl}.png"); open(path, "wb").write(img)
        sha = hashlib.sha256(img).hexdigest()
        y.mark()
        x.send(cmd="send_image", path=path, mime="image/png")
        ev = y.expect("image", lambda e: e.get("ev") == "clip" and e.get("kind") == "image" and e.get("sha") == sha, timeout=30)
        assert ev.get("size") == len(img) and ev.get("live") is True, ev
        image_id = ev["id"]
        # delete propagates
        y.mark()
        x.send(cmd="delete", id=image_id)
        y.expect("deleted", lambda e: e.get("ev") == "deleted" and e.get("id") == image_id)
        assert all(c["id"] != image_id for c in history_ids(y)), "deleted clip still in history"
        # catch-up after restart
        y.quit()
        away = f"while away {random.randint(0, 1 << 30)}"
        x.mark()
        x.send(cmd="send_text", text=away)
        y.restart()
        y.expect("catch-up", is_clip(text=away, live=False), timeout=60)
        # removal
        x.expect("peer back", lambda e: e.get("ev") == "peer_up" and e.get("id") == y.id, timeout=60)
        y.mark()
        x.send(cmd="remove", peer=y.id)
        y.expect("left", lambda e: e.get("ev") == "left" and e.get("reason") == "removed", timeout=30)
    finally:
        x.quit(); y.quit()

def scenario_code(x_impl, x_cmd, y_impl, y_cmd, tmp):
    """X invites Y by numeric comparison: decline once, then accept; catch-up of earlier clip; rename gossip."""
    x = Peer(x_impl, x_cmd, f"{x_impl}-codehost"); y = Peer(y_impl, y_cmd, f"{y_impl}-codejoin")
    try:
        early = f"before pairing {random.randint(0, 1 << 30)}"
        x.send(cmd="send_text", text=early)
        pair_code(x, y, accept=False)
        pair_code(x, y, accept=True)
        y.expect("catch-up of earlier clip", is_clip(text=early, live=False), timeout=30)
        x.mark()
        y.send(cmd="rename", name=f"{y_impl} renamed")
        x.expect("rename gossip", lambda e: e.get("ev") == "members" and any(m.get("id") == y.id and m.get("name") == f"{y_impl} renamed" for m in e.get("members", [])))
    finally:
        x.quit(); y.quit()

def scenario_readd(impls, tmp):
    """A removes C; B is offline while C is re-added via A; A goes away; C must stay in the group when it meets B
    (B still holds C's old tombstone). Found by the Android worker; PROTOCOL §4.3 merges welcomes first."""
    (ia, ca), (ib, cb), (ic, cc) = impls
    a = Peer(ia, ca, f"{ia}-A"); b = Peer(ib, cb, f"{ib}-B"); c = Peer(ic, cc, f"{ic}-C")
    try:
        pair_qr(a, b)
        pair_qr(a, c)
        a.mark(); b.mark(); c.mark()
        a.send(cmd="remove", peer=c.id)
        c.expect("left after removal", lambda e: e.get("ev") == "left")
        b.expect("B stores C's tombstone", lambda e: e.get("ev") == "members" and any(m.get("id") == c.id and m.get("removed") for m in e.get("members", [])))
        b.quit()
        pair_qr(a, c)
        a.quit()
        b.restart()
        c.mark(); b.mark()
        c.send(cmd="connect", host="127.0.0.1", port=b.port)
        b.expect("B meets the re-added C", lambda e: e.get("ev") == "peer_up" and e.get("id") == c.id, timeout=20)
        try:
            ev = c.expect("no second removal", lambda e: e.get("ev") == "left", timeout=3)
            raise AssertionError("re-added device was removed again: " + json.dumps(ev))
        except AssertionError as err:
            if "re-added" in str(err):
                raise
        text = f"after re-add {random.randint(0, 1 << 30)}"
        c.send(cmd="send_text", text=text)
        b.expect("clip from the re-added device", is_clip(text=text), timeout=15)
    finally:
        a.quit(); b.quit(); c.quit()

def scenario_mesh(impls, tmp):
    """A (impl0) <-QR- B (impl1) <-code- C (impl2). A and C have no direct link: clips must be forwarded by B."""
    (ia, ca), (ib, cb), (ic, cc) = impls
    a = Peer(ia, ca, f"{ia}-A"); b = Peer(ib, cb, f"{ib}-B"); c = Peer(ic, cc, f"{ic}-C")
    try:
        pair_qr(a, b)
        pair_code(b, c)
        a.expect("A learns C via gossip", lambda e: e.get("ev") == "members" and any(m.get("id") == c.id for m in e.get("members", [])), timeout=30)
        for src, dst in ((a, c), (c, a)):
            dst.mark()
            text = f"mesh {src.impl}->{dst.impl} {random.randint(0, 1 << 30)}"
            src.send(cmd="send_text", text=text)
            ev = dst.expect("forwarded clip", is_clip(text=text), timeout=30)
            assert ev.get("src") == src.id, ev
        # deletion from C reaches A through B
        cid = history_ids(a)[0]["id"]
        a.mark()
        c.send(cmd="delete", id=cid)
        a.expect("forwarded delete", lambda e: e.get("ev") == "deleted" and e.get("id") == cid, timeout=30)
    finally:
        a.quit(); b.quit(); c.quit()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--impl", action="append", default=[], help="name=command")
    ap.add_argument("--only", default="")
    ap.add_argument("--keep", action="store_true", help="keep temp state dirs")
    args = ap.parse_args()
    impls = detect()
    for spec in args.impl:
        k, _, v = spec.partition("=")
        impls[k] = v
    if args.only:
        impls = {k: v for k, v in impls.items() if k in args.only.split(",")}
    if not impls:
        print("no CLIs found; build them first (see tools/interop/README.md)"); return 2
    print("implementations:", ", ".join(f"{k}={v}" for k, v in impls.items()))
    tmp = tempfile.mkdtemp(prefix="nearclip-interop-")
    results = []
    names = list(impls.items())
    cases = []
    for (xi, xc), (yi, yc) in itertools.product(names, names):
        cases.append((f"pair-qr+sync  {xi:>6} invites {yi:<6}", scenario_pair, (xi, xc, yi, yc, tmp)))
        cases.append((f"pair-code     {xi:>6} invites {yi:<6}", scenario_code, (xi, xc, yi, yc, tmp)))
    if len(names) >= 3:
        for perm in itertools.permutations(names, 3):
            cases.append(("mesh forward  " + " -> ".join(p[0] for p in perm), scenario_mesh, (list(perm), tmp)))
            cases.append(("re-add        " + " / ".join(p[0] for p in perm), scenario_readd, (list(perm), tmp)))
    elif len(names) == 2:
        cases.append(("mesh forward  " + " -> ".join([names[0][0], names[1][0], names[0][0]]), scenario_mesh, ([names[0], names[1], names[0]], tmp)))
        cases.append(("re-add        " + " / ".join([names[0][0], names[1][0], names[0][0]]), scenario_readd, ([names[0], names[1], names[0]], tmp)))
    else:
        cases.append(("mesh forward  " + names[0][0] + " x3", scenario_mesh, ([names[0]] * 3, tmp)))
        cases.append(("re-add        " + names[0][0] + " x3", scenario_readd, ([names[0]] * 3, tmp)))
    failed = 0
    for title, fn, fargs in cases:
        t0 = time.time()
        try:
            fn(*fargs)
            print(f"PASS  {title}  ({time.time() - t0:.1f}s)", flush=True)
        except Exception as e:
            failed += 1
            print(f"FAIL  {title}  ({time.time() - t0:.1f}s)\n      {e}", flush=True)
    print(f"\n{len(cases) - failed}/{len(cases)} passed")
    if not args.keep:
        shutil.rmtree(tmp, ignore_errors=True)
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())

