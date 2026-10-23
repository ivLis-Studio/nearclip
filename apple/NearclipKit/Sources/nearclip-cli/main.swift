// Headless Nearclip peer for cross-implementation tests (PROTOCOL.md §9).
import Foundation
import NearclipKit

setvbuf(stdout, nil, _IOLBF, 0)

func errlog(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func usage() -> Never {
    errlog("usage: nearclip-cli --state <dir> --name <name> [--port <n>]")
    exit(2)
}

var stateDir: String?
var name = "Nearclip CLI"
var port: UInt16 = 0
var platform = "cli"
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--state": stateDir = args.next()
    case "--name": name = args.next() ?? name
    case "--port": port = UInt16(args.next() ?? "") ?? 0
    case "--platform": platform = args.next() ?? platform  // demos only: impersonate mac/win/android/ios
    default: usage()
    }
}
guard let stateDir else { usage() }

let out = DispatchQueue(label: "nearclip.cli.out")

func emit(_ obj: [String: Any]) {
    guard var line = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

@Sendable func clipJSON(_ c: Clip, live: Bool?) -> [String: Any] {
    var o: [String: Any] = ["id": c.id, "src": c.src, "kind": c.kind, "ts": c.ts]
    if let live { o["live"] = live }
    if let t = c.text { o["text"] = t }
    if let s = c.size { o["size"] = s }
    if let s = c.sha { o["sha"] = s }
    if let m = c.mime { o["mime"] = m }
    return o
}

@Sendable func memberJSON(_ m: MemberRecord) -> [String: Any] {
    var o: [String: Any] = ["id": m.id, "name": m.name, "platform": m.platform, "addedAt": m.addedAt,
                            "updatedAt": m.updatedAt, "removed": m.removed]
    if let v = m.model { o["model"] = v }
    if let v = m.app { o["app"] = v }
    return o
}

let stateURL = URL(fileURLWithPath: stateDir)
let node: NearclipNode
do {
    node = try NearclipNode(config: .init(stateDirectory: stateURL, deviceName: name, platform: platform, appVersion: "1.0.0",
                                          port: port, bonjour: false,
                                          secretStore: FileSecretStore(directory: stateURL.appendingPathComponent("secrets"))))
} catch {
    errlog("init failed: \(error)")
    exit(1)
}
if node.snapshot().deviceName != name { node.rename(name) }

node.eventQueue = out
node.onEvent = { ev in
    switch ev {
    case .ready(let p, let g, let gt):
        emit(["ev": "ready", "id": node.deviceId, "port": Int(p), "group": g, "gt": gt])
    case .ticket(let t):
        emit(["ev": "ticket", "uri": t.uri])
    case .pairCode(let code, _):
        emit(["ev": "pair_sas", "sas": code])
    case .pairPrompt(let p):
        emit(["ev": "pair_prompt", "peer": p.peerId, "name": p.name, "sas": p.code])
    case .paired(let g, let peer, _, _):
        emit(["ev": "paired", "group": g, "peer": peer])
    case .pairFailed(let reason):
        emit(["ev": "pair_failed", "reason": reason])
    case .peerUp(let rec):
        emit(["ev": "peer_up", "id": rec.id, "name": rec.name])
    case .peerDown(let id):
        emit(["ev": "peer_down", "id": id])
    case .clipAdded(let sc, let live, _, let local):
        if !local {
            var o = clipJSON(sc.clip, live: live)
            o["ev"] = "clip"
            emit(o)
        }
    case .clipsDeleted(let ids):
        for id in ids { emit(["ev": "deleted", "id": id]) }
    case .membersChanged(let list):
        emit(["ev": "members", "members": list.map(memberJSON)])
    case .left(let reason):
        emit(["ev": "left", "reason": reason])
    case .tooLarge(let kind):
        emit(["ev": "error", "msg": "too large: \(kind)"])
    case .log(let s):
        errlog(s)
    default:
        break
    }
}
node.start()

func quit() -> Never {
    node.stop()
    Thread.sleep(forTimeInterval: 0.3)
    out.sync {}
    exit(0)
}

func handle(_ cmd: String, _ o: [String: Any]) {
    switch cmd {
    case "ticket":
        node.createTicket()
    case "pair_qr":
        guard let uri = o["uri"] as? String, let invite = PairingInvite(uri: uri) else {
            out.async { emit(["ev": "pair_failed", "reason": "bad_uri"]) }
            return
        }
        node.join(invite: invite)
    case "pair_code":
        guard let host = o["host"] as? String, let p = o["port"] as? Int, let p16 = UInt16(exactly: p) else {
            out.async { emit(["ev": "error", "msg": "pair_code needs host and port"]) }
            return
        }
        node.pairWithCode(host: host, port: p16)
    case "accept":
        node.answerPairPrompt(accept: true)
    case "decline":
        node.answerPairPrompt(accept: false)
    case "connect":
        guard let host = o["host"] as? String, let p = o["port"] as? Int, let p16 = UInt16(exactly: p) else { return }
        node.connect(host: host, port: p16)
    case "send_text":
        guard let t = o["text"] as? String else { return }
        node.sendText(t)
    case "send_image":
        guard let path = o["path"] as? String, let data = FileManager.default.contents(atPath: path) else {
            out.async { emit(["ev": "error", "msg": "cannot read image"]) }
            return
        }
        node.sendImage(data, mime: (o["mime"] as? String) ?? "image/png")
    case "delete":
        if let id = o["id"] as? String { node.delete(ids: [id]) }
    case "remove":
        if let peer = o["peer"] as? String { node.removeMember(peer) }
    case "rename":
        if let n = o["name"] as? String { node.rename(n) }
    case "list":
        let snap = node.snapshot()
        let clips = snap.history.filter { $0.groupId == snap.groupId }.map { clipJSON($0.clip, live: nil) }
        out.async { emit(["ev": "history", "clips": clips]) }
    case "members":
        let snap = node.snapshot()
        out.async { emit(["ev": "members", "members": snap.members.map(memberJSON)]) }
    case "quit":
        quit()
    default:
        out.async { emit(["ev": "error", "msg": "unknown command \(cmd)"]) }
    }
}

Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            out.async { emit(["ev": "error", "msg": "bad command"]) }
            continue
        }
        handle(cmd, obj)
    }
    quit()
}

dispatchMain()

