import Foundation
import NearclipKit
import Observation
import SwiftUI

enum JoinState: Equatable {
    case idle
    case connecting(String)
    case confirm(code: String, peer: String)
    case success(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .connecting, .confirm: return true
        default: return false
        }
    }
}

struct Notice: Identifiable, Equatable {
    enum Tone { case info, success, warning }
    let id = UUID()
    var text: String
    var symbol: String
    var tone: Tone = .info
}

@MainActor
protocol ClipboardWriter: AnyObject {
    /// Writes a clip to the system clipboard, marked so Nearclip does not pick it up again. False when nothing was
    /// written because the clipboard already holds the same content.
    @discardableResult func write(_ clip: Clip, blob: Data?) -> Bool
}

/// The UI-facing state of the engine. Shared by the macOS and iOS apps.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let node: NearclipNode
    let settings: AppSettings
    @ObservationIgnored weak var clipboard: ClipboardWriter?
    /// A live clip from another device was written to the system clipboard.
    @ObservationIgnored var onReceive: ((StoredClip) -> Void)?
    @ObservationIgnored var onPairPrompt: ((PairPrompt) -> Void)?
    /// Something was sent or received (status-icon pulse).
    @ObservationIgnored var onActivity: (() -> Void)?
    /// The live image shown as "Receiving…" changed (nil: none). See `shownTransfer`.
    @ObservationIgnored var onShownTransfer: ((IncomingTransfer?) -> Void)?
    /// A shown transfer arrived but was not copied to the clipboard (auto-copy off, or an older clip).
    @ObservationIgnored var onReceivedQuietly: ((StoredClip) -> Void)?
    /// A shown transfer ended without the image (the sender cancelling it is not reported).
    @ObservationIgnored var onTransferFailed: ((IncomingTransfer) -> Void)?
    /// A verification code from another device's messages (PROTOCOL.md §6.7), to offer with "Copy it?". Codes are never
    /// copied on their own.
    @ObservationIgnored var onCode: ((StoredClip) -> Void)?
    @ObservationIgnored private var offeredCodes = Set<String>()

    private(set) var deviceId: String
    private(set) var deviceName: String
    private(set) var platform: String
    private(set) var members: [MemberRecord] = []
    private(set) var online: Set<String> = []
    private(set) var lastSeen: [String: Int64] = [:]
    private(set) var history: [StoredClip] = [] { didSet { rebuildItems() } }
    private(set) var items: [ClipItem] = []
    private(set) var nearby: [NearbyDevice] = []
    private(set) var port: UInt16 = 0
    private(set) var addresses: [String] = []
    /// Route of every connected device (same network / remote).
    private(set) var routes: [String: PeerRoute] = [:]
    /// The embedded Tailscale node (remote connection).
    private(set) var tailnet: TailnetStatus = .off
    /// Waiting for the Tailscale sign-in page (button pressed, page opened).
    private(set) var tailnetSigningIn = false
    /// iOS shows this sign-in page in an in-app Safari sheet; cleared once the node runs.
    var tailnetLoginURL: URL?
    /// macOS opens sign-in pages in the default browser.
    @ObservationIgnored var onOpenTailnetLogin: ((URL) -> Void)?
    private(set) var ticket: PairingTicket?
    var pairPrompt: PairPrompt?
    var joinState: JoinState = .idle
    var notice: Notice?
    /// A live image on its way from another device (PROTOCOL.md §6.6): the newest transfer still running 0.3 s after it
    /// started, so quick ones go straight to "Copied from …".
    private(set) var shownTransfer: IncomingTransfer?
    @ObservationIgnored private var transfers: [String: IncomingTransfer] = [:]
    @ObservationIgnored private var transferOrder: [String] = []
    @ObservationIgnored private var visibleTransfers = Set<String>()
    /// Name of a device that just joined through this one (inviter side).
    var justJoined: String?
    @ObservationIgnored private var ticketDemand = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Newest clip time written to (or copied from) this device's clipboard.
    @ObservationIgnored var lastAppliedTs: Int64 = Int64(UserDefaults.standard.double(forKey: "lastAppliedTs")) {
        didSet { UserDefaults.standard.set(Double(lastAppliedTs), forKey: "lastAppliedTs") }
    }
    @ObservationIgnored private var catchUpDeadline: Date?
    @ObservationIgnored private var catchUpCandidate: StoredClip?
    @ObservationIgnored private var catchUpTask: Task<Void, Never>?

    init(node: NearclipNode, settings: AppSettings) {
        self.node = node
        self.settings = settings
        let snap = node.snapshot()
        deviceId = snap.deviceId
        deviceName = snap.deviceName
        platform = snap.platform
        apply(snap)
        node.eventQueue = .main
        node.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func start() {
        node.setRetention(days: settings.retentionDays)
        node.setPaused(settings.paused)
        node.setRemoteEnabled(settings.remoteEnabled)
        node.start()
    }

    func refresh() { apply(node.snapshot()) }

    private func apply(_ snap: NodeSnapshot) {
        deviceName = snap.deviceName
        members = snap.members
        online = snap.online
        lastSeen = snap.lastSeen
        history = snap.history
        nearby = snap.nearby
        port = snap.port
        addresses = snap.addresses
        routes = snap.routes
        tailnet = snap.tailnet
    }

    // MARK: - Derived

    var me: MemberRecord? { members.first { $0.id == deviceId } }
    var otherMembers: [MemberRecord] { members.filter { !$0.removed && $0.id != deviceId } }
    var connectedMembers: [MemberRecord] { otherMembers.filter { online.contains($0.id) } }
    var connectedCount: Int { connectedMembers.count }
    func isOnline(_ id: String) -> Bool { online.contains(id) }
    func route(_ id: String) -> PeerRoute? { online.contains(id) ? routes[id] : nil }

    /// "Connected · Same network" / "Connected · Remote" (DESIGN.md §4.7).
    func connectionText(_ id: String) -> String {
        guard isOnline(id) else { return Format.lastSeen(lastSeen[id]) }
        switch route(id) {
        case .remote: return String(localized: "Connected · Remote")
        case .lan: return String(localized: "Connected · Same network")
        case nil: return String(localized: "Connected")
        }
    }

    /// Remote connection is off and a device is out of reach: suggest turning it on.
    var suggestsRemote: Bool {
        node.isTailnetAvailable && !settings.remoteEnabled && otherMembers.contains { !online.contains($0.id) }
    }

    var thisDeviceLabel: String {
        switch platform {
        case "mac": return String(localized: "This Mac")
        case "ios": return (me?.model ?? "").hasPrefix("iPad") ? String(localized: "This iPad") : String(localized: "This iPhone")
        default: return String(localized: "This device")
        }
    }

    var statusLine: String {
        if settings.paused { return String(localized: "Syncing paused") }
        let n = connectedCount
        if otherMembers.isEmpty { return String(localized: "No other devices yet") }
        if n == 0 { return String(localized: "Waiting for your devices") }
        return n == 1 ? String(localized: "Connected to 1 device") : String(localized: "Connected to \(n) devices")
    }

    func sourceName(_ sc: StoredClip) -> String {
        if sc.clip.src == deviceId { return thisDeviceLabel }
        if let m = members.first(where: { $0.id == sc.clip.src }), !m.name.isEmpty { return m.name }
        return sc.srcName ?? String(localized: "Another device")
    }

    func sourceSymbol(_ sc: StoredClip) -> String {
        if sc.clip.src == deviceId { return DeviceStyle.symbol(platform: platform, model: me?.model) }
        let m = members.first { $0.id == sc.clip.src }
        return DeviceStyle.symbol(platform: m?.platform ?? sc.srcPlatform ?? "", model: m?.model)
    }

    /// Name and symbol of the device an image is coming from.
    func deviceName(_ id: String) -> String {
        if let m = members.first(where: { $0.id == id }), !m.name.isEmpty { return m.name }
        return String(localized: "Another device")
    }

    func deviceSymbol(_ id: String) -> String {
        let m = members.first { $0.id == id }
        return DeviceStyle.symbol(platform: m?.platform ?? "", model: m?.model)
    }

    func items(filter: HistoryFilter, query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            let clip = item.clip.clip
            switch filter {
            case .all: break
            case .text: guard clip.isText, !ClipContent.of(clip).isLink else { return false }
            case .links: guard ClipContent.of(clip).isLink else { return false }
            case .images: guard clip.isImage else { return false }
            case .pinned: guard item.pinned else { return false }
            }
            guard !q.isEmpty else { return true }
            if let t = clip.text, t.lowercased().contains(q) { return true }
            if sourceName(item.clip).lowercased().contains(q) { return true }
            if clip.isImage, String(localized: "Image").lowercased().contains(q) { return true }
            return false
        }
    }

    private func rebuildItems() {
        var index: [String: Int] = [:]
        var out: [ClipItem] = []
        out.reserveCapacity(history.count)
        for sc in history {
            let key = sc.clip.isImage ? "i:" + (sc.clip.sha ?? sc.id) : "t:" + (sc.clip.text ?? "")
            if let i = index[key] {
                out[i].ids.append(sc.id)
                if sc.pinned { out[i].pinned = true }
                continue
            }
            index[key] = out.count
            out.append(ClipItem(clip: sc, ids: [sc.id], pinned: sc.pinned))
        }
        items = out
    }

    // MARK: - Clip actions

    /// Copies an item from history: it becomes the clipboard here and the newest clip everywhere.
    func copy(_ item: ClipItem) {
        let c = item.clip.clip
        let blob = c.isImage ? node.blobData(for: c.id) : nil
        if c.isImage && blob == nil { return }
        clipboard?.write(c, blob: blob)
        lastAppliedTs = max(lastAppliedTs, c.ts)
        guard !settings.paused else { return }
        if c.isText, let t = c.text {
            node.sendText(t)
        } else if let blob, settings.syncImages {
            node.sendImage(blob, mime: c.mime ?? "image/png", width: c.w, height: c.h)
        }
        onActivity?()
    }

    /// Something was copied on this device.
    /// Returns false when it was not sent because it is the newest clip already (see `isNewest`).
    @discardableResult
    func localCopy(text: String) -> Bool {
        guard !settings.paused else { return true }
        guard !isNewest(ContentKey.text(text)) else { return false }
        if let sc = node.sendText(text) {
            lastAppliedTs = max(lastAppliedTs, sc.clip.ts)
            onActivity?()
        }
        return true
    }

    func localCopy(image: Data, mime: String, width: Int?, height: Int?) {
        localCopy(image: image, mime: mime, width: width, height: height, announced: nil)
    }

    /// `announced`: from `announceImage()`, called before the image was encoded.
    /// Returns false when it was not sent because it is the newest clip already (see `isNewest`).
    @discardableResult
    func localCopy(image: Data, mime: String, width: Int?, height: Int?, announced: String?) -> Bool {
        guard !settings.paused, settings.syncImages else {
            if let announced { node.cancelImage(announced) }
            return true
        }
        guard !isNewest(image: image) else {
            if let announced { node.cancelImage(announced) }
            return false
        }
        if let sc = node.sendImage(image, mime: mime, width: width, height: height, id: announced) {
            lastAppliedTs = max(lastAppliedTs, sc.clip.ts)
            onActivity?()
        }
        return true
    }

    /// The same content as the newest clip in history, if that one is recent: it is on the other devices already, so
    /// copying it again here (or another sync app putting it back) is not a new clip (DESIGN.md §4.3).
    func isNewest(_ key: String) -> Bool {
        guard let newest = history.first, nowMs() - newest.receivedAt < 600_000 else { return false }
        return ContentKey.of(newest.clip) == key
    }

    /// `isNewest` for an image file (hashed only when the newest clip is an image of the same size).
    func isNewest(image: Data) -> Bool {
        guard let newest = history.first, newest.clip.isImage, newest.clip.size == image.count else { return false }
        return isNewest(ContentKey.file(image))
    }

    /// An image was just copied here and is about to be encoded: lets the other devices show it arriving right away
    /// (PROTOCOL.md §6.6). Pass the id to `localCopy(image:…announced:)` or `cancelImage`.
    func announceImage() -> String? {
        guard !settings.paused, settings.syncImages, connectedCount > 0 else { return nil }
        return node.announceImage()
    }

    func cancelImage(_ id: String?) {
        if let id { node.cancelImage(id) }
    }

    /// Mobile "copy the newest clip when Nearclip opens": for a short window after the app becomes active, the newest
    /// clip that arrives through catch-up (from another device, at most 10 minutes old) goes to the clipboard.
    func armCopyNewest(window: TimeInterval = 12) {
        guard settings.copyLatestOnOpen else { return }
        catchUpDeadline = Date().addingTimeInterval(window)
        catchUpCandidate = nil
        // A clip that arrived while we were away may already be in history (e.g. received just before backgrounding).
        if let newest = history.first(where: { $0.clip.src != deviceId }) { considerCatchUp(newest) }
    }

    private func considerCatchUp(_ sc: StoredClip) {
        guard let deadline = catchUpDeadline, Date() < deadline, settings.copyLatestOnOpen, !settings.paused, !sc.clip.isCode,
              sc.clip.src != deviceId, sc.clip.ts > lastAppliedTs, nowMs() - sc.clip.ts < 600_000,
              !(sc.clip.isImage && !settings.syncImages) else { return }
        if let c = catchUpCandidate, c.clip.ts >= sc.clip.ts { return }
        catchUpCandidate = sc
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let c = self.catchUpCandidate, c.clip.ts > self.lastAppliedTs else { return }
            let blob = c.clip.isImage ? self.node.blobData(for: c.id) : nil
            if c.clip.isImage && blob == nil { return }
            let written = self.clipboard?.write(c.clip, blob: blob) ?? true
            self.lastAppliedTs = c.clip.ts
            self.node.noteApplied(c.clip)
            if written { self.onReceive?(c) }
        }
    }

    func togglePin(_ item: ClipItem) {
        for id in item.ids { node.setPinned(!item.pinned, id: id) }
    }

    // MARK: - Verification codes (PROTOCOL.md §6.7)

    /// Offers a code from another device: when it arrives, or later (catch-up) while it can still be used.
    func offerCode(_ sc: StoredClip, live: Bool) {
        guard sc.clip.isCode, sc.clip.src != deviceId, !settings.paused else { return }
        guard live || nowMs() - sc.clip.ts < 180_000 else { return }
        guard offeredCodes.insert(sc.id).inserted else { return }
        onCode?(sc)
    }

    /// "Copy" on a code offer: to this device's clipboard only.
    func copyCode(_ sc: StoredClip) {
        clipboard?.write(sc.clip, blob: nil)
        lastAppliedTs = max(lastAppliedTs, sc.clip.ts)
        node.noteApplied(sc.clip)
    }

    func delete(_ item: ClipItem) { node.delete(ids: item.ids) }
    func clearHistory() { node.clearHistory() }

    // MARK: - Devices & settings

    func rename(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != deviceName else { return }
        deviceName = t
        node.rename(t)
    }

    func remove(_ member: MemberRecord) { node.removeMember(member.id) }
    func leaveGroup() { node.leaveGroup() }

    func setPaused(_ paused: Bool) {
        settings.paused = paused
        node.setPaused(paused)
        if paused { online = []; routes = [:] }
    }

    func setRetention(_ days: Int) {
        settings.retentionDays = days
        node.setRetention(days: days)
    }

    // MARK: - Remote connection (embedded Tailscale)

    var remoteAvailable: Bool { node.isTailnetAvailable }

    func setRemoteEnabled(_ on: Bool) {
        settings.remoteEnabled = on
        node.setRemoteEnabled(on)
        if !on {
            tailnet = .off
            tailnetSigningIn = false
            tailnetLoginURL = nil
        }
    }

    /// Opens Tailscale's sign-in page (asks the node for one first when needed).
    func signInToTailscale() {
        if let s = tailnet.authURL, let url = URL(string: s) {
            openTailnetLogin(url)
            return
        }
        tailnetSigningIn = true
        node.tailnetLogin { [weak self] st in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tailnet = st
                if let s = st.authURL, let url = URL(string: s) {
                    self.openTailnetLogin(url)
                } else {
                    self.tailnetSigningIn = false
                }
            }
        }
    }

    private func openTailnetLogin(_ url: URL) {
        tailnetSigningIn = true
        if let open = onOpenTailnetLogin { open(url) } else { tailnetLoginURL = url }
    }

    func signOutOfTailscale() {
        tailnetSigningIn = false
        node.tailnetLogout()
    }

    /// Restarts the node after an error.
    func retryRemote() {
        node.setRemoteEnabled(false)
        node.setRemoteEnabled(true)
    }

    // MARK: - Pairing

    /// Call while an Add-device surface is visible: keeps a fresh QR ticket and advertises pairing mode.
    func beginAddDevice() {
        ticketDemand += 1
        node.setPairingMode(true)
        if ticket == nil || ticket!.expiresAt < Date().addingTimeInterval(30) { requestTicket() }
    }

    func endAddDevice() {
        ticketDemand = max(0, ticketDemand - 1)
        guard ticketDemand == 0 else { return }
        node.setPairingMode(false)
        node.cancelTicket()
        ticket = nil
    }

    private func requestTicket() {
        guard port > 0 else { return }
        ticket = node.createTicket()
    }

    @discardableResult
    func join(link: String) -> Bool {
        guard let invite = PairingInvite(uri: link) else { return false }
        joinState = .connecting(invite.name)
        node.join(invite: invite)
        return true
    }

    func pair(with device: NearbyDevice) {
        joinState = .connecting(device.name)
        node.pairWithCode(nearbyId: device.id)
    }

    func pair(host: String, port: UInt16) {
        joinState = .connecting(host)
        node.pairWithCode(host: host, port: port)
    }

    func connect(host: String, port: UInt16) { node.connect(host: host, port: port) }

    func cancelJoin() {
        node.cancelJoin()
        joinState = .idle
    }

    func answerPrompt(_ accept: Bool) {
        node.answerPairPrompt(accept: accept)
        if !accept { pairPrompt = nil }
    }

    static func failureText(_ reason: String) -> String {
        switch reason {
        case "declined": return String(localized: "The other device declined.")
        case "no_ticket": return String(localized: "That code expired. Show a new one on the other device.")
        case "unreachable", "io":
            return String(localized: "Couldn't reach the device. Make sure both devices are on the same Wi-Fi, or turn on Remote connection on both.")
        case "timeout": return String(localized: "The other device didn't answer in time.")
        case "busy": return String(localized: "The other device is pairing with someone else. Try again in a moment.")
        case "self": return String(localized: "That's this device.")
        case "bad_uri": return String(localized: "That isn't a Nearclip pairing code.")
        default: return String(localized: "Pairing didn't work. Please try again.")
        }
    }

    // MARK: - Notices

    func show(_ text: String, symbol: String, tone: Notice.Tone = .info) {
        notice = Notice(text: text, symbol: symbol, tone: tone)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Engine events

    private func insert(_ sc: StoredClip) {
        guard !history.contains(where: { $0.id == sc.id }) else { return }
        let i = history.firstIndex { $0.clip.ts < sc.clip.ts } ?? history.count
        history.insert(sc, at: i)
    }

    private func handle(_ event: NodeEvent) {
        switch event {
        case .ready(let p, _, _):
            port = p
            addresses = node.snapshot().addresses
            if ticketDemand > 0 { requestTicket() }
        case .ticket(let t):
            ticket = t
        case .ticketExpired:
            ticket = nil
            if ticketDemand > 0 { requestTicket() }
        case .pairCode(let code, let peer):
            if case .connecting(let name) = joinState {
                joinState = .confirm(code: code, peer: peer.isEmpty ? name : peer)
            } else {
                joinState = .confirm(code: code, peer: peer)
            }
        case .pairPrompt(let p):
            pairPrompt = p
            onPairPrompt?(p)
        case .pairPromptDismissed:
            pairPrompt = nil
        case .paired(_, _, let name, let joined):
            if joined {
                joinState = .success(name)
            } else {
                pairPrompt = nil
                justJoined = name
                show(String(localized: "‘\(name)’ is now one of your devices."), symbol: "checkmark.circle.fill", tone: .success)
                if ticketDemand > 0 { requestTicket() }
            }
            refresh()
        case .pairFailed(let reason):
            joinState = .failed(reason)
        case .peerUp(let rec, let route):
            online.insert(rec.id)
            routes[rec.id] = route
            if let i = members.firstIndex(where: { $0.id == rec.id }) { members[i] = rec } else { members.append(rec) }
        case .peerDown(let id):
            online.remove(id)
            routes[id] = nil
            lastSeen[id] = nowMs()
        case .clipAdded(let sc, let live, let apply, let local):
            insert(sc)
            guard !local else { return }
            if sc.clip.isCode {
                onActivity?()
                offerCode(sc, live: live)
                return
            }
            let wasShown = transfers[sc.id] != nil && endTransfer(sc.id)
            onActivity?()
            var copied = false
            if apply, settings.autoApply, !settings.paused, !(sc.clip.isImage && !settings.syncImages) {
                let blob = sc.clip.isImage ? node.blobData(for: sc.id) : nil
                if !sc.clip.isImage || blob != nil {
                    // Already on the clipboard (copied here too, or brought by another sync app): not written again
                    // and no toast, unless its progress was showing.
                    let written = clipboard?.write(sc.clip, blob: blob) ?? true
                    lastAppliedTs = max(lastAppliedTs, sc.clip.ts)
                    if written || wasShown { onReceive?(sc) }
                    copied = true
                }
            } else if !apply {
                considerCatchUp(sc)
            }
            if wasShown && !copied { onReceivedQuietly?(sc) }
            updateShownTransfer()
        case .transfer(let t):
            handleTransfer(t)
        case .clipsDeleted(let ids):
            let set = Set(ids)
            history.removeAll { set.contains($0.id) }
        case .clipUpdated(let sc):
            if let i = history.firstIndex(where: { $0.id == sc.id }) { history[i] = sc }
        case .membersChanged(let list):
            members = list
        case .nearbyChanged(let list):
            nearby = list
        case .left(let reason):
            refresh()
            online = []
            routes = [:]
            if reason == "removed" {
                show(String(localized: "This device was removed from your devices."), symbol: "person.crop.circle.badge.xmark", tone: .warning)
            }
        case .tooLarge:
            show(String(localized: "Too large to sync"), symbol: "exclamationmark.triangle.fill", tone: .warning)
        case .tailnetChanged(let st):
            tailnet = st
            if st.isRunning || st.state == "off" {
                tailnetSigningIn = false
                tailnetLoginURL = nil
            }
        case .log(let s):
            #if DEBUG
            print("[nearclip]", s)
            #endif
            _ = s
        }
    }

    // MARK: - Live images on their way (PROTOCOL.md §6.6)

    private func handleTransfer(_ t: IncomingTransfer) {
        guard settings.syncImages else { return }
        if t.state == .failed {
            let wasShown = endTransfer(t.id)
            if wasShown && t.reason != "cancelled" { onTransferFailed?(t) }
            updateShownTransfer()
            return
        }
        let isNew = transfers[t.id] == nil
        transfers[t.id] = t
        guard isNew else { updateShownTransfer(); return }
        transferOrder.append(t.id)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.transfers[t.id] != nil else { return }
            self.visibleTransfers.insert(t.id)
            self.updateShownTransfer()
        }
    }

    /// Forgets a transfer; returns whether it was the one shown.
    @discardableResult
    private func endTransfer(_ id: String) -> Bool {
        let wasShown = shownTransfer?.id == id
        transfers[id] = nil
        transferOrder.removeAll { $0 == id }
        visibleTransfers.remove(id)
        return wasShown
    }

    private func updateShownTransfer() {
        let next = transferOrder.last(where: { visibleTransfers.contains($0) }).flatMap { transfers[$0] }
        guard next != shownTransfer else { return }
        shownTransfer = next
        onShownTransfer?(next)
    }
}

