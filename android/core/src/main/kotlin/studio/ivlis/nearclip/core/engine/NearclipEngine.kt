package studio.ivlis.nearclip.core.engine

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import studio.ivlis.nearclip.core.crypto.B64u
import studio.ivlis.nearclip.core.crypto.Crypto
import studio.ivlis.nearclip.core.crypto.Hex
import studio.ivlis.nearclip.core.crypto.P256
import studio.ivlis.nearclip.core.crypto.concat
import studio.ivlis.nearclip.core.crypto.utf8
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.ClipKind
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.model.Group
import studio.ivlis.nearclip.core.model.MemberRecord
import studio.ivlis.nearclip.core.model.Tombstone
import studio.ivlis.nearclip.core.model.newId
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.core.proto.HelloFrame
import studio.ivlis.nearclip.core.proto.Hello
import studio.ivlis.nearclip.core.proto.Plain
import studio.ivlis.nearclip.core.proto.ProtocolException
import studio.ivlis.nearclip.core.proto.SecureChannel
import studio.ivlis.nearclip.core.proto.Wire
import studio.ivlis.nearclip.core.proto.arr
import studio.ivlis.nearclip.core.proto.bool
import studio.ivlis.nearclip.core.proto.normalizeId
import studio.ivlis.nearclip.core.proto.obj
import studio.ivlis.nearclip.core.proto.objects
import studio.ivlis.nearclip.core.proto.str
import studio.ivlis.nearclip.core.store.Store
import studio.ivlis.nearclip.core.tailnet.PeerRoute
import studio.ivlis.nearclip.core.tailnet.TailnetAddress
import studio.ivlis.nearclip.core.tailnet.TailnetBridge
import studio.ivlis.nearclip.core.tailnet.TailnetStatus
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.concurrent.Callable
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.math.max

/**
 * The Nearclip engine (PROTOCOL.md): listener, member sessions, pairing, gossip, catch-up and history.
 *
 * All state lives on one engine thread; network I/O runs on worker threads that hand results to it.
 * DNS-SD is platform specific and fed in through [onServiceDiscovered] / [onServiceLost].
 */
class NearclipEngine(
    private val store: Store,
    val config: EngineConfig,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private class Backoff(val next: Long, val delay: Long)
    private class Ticket(val secret: ByteArray, val expiresAt: Long, val info: TicketInfo) { var failures = 0 }
    private class Creds(val id: String, val group: Group)

    private class CodeInvite(val conn: Conn) {
        @Volatile var prompt: PairPromptInfo? = null
        val decision = CompletableFuture<Boolean>()
    }

    private class JoinOp(val kind: String, var peerName: String?) {
        @Volatile var cancelled = false
        @Volatile var conn: Conn? = null
        @Volatile var reachedInviter = false
        @Volatile var sas: String? = null
    }

    data class JoinState(val kind: String, val peerName: String?, val sas: String?)

    private class PairAccept(val groupId: String, val key: ByteArray, val device: MemberRecord, val members: List<MemberRecord>)

    // ---- threads ----
    @Volatile private var engineThread: Thread? = null
    private val exec = ScheduledThreadPoolExecutor(1) { r ->
        Thread(r, "nearclip-engine").apply { isDaemon = true; engineThread = this }
    }.apply { removeOnCancelPolicy = true }
    private val io: ExecutorService = Executors.newCachedThreadPool { r -> Thread(r, "nearclip-io").apply { isDaemon = true } }
    private val saver: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "nearclip-save").apply { isDaemon = true } }

    // ---- persistent state (engine thread only) ----
    private val st: PersistedState
    private var group: Group
    private val history = ArrayList<Clip>()
    private val index = HashMap<String, Clip>()

    // ---- runtime state (engine thread only) ----
    @Volatile private var running = false
    @Volatile private var paused = false
    private var pairingMode = false
    private var server: ServerSocket? = null
    @Volatile var port = 0
        private set
    private val sessions = LinkedHashSet<MemberSession>()
    private val online = LinkedHashMap<String, MemberSession>()
    private val dialing = HashSet<String>()
    private val backoff = HashMap<String, Backoff>()
    private val discovered = LinkedHashMap<String, DiscoveredService>()
    private var ticket: Ticket? = null
    private var codeInvite: CodeInvite? = null
    private val codeAttempts = ArrayDeque<Long>()
    private var join: JoinOp? = null
    private val pendingLive = LinkedHashMap<String, Long>()
    /**
     * Live images arriving from other devices (PROTOCOL §6.6), by clip id. The same clip can come through several
     * sessions (forwarding); a transfer ends when one of them delivers it or all of them are gone.
     */
    private val transfers = HashMap<String, Transfer>()
    /** Images this device announced and has not sent or cancelled yet. */
    private val announced = HashMap<String, Long>()
    private var tickTask: ScheduledFuture<*>? = null
    private var saveTask: ScheduledFuture<*>? = null
    private var persistDirty = false
    private var historyDirty = false
    private var retentionDays = config.retentionDays
    private var maxItems = config.maxItems
    private var syncImages = config.syncImages
    private var lastPrune = 0L

    // Remote connection (embedded Tailscale node, PROTOCOL §10).
    private var remoteEnabled = false
    private var tailnetStatus = TailnetStatus.OFF
    private var tailnetServer: ServerSocket? = null
    private var tailnetGeneration = 0
    private var tailnetReach = ""
    private var tailnetPoll: ScheduledFuture<*>? = null
    private val tailnetExec: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "nearclip-tailnet").apply { isDaemon = true } }

    // ---- outputs ----
    private val _events = MutableSharedFlow<EngineEvent>(extraBufferCapacity = 512, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val events: SharedFlow<EngineEvent> = _events.asSharedFlow()

    /** Synchronous listener invoked on the engine thread in event order (used by the CLI). */
    @Volatile var listener: ((EngineEvent) -> Unit)? = null

    private val _state: MutableStateFlow<EngineSnapshot>
    val state: StateFlow<EngineSnapshot>

    val deviceId: String

    init {
        val now = clock()
        val loaded = Persistence.loadState(store)
        st = loaded ?: PersistedState(
            deviceId = newId(),
            deviceName = config.defaultName.trim().take(64).ifEmpty { "Nearclip" },
            groupId = "",
            groupKey = null,
            joinedAt = now,
        )
        deviceId = st.deviceId
        val key = st.groupKey
        group = if (key != null && normalizeId(st.groupId) != null) {
            Group(st.groupId, key, st.joinedAt)
        } else {
            // First launch (or the key is unreadable): start a fresh solo group.
            st.members.clear()
            st.endpoints.clear()
            st.lastSeen.clear()
            Group.create(now).also { st.groupId = it.id; st.groupKey = it.key; st.joinedAt = now }
        }
        for (c in Persistence.loadHistory(store)) if (index.put(c.id, c) == null) history.add(c)
        ensureOwnRecord()
        persistDirty = true
        writeNow()
        _state = MutableStateFlow(buildSnapshot())
        state = _state.asStateFlow()
    }

    // =====================================================================================
    // Public API (thread-safe)
    // =====================================================================================

    fun start() = call {
        if (running) return@call
        running = true
        prune()
        if (!paused) startNetworking()
        tickTask = exec.scheduleWithFixedDelay({ runTask { tick() } }, config.tickMs, config.tickMs, TimeUnit.MILLISECONDS)
        tick()
    }

    /** Sends bye(shutdown) to every peer, closes everything and flushes state. Blocks until done. */
    fun stop() {
        val closing = try {
            call {
                if (!running) return@call emptyList<MemberSession>()
                running = false
                tickTask?.cancel(false)
                tickTask = null
                val list = sessions.toList()
                stopNetworking("shutdown")
                list
            }
        } catch (_: RejectedExecutionException) {
            emptyList()
        }
        val deadline = System.currentTimeMillis() + 1_500
        for (s in closing) s.awaitWriter(max(1, deadline - System.currentTimeMillis()))
        try { call { writeNow() } } catch (_: RejectedExecutionException) {}
        // Let the embedded node shut down cleanly (bounded by the bridge's own timeout).
        try { tailnetExec.submit {}.get(10, TimeUnit.SECONDS) } catch (_: Exception) {}
    }

    /** [stop] and release all threads. The engine cannot be restarted afterwards. */
    fun shutdown() {
        stop()
        exec.shutdown()
        saver.shutdown()
        tailnetExec.shutdown()
        try { saver.awaitTermination(3, TimeUnit.SECONDS) } catch (_: InterruptedException) {}
        io.shutdownNow()
    }

    fun snapshot(): EngineSnapshot = call { buildSnapshot() }

    fun blobFile(clip: Clip): File = store.file(Persistence.blobFileName(clip))

    /** [otp]: a verification code found in a message (PROTOCOL §6.7). */
    fun sendText(text: String, otp: Boolean = false): SendResult = call {
        if (text.isEmpty()) return@call SendResult(null, 0)
        if (paused) return@call SendResult(null, 0, paused = true)
        val tooLarge = text.toByteArray(Charsets.UTF_8).size > Clip.MAX_TEXT_BYTES
        val now = clock()
        val c = Clip(
            id = newId(), ts = max(now, st.newestLocalTs + 1), src = deviceId, kind = ClipKind.TEXT, text = text,
            groupId = group.id, receivedAt = now, sourceName = st.deviceName, sourcePlatform = config.platform,
            localOnly = tooLarge, otp = otp && !tooLarge,
        )
        if (tooLarge) emit(EngineEvent.TooLarge(ClipKind.TEXT))
        produce(c)
    }

    /** Adds an image clip from encoded PNG/JPEG bytes. Heavy work (hashing, writing the blob) runs on the caller's thread. */
    fun sendImage(bytes: ByteArray, mime: String, width: Int? = null, height: Int? = null, id: String? = null): SendResult {
        // [id]: from announceImage (PROTOCOL §6.6). Never reuse an id that already names a blob here.
        val announcedId = normalizeId(id)
        if (bytes.isEmpty() || paused) {
            if (announcedId != null) post { if (announced.remove(announcedId) != null) sendCancel(announcedId) }
            return SendResult(null, 0, paused = paused)
        }
        val normalizedMime = if (mime.lowercase() == "image/jpeg" || mime.lowercase() == "image/jpg") "image/jpeg" else "image/png"
        val draft = Clip(
            id = newId(), ts = 0, src = deviceId, kind = ClipKind.IMAGE, mime = normalizedMime, size = bytes.size.toLong(),
            sha = Hex.encode(Crypto.sha256(bytes)), w = width?.takeIf { it > 0 }, h = height?.takeIf { it > 0 }, groupId = "",
        ).let { d -> if (announcedId != null && !blobFile(d.copy(id = announcedId)).exists()) d.copy(id = announcedId) else d }
        val fileName = Persistence.blobFileName(draft)
        store.writeFile(fileName, bytes)
        return call {
            val wasAnnounced = announcedId != null && announced.remove(announcedId) != null
            if (paused) {
                store.delete(fileName)
                if (wasAnnounced) sendCancel(announcedId!!)
                return@call SendResult(null, 0, paused = true)
            }
            val tooLarge = bytes.size > Clip.MAX_IMAGE_BYTES
            if (tooLarge) {
                emit(EngineEvent.TooLarge(ClipKind.IMAGE))
                if (wasAnnounced) sendCancel(announcedId!!)
            }
            val now = clock()
            var c = draft
            if (index.containsKey(c.id) || st.tombstones.containsKey(c.id)) {
                c = c.copy(id = newId())
                store.writeFile(Persistence.blobFileName(c), bytes)
                store.delete(fileName)
            }
            produce(
                c.copy(
                    ts = max(now, st.newestLocalTs + 1), groupId = group.id, receivedAt = now,
                    sourceName = st.deviceName, sourcePlatform = config.platform, localOnly = tooLarge,
                ),
            )
        }
    }

    /**
     * Tells the other devices that an image was just copied here, before it is encoded (PROTOCOL §6.6), so they can
     * show it arriving right away. Pass the returned id to [sendImage], or to [cancelImage] if it is not sent.
     */
    fun announceImage(): String {
        val id = newId()
        post {
            if (!running || paused) return@post
            announced[id] = clock()
            for (s in online.values) {
                val p = st.policies[s.peerId] ?: studio.ivlis.nearclip.core.model.SyncPolicy()
                if (p.send && p.images) s.sendJson(Msg.incoming(id))
            }
        }
        return id
    }

    /** The announced image will not be sent after all (unreadable, too large, replaced by a newer copy). */
    fun cancelImage(id: String) = post {
        val key = normalizeId(id) ?: return@post
        if (announced.remove(key) != null) sendCancel(key)
    }

    private fun sendCancel(id: String) {
        for (s in online.values) s.sendJson(Msg.incomingCancel(id))
    }

    fun delete(ids: Collection<String>) = post {
        val now = clock()
        applyDeletes(ids.mapNotNull { normalizeId(it) }.distinct().map { Tombstone(it, now) }, from = null)
    }

    /** Deletes every clip on all devices, pinned ones included (PROTOCOL §6.3: pins are local, clearing deletes every clip). */
    fun clearHistory() = post {
        val now = clock()
        applyDeletes(history.map { Tombstone(it.id, now) }, from = null)
    }

    fun setPinned(id: String, pinned: Boolean) = post {
        val c = index[id] ?: return@post
        if (c.pinned == pinned) return@post
        val updated = c.copy(pinned = pinned)
        index[id] = updated
        val i = history.indexOfFirst { it.id == id }
        if (i >= 0) history[i] = updated
        markHistory()
    }

    fun rename(name: String) = post {
        val trimmed = name.trim().take(64)
        if (trimmed.isEmpty() || trimmed == st.deviceName) return@post
        st.deviceName = trimmed
        val me = ownRecord.copy(name = trimmed, updatedAt = max(clock(), ownRecord.updatedAt + 1))
        st.members[deviceId] = me
        markPersist()
        for (o in online.values) o.sendJson(Msg.members(listOf(me)))
        emit(EngineEvent.MembersChanged(memberList()))
    }

    fun removeMember(id: String) = post {
        val pid = normalizeId(id) ?: return@post
        if (pid == deviceId) return@post
        val cur = st.members[pid] ?: return@post
        val r = cur.copy(removed = true, updatedAt = max(clock(), cur.updatedAt + 1))
        st.members[pid] = r
        for (s in sessions.toList()) if (s.peerId == pid) s.bye("removed")
        for ((opid, o) in online) if (opid != pid && !o.supportsRekey) o.sendJson(Msg.members(listOf(r)))
        st.endpoints.remove(pid)
        backoff.remove(pid)
        rotateAfterRemoval()
        emit(EngineEvent.MembersChanged(memberList()))
    }

    /** This device leaves its group and starts a new, empty one (history is kept). */
    fun leaveGroup() = post { leave("leaving", announce = true) }

    fun setPaused(value: Boolean) = post {
        if (paused == value) return@post
        paused = value
        if (!running) return@post
        if (value) stopNetworking("shutdown") else {
            startNetworking()
            tick()
        }
    }

    /** Advertise pm=1 while the Add-device UI is visible (the platform layer re-registers DNS-SD). */
    fun setPairingMode(on: Boolean) = post { pairingMode = on }

    fun setRetention(days: Int, items: Int = 1000) = post {
        retentionDays = days
        maxItems = items
        prune()
    }

    fun setSyncImages(on: Boolean) = post { syncImages = on }

    fun createTicket(): TicketInfo = call {
        val secret = Crypto.random(16)
        val hosts = config.localAddresses().toMutableList()
        // A joiner in the same tailnet can pair from another network (the node also listens on the LAN port).
        val tip = tailnetStatus.ip
        if (tailnetStatus.isRunning && tip != null && tip !in hosts) hosts.add(tip)
        val p = if (port > 0) port else config.port
        val uri = PairingUri(deviceId, st.deviceName, config.platform, hosts, p, secret).build()
        val expires = clock() + config.ticketLifetimeMs
        val info = TicketInfo(uri, expires, hosts, p)
        ticket = Ticket(secret, expires, info)
        emit(EngineEvent.TicketCreated(info))
        info
    }

    fun cancelTicket() = post { ticket = null }

    /** Joiner: QR code / nearclip:// link. */
    fun joinWithUri(uri: PairingUri, extraEndpoints: List<Endpoint> = emptyList()) = post {
        if (join != null) { emit(EngineEvent.PairFailed("busy", uri.name)); return@post }
        if (uri.inviterId == deviceId) { emit(EngineEvent.PairFailed("self", uri.name)); return@post }
        val targets = LinkedHashSet<Endpoint>()
        uri.hosts.forEach { h -> runCatching { Endpoint(h, uri.port) }.getOrNull()?.let { targets.add(it) } }
        discovered[uri.inviterId]?.endpoints?.let { targets.addAll(it) }
        targets.addAll(extraEndpoints)
        if (tailnetStatus.isRunning) {
            val id8 = uri.inviterId.replace("-", "").take(8)
            for (p in tailnetStatus.peers) {
                if (p.idPrefix == id8) runCatching { Endpoint(p.ip, uri.port) }.getOrNull()?.let { targets.add(it) }
            }
        }
        val candidates = candidatesFor(targets.toList())
        if (candidates.isEmpty()) { emit(EngineEvent.PairFailed("unreachable", uri.name)); return@post }
        val op = JoinOp("qr", uri.name)
        join = op
        val me = joinerRecord()
        io.execute { runJoin(op, candidates) { conn -> qrHandshake(op, conn, uri, me) } }
    }

    /** Joiner: numeric-comparison pairing with a nearby device or an explicit address. */
    fun pairWithCode(targets: List<Endpoint>, peerName: String? = null) = post {
        if (join != null) { emit(EngineEvent.PairFailed("busy", peerName)); return@post }
        val candidates = candidatesFor(targets, fallback = true)
        if (candidates.isEmpty()) { emit(EngineEvent.PairFailed("unreachable", peerName)); return@post }
        val op = JoinOp("code", peerName)
        join = op
        val me = joinerRecord()
        io.execute { runJoin(op, candidates) { conn -> codeHandshake(op, conn, me) } }
    }

    fun cancelJoin() = post {
        val op = join ?: return@post
        op.cancelled = true
        join = null
        op.conn?.close()
    }

    /** Inviter: answer the pending code-pairing prompt. */
    fun answerPairPrompt(accept: Boolean) = post {
        val ci = codeInvite ?: return@post
        if (ci.prompt == null) return@post
        codeInvite = null
        ci.decision.complete(accept)
    }

    /** Dial a member session at an explicit address. */
    fun connect(endpoint: Endpoint) = post { dialMember(null, candidatesFor(listOf(endpoint), fallback = true)) }

    // ---- Remote connection (public) ----

    /** Whether this build can run the embedded Tailscale node. */
    val tailnetAvailable: Boolean get() = config.tailnet != null && TailnetBridge.available

    /** Remote connection on/off (the app persists the choice). The node runs only while networking runs. */
    fun setRemoteEnabled(on: Boolean) = post {
        if (remoteEnabled == on) return@post
        remoteEnabled = on
        if (on) startTailnetIfNeeded() else stopTailnet()
    }

    /** Makes sure a Tailscale sign-in URL exists; completes with the fresh status. */
    fun tailnetLogin(): CompletableFuture<TailnetStatus> {
        val f = CompletableFuture<TailnetStatus>()
        post {
            if (tailnetServer == null) { f.complete(tailnetStatus); return@post }
            val gen = tailnetGeneration
            tailnetExec.execute {
                val st = TailnetBridge.login()
                post { if (gen == tailnetGeneration) applyTailnet(st) }
                f.complete(st)
            }
        }
        return f
    }

    /** Signs this device out of Tailscale (remote connection then needs a new sign-in). */
    fun tailnetLogout() = post {
        if (tailnetServer == null) return@post
        val gen = tailnetGeneration
        tailnetExec.execute {
            val st = TailnetBridge.logout()
            post { if (gen == tailnetGeneration) applyTailnet(st) }
        }
    }

    /**
     * The device's network changed (Wi-Fi ↔ cellular, wake, back in the foreground): drop sessions that went
     * silent, forget back-off and redial now (PROTOCOL §4.5, §10.4). [netInfo] is the Android interface report
     * for the embedded node (tailnet/README.md).
     */
    fun networkChanged(netInfo: String? = null) = post {
        if (tailnetServer != null) {
            tailnetExec.execute { if (netInfo != null) TailnetBridge.setNetwork(netInfo) else TailnetBridge.networkChanged() }
        }
        if (!running || paused) return@post
        val now = clock()
        for (s in online.values.toList()) if (now - s.lastReceived > 20_000) s.close()
        backoff.clear()
        for (s in online.values) s.sendJson(Msg.PING)
        tick()
    }

    fun onServiceDiscovered(d: DiscoveredService) = post {
        if (d.id == deviceId) return@post
        val prev = discovered.put(d.id, d)
        if (d.groupTag == group.tag) {
            if (prev == null || prev.groupTag != d.groupTag) backoff.remove(d.id)
            considerDial(d)
        }
    }

    fun onServiceLost(id: String) = post { discovered.remove(id.lowercase()) }

    fun clearDiscovered() = post { discovered.clear() }

    fun joinState(): JoinState? = call { join?.let { JoinState(it.kind, it.peerName, it.sas) } }

    fun log(message: String) = emit(EngineEvent.Log(message))

    // =====================================================================================
    // Engine thread plumbing
    // =====================================================================================

    private fun post(task: () -> Unit) {
        try {
            exec.execute { runTask(task) }
        } catch (_: RejectedExecutionException) {
        }
    }

    private fun <T> call(task: () -> T): T {
        if (Thread.currentThread() === engineThread) return task()
        val f = exec.submit(Callable { runTaskResult(task) })
        try {
            return f.get()
        } catch (e: ExecutionException) {
            throw e.cause ?: e
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw RejectedExecutionException("interrupted")
        }
    }

    private fun runTask(task: () -> Unit) {
        try {
            task()
        } catch (t: Throwable) {
            log("internal error: ${t}")
        } finally {
            publish()
        }
    }

    private fun <T> runTaskResult(task: () -> T): T {
        try {
            return task()
        } finally {
            publish()
        }
    }

    private fun publish() {
        try { _state.value = buildSnapshot() } catch (_: Throwable) {}
    }

    internal fun scheduleForceClose(s: MemberSession, ms: Long) {
        try { exec.schedule({ s.close() }, ms, TimeUnit.MILLISECONDS) } catch (_: RejectedExecutionException) { s.close() }
    }

    private fun emit(e: EngineEvent) {
        try { listener?.invoke(e) } catch (_: Throwable) {}
        _events.tryEmit(e)
    }

    private val ownRecord: MemberRecord get() = st.members[deviceId] ?: freshOwnRecord(clock())

    private fun freshOwnRecord(now: Long) =
        MemberRecord(deviceId, st.deviceName, config.platform, config.model, config.appVersion, now, now)

    private fun ensureOwnRecord() {
        val now = clock()
        var rec = st.members[deviceId] ?: freshOwnRecord(now)
        if (rec.name != st.deviceName || rec.platform != config.platform || rec.app != config.appVersion ||
            rec.model != config.model || rec.removed
        ) {
            rec = rec.copy(
                name = st.deviceName, platform = config.platform, app = config.appVersion, model = config.model,
                removed = false, updatedAt = max(now, rec.updatedAt + 1),
            )
        }
        st.members[deviceId] = rec
    }

    /** Own record as sent in pair_request. */
    private fun joinerRecord(): MemberRecord = ownRecord.copy(removed = false)

    private fun memberList(): List<MemberRecord> = st.members.values.sortedWith(compareBy({ it.addedAt }, { it.id }))

    private fun buildSnapshot(): EngineSnapshot = EngineSnapshot(
        deviceId = deviceId,
        deviceName = st.deviceName,
        platform = config.platform,
        groupId = group.id,
        groupTag = group.tag,
        members = memberList(),
        online = online.keys.toSet(),
        lastSeen = HashMap(st.lastSeen),
        history = ArrayList(history),
        nearby = discovered.values.filter { it.groupTag != group.tag }
            .sortedWith(compareBy({ !it.pairingMode }, { it.name.lowercase() })),
        port = port,
        running = running,
        paused = paused,
        pairingMode = pairingMode,
        ticket = ticket?.info,
        prompt = codeInvite?.prompt,
        joining = join != null,
        addresses = config.localAddresses(),
        routes = online.mapValues { if (it.value.remote) PeerRoute.REMOTE else PeerRoute.LAN },
        remoteEnabled = remoteEnabled,
        tailnet = tailnetStatus,
    )

    // ---- persistence ----

    private fun markPersist() {
        persistDirty = true
        scheduleSave()
    }

    private fun markHistory() {
        historyDirty = true
        scheduleSave()
    }

    private fun scheduleSave() {
        if (saveTask != null) return
        saveTask = try {
            exec.schedule({ runTask { saveTask = null; writeNow(async = true) } }, 300, TimeUnit.MILLISECONDS)
        } catch (_: RejectedExecutionException) {
            null
        }
    }

    private fun writeNow(async: Boolean = false) {
        st.groupId = group.id
        st.groupKey = group.key
        val stateText = if (persistDirty) Persistence.stateJson(st, store) else null
        val historyText = if (historyDirty) Persistence.historyJson(history, store) else null
        persistDirty = false
        historyDirty = false
        if (stateText == null && historyText == null) return
        val work = Runnable {
            try {
                stateText?.let { store.write(Persistence.STATE, it) }
                historyText?.let { store.write(Persistence.HISTORY, it) }
            } catch (e: Exception) {
                log("saving state failed: ${e.message}")
            }
        }
        try {
            if (async) saver.execute(work) else saver.submit(work).get(10, TimeUnit.SECONDS)
        } catch (_: Exception) {
            work.run()
        }
    }

    // ---- history ----

    private fun addToHistory(c: Clip) {
        if (index.containsKey(c.id)) return
        var i = 0
        while (i < history.size && history[i].ts >= c.ts) i++
        history.add(i, c)
        index[c.id] = c
        markHistory()
    }

    private fun removeFromHistory(id: String): Boolean {
        val c = index.remove(id) ?: return false
        history.removeAll { it.id == id }
        if (c.isImage) store.delete(Persistence.blobFileName(c))
        if (c.isText) store.delete(Persistence.textFileName(c.id))
        markHistory()
        return true
    }

    private fun prune() {
        val now = clock()
        lastPrune = now
        val expired = history.filter { it.isExpired(now) }.map { Tombstone(it.id, now) }
        if (expired.isNotEmpty()) applyDeletes(expired, null)
        val drop = LinkedHashSet<String>()
        if (retentionDays > 0) {
            val cutoff = now - retentionDays * DAY
            for (c in history) if (!c.pinned && c.ts < cutoff) drop.add(c.id)
        }
        val unpinned = history.filter { !it.pinned && it.id !in drop }
        if (unpinned.size > maxItems) for (c in unpinned.drop(maxItems)) drop.add(c.id)
        for (id in drop) removeFromHistory(id)
        val tombCutoff = now - 30 * DAY
        if (st.tombstones.values.removeAll { it < tombCutoff }) markPersist()
        if (drop.isNotEmpty()) emit(EngineEvent.ClipsDeleted(drop.toList()))
    }

    // =====================================================================================
    // Networking
    // =====================================================================================

    private fun startNetworking() {
        if (server == null) startListener()
    }

    private fun stopNetworking(reason: String) {
        try { server?.close() } catch (_: Exception) {}
        server = null
        stopTailnet()
        for (s in sessions.toList()) s.bye(reason)
        join?.let { op ->
            op.cancelled = true
            op.conn?.close()
            join = null
            emit(EngineEvent.PairFailed("cancelled", op.peerName))
        }
        codeInvite?.let { ci ->
            codeInvite = null
            ci.decision.completeExceptionally(IOException("stopped"))
            ci.conn.close()
            if (ci.prompt != null) emit(EngineEvent.PairPromptDismissed)
        }
        discovered.clear()
    }

    private fun bind(p: Int): ServerSocket {
        val ss = ServerSocket()
        try {
            ss.reuseAddress = p != 0
            ss.bind(InetSocketAddress(p), 50)
            return ss
        } catch (e: IOException) {
            ss.close()
            throw e
        }
    }

    private fun startListener() {
        val ss = try {
            bind(config.port)
        } catch (e: IOException) {
            if (config.port != 0) {
                try { bind(0) } catch (e2: IOException) { log("listener failed: ${e2.message}"); null }
            } else {
                log("listener failed: ${e.message}")
                null
            }
        } ?: return
        server = ss
        port = ss.localPort
        Thread({ acceptLoop(ss, viaTailnet = false) }, "nearclip-accept").apply { isDaemon = true; start() }
        emit(EngineEvent.Ready(port, group.id, group.tag))
        startTailnetIfNeeded()
    }

    private fun acceptLoop(ss: ServerSocket, viaTailnet: Boolean) {
        while (!ss.isClosed) {
            val sock = try { ss.accept() } catch (_: IOException) { break }
            if (!running || paused) {
                try { sock.close() } catch (_: Exception) {}
                continue
            }
            Conn.tune(sock)
            try {
                io.execute { serveIncoming(Conn(sock), viaTailnet) }
            } catch (_: RejectedExecutionException) {
                try { sock.close() } catch (_: Exception) {}
            }
        }
    }

    // ---- Embedded Tailscale node ----

    private fun startTailnetIfNeeded() {
        val opts = config.tailnet ?: return
        if (!remoteEnabled || !running || paused || port <= 0) return
        val ss = tailnetServer ?: try {
            // Inbound tailnet connections arrive here from the bridge (loopback only).
            ServerSocket().apply { bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 50) }.also { s ->
                tailnetServer = s
                Thread({ acceptLoop(s, viaTailnet = true) }, "nearclip-accept-tailnet").apply { isDaemon = true; start() }
            }
        } catch (e: IOException) {
            applyTailnet(TailnetStatus(state = "error", error = e.message))
            return
        }
        val cfg = buildJsonObject {
            put("dir", opts.directory.absolutePath)
            put("deviceId", deviceId)
            put("deviceName", st.deviceName)
            putJsonArray("ports") { add(port) }
            put("forward", "127.0.0.1:${ss.localPort}")
            opts.controlUrl?.let { put("controlURL", it) }
            opts.logPath?.let { put("logPath", it) }
            if (opts.testMode) put("testMode", true)
        }
        tailnetGeneration++
        val gen = tailnetGeneration
        if (!tailnetStatus.isRunning) applyTailnet(TailnetStatus(state = "starting"))
        tailnetExec.execute {
            opts.directory.mkdirs()
            opts.netInfo?.invoke()?.let { TailnetBridge.setNetwork(it) }
            val status = TailnetBridge.start(cfg)
            post {
                if (gen == tailnetGeneration) {
                    applyTailnet(status)
                    scheduleTailnetPoll(gen)
                }
            }
        }
    }

    private fun stopTailnet() {
        val active = tailnetServer != null || tailnetStatus.state != "off"
        try { tailnetServer?.close() } catch (_: Exception) {}
        tailnetServer = null
        tailnetGeneration++
        tailnetPoll?.cancel(false)
        tailnetPoll = null
        if (!active) return
        try { tailnetExec.execute { TailnetBridge.stop() } } catch (_: RejectedExecutionException) {}
        applyTailnet(TailnetStatus.OFF)
    }

    private fun scheduleTailnetPoll(gen: Int) {
        val delay = if (tailnetStatus.isRunning) 5_000L else 1_500L
        tailnetPoll = try {
            exec.schedule({
                runTask {
                    if (gen != tailnetGeneration || tailnetServer == null) return@runTask
                    tailnetExec.execute {
                        val status = TailnetBridge.status()
                        post {
                            if (gen == tailnetGeneration) {
                                applyTailnet(status)
                                scheduleTailnetPoll(gen)
                            }
                        }
                    }
                }
            }, delay, TimeUnit.MILLISECONDS)
        } catch (_: RejectedExecutionException) {
            null
        }
    }

    private fun applyTailnet(status: TailnetStatus) {
        val old = tailnetStatus
        tailnetStatus = status
        if (!old.sameEssentials(status)) emit(EngineEvent.TailnetChanged(status))
        // New ways to reach members (node came up, other nodes appeared): dial at once.
        val reach = if (status.isRunning) status.ip + "|" + status.peers.joinToString(",") { "${it.idPrefix}@${it.ip}" } else ""
        if (reach != tailnetReach) {
            tailnetReach = reach
            if (status.isRunning) {
                backoff.clear()
                tick()
            }
        }
    }

    private fun busy(pid: String): Boolean =
        online.containsKey(pid) || dialing.contains(pid) || sessions.any { it.peerId == pid && !it.closed && !it.welcomed }

    /** All ways to reach a member: the discovered service, remembered endpoints and its tailnet node. */
    private fun dialCandidates(pid: String): List<DialCandidate> {
        val out = LinkedHashSet<Endpoint>()
        discovered[pid]?.takeIf { it.groupTag == group.tag }?.endpoints?.let { out.addAll(it) }
        st.endpoints[pid]?.let { out.addAll(it) }
        if (tailnetStatus.isRunning) {
            val id8 = pid.replace("-", "").take(8)
            for (p in tailnetStatus.peers) {
                if (p.idPrefix == id8) runCatching { Endpoint(p.ip, EngineConfig.TAILNET_PORT) }.getOrNull()?.let { out.add(it) }
            }
        }
        return candidatesFor(out.toList())
    }

    /**
     * Direct candidates for LAN endpoints; tailnet endpoints go through the bridge proxy (and through the OS when
     * the Tailscale app itself is connected) and start a little later (PROTOCOL §10.3).
     */
    private fun candidatesFor(eps: List<Endpoint>, fallback: Boolean = false): List<DialCandidate> {
        val out = ArrayList<DialCandidate>()
        val ts = tailnetStatus
        var osTailnet: Boolean? = null
        for (e in eps.distinct()) {
            if (!TailnetAddress.contains(e.host)) {
                out.add(DialCandidate(e, e))
                continue
            }
            if (e.host == ts.ip) continue
            val pp = ts.proxyPort
            val token = ts.token
            if (ts.isRunning && pp != null && token != null) {
                out.add(DialCandidate(Endpoint("127.0.0.1", pp), e, "NCTN1 $token ${e.host}:${e.port}\n",
                    EngineConfig.TAILNET_DELAY_MS, remote = true))
            }
            if (osTailnet == null) osTailnet = config.localAddresses().any { TailnetAddress.contains(it) }
            if (osTailnet == true) out.add(DialCandidate(e, e, null, EngineConfig.TAILNET_DELAY_MS, remote = true))
        }
        if (out.isEmpty() && fallback && eps.isNotEmpty()) out.add(DialCandidate(eps[0], eps[0]))
        return out
    }

    private fun tick() {
        val now = clock()
        ticket?.let { t ->
            if (t.expiresAt <= now) {
                ticket = null
                emit(EngineEvent.TicketExpired)
            }
        }
        expireTransfers(now)
        for (s in sessions.toList()) {
            if (s.closed) continue
            if (now - s.lastSent >= config.keepAliveMs) s.sendJson(Msg.PING)
            if (now - s.lastReceived >= config.idleTimeoutMs) {
                log("session ${s.shortPeer}: no traffic for ${config.idleTimeoutMs / 1000} s, closing")
                s.close()
            }
        }
        prune()
        if (!running || paused) return
        for (m in st.members.values.toList()) {
            if (m.id == deviceId || m.removed || busy(m.id)) continue
            val b = backoff[m.id]
            if (b != null && now < b.next) continue
            // Every known way to reach the member at once; the first connection wins (PROTOCOL §4.5).
            val targets = dialCandidates(m.id)
            if (targets.isEmpty()) continue
            val delay = b?.delay ?: config.dialIntervalMs
            backoff[m.id] = Backoff(now + delay, minOf(delay * 2, config.maxBackoffMs))
            dialMember(m.id, targets)
        }
    }

    private fun considerDial(d: DiscoveredService) {
        if (!running || paused || busy(d.id) || st.members[d.id]?.removed == true || d.endpoints.isEmpty()) return
        if (deviceId < d.id) {
            dialMember(d.id, dialCandidates(d.id))
        } else {
            try {
                exec.schedule({
                    runTask {
                        val d2 = discovered[d.id]
                        if (d2 != null && d2.groupTag == group.tag && !busy(d.id) && running && !paused) dialMember(d.id, dialCandidates(d.id))
                    }
                }, 3, TimeUnit.SECONDS)
            } catch (_: RejectedExecutionException) {
            }
        }
    }

    private fun dialMember(peerId: String?, targets: List<DialCandidate>) {
        if (!running || paused || targets.isEmpty()) return
        if (peerId != null) {
            if (busy(peerId) || st.members[peerId]?.removed == true) return
            dialing.add(peerId)
        }
        val creds = Creds(deviceId, group)
        try {
            io.execute {
                var session: MemberSession? = null
                try {
                    val (sock, cand) = Conn.race(targets, config.connectTimeoutMs, io)
                    session = clientMemberHandshake(Conn(sock), cand, creds)
                } catch (e: HandshakeError) {
                    log("dial ${peerId?.take(8) ?: targets.first().address}: ${e.code}")
                } catch (e: Exception) {
                    log("dial ${peerId?.take(8) ?: targets.first().address}: ${e.message ?: e.javaClass.simpleName}")
                }
                post {
                    if (peerId != null) dialing.remove(peerId)
                    if (session != null) attach(session)
                }
            }
        } catch (_: RejectedExecutionException) {
            if (peerId != null) dialing.remove(peerId)
        }
    }

    private fun clientMemberHandshake(conn: Conn, cand: DialCandidate, creds: Creds): MemberSession {
        try {
            conn.setReadTimeout(config.handshakeTimeoutMs)
            val eph = P256.generate()
            val nc = Crypto.random(16)
            val helloC = Hello.member(creds.id, creds.group.tag, eph.publicX963, nc)
            conn.write(helloC)
            val resp = HelloFrame(conn.read())
            if (resp.t == "error") throw HandshakeError(resp.code ?: "error")
            if (resp.t != "hello" || resp.mode != "member") throw HandshakeError("protocol")
            if (resp.version != 1L) throw HandshakeError("version")
            val pid = resp.id ?: throw HandshakeError("protocol")
            if (pid == creds.id) throw HandshakeError("self")
            if (resp.groupTag != creds.group.tag) throw HandshakeError("group_mismatch")
            val e = resp.ephemeral ?: throw HandshakeError("protocol")
            val z = P256.ecdh(eph.private, e)
            val th = Crypto.sha256(helloC, resp.raw)
            val okm = Crypto.hkdf(z, creds.group.authKey, concat("nearclip-session".utf8, th), 64)
            conn.setReadTimeout(SESSION_READ_TIMEOUT_MS)
            return MemberSession(this, conn, SecureChannel.fromOkm(okm, isClient = true), pid, isClient = true,
                clientId = creds.id, groupId = creds.group.id, dialed = cand.address, remote = cand.remote)
        } catch (e: Exception) {
            conn.close()
            throw e
        }
    }

    private fun attach(s: MemberSession) {
        if (!running || paused || s.retired || s.groupId != group.id) {
            s.close()
            return
        }
        sessions.add(s)
        // Removal is decided after both welcomes are merged (PROTOCOL §4.3): a re-added device carries a newer
        // record of itself than a member that was offline while it was re-added.
        s.sendJson(Msg.welcome(ownRecord, memberList(), ownEndpoints(), extended = true))
        s.start()
    }

    private fun ownEndpoints(): List<Endpoint> {
        if (port <= 0) return emptyList()
        val eps = config.localAddresses().mapNotNull { runCatching { Endpoint(it, port) }.getOrNull() }.toMutableList()
        val ip = tailnetStatus.ip
        if (tailnetStatus.isRunning && ip != null) eps.add(Endpoint(ip, EngineConfig.TAILNET_PORT))
        return eps
    }

    /** Keeps up to 6 LAN and 2 tailnet endpoints per member, newest first (PROTOCOL §4.5). */
    private fun rememberEndpoints(pid: String, eps: List<Endpoint>) {
        val merged = LinkedHashSet<Endpoint>()
        merged.addAll(eps)
        st.endpoints[pid]?.let { merged.addAll(it) }
        val list = (merged.filter { !TailnetAddress.contains(it.host) }.take(6) +
            merged.filter { TailnetAddress.contains(it.host) }.take(2)).toMutableList()
        if (st.endpoints[pid] != list) {
            st.endpoints[pid] = list
            markPersist()
        }
    }

    // ---- incoming connections ----

    private fun reject(conn: Conn, code: String) {
        try { conn.write(Hello.error(code)) } catch (_: Exception) {}
        lingerClose(conn)
    }

    private fun lingerClose(conn: Conn) {
        try { conn.socket.shutdownOutput() } catch (_: Exception) {}
        try { exec.schedule({ conn.close() }, 2, TimeUnit.SECONDS) } catch (_: RejectedExecutionException) { conn.close() }
    }

    private fun serveIncoming(conn: Conn, viaTailnet: Boolean) {
        try {
            conn.setReadTimeout(config.handshakeTimeoutMs)
            val hello = try { HelloFrame(conn.read()) } catch (e: ProtocolException) { reject(conn, "bad_request"); return }
            if (hello.t != "hello") { reject(conn, "bad_request"); return }
            if (hello.version != 1L) { reject(conn, "version"); return }
            val pid = hello.id
            val e = hello.ephemeral
            if (pid == null || e == null || e.size != 65) { reject(conn, "bad_request"); return }
            if (pid == deviceId) { conn.close(); return }
            when (hello.mode) {
                "member" -> serveMember(conn, hello, pid, e, viaTailnet)
                "pair-qr" -> servePairQr(conn, hello, pid, e)
                "pair-code" -> servePairCode(conn, hello, pid, e)
                else -> reject(conn, "bad_request")
            }
        } catch (_: Exception) {
            conn.close()
        }
    }

    private fun serveMember(conn: Conn, hello: HelloFrame, pid: String, e: ByteArray, viaTailnet: Boolean) {
        val creds = call { if (running && !paused) Creds(deviceId, group) else null } ?: run { conn.close(); return }
        if (hello.groupTag != creds.group.tag) { reject(conn, "group_mismatch"); return }
        val eph = P256.generate()
        val z = try { P256.ecdh(eph.private, e) } catch (_: Exception) { reject(conn, "bad_request"); return }
        val ns = Crypto.random(16)
        val helloS = Hello.member(deviceId, creds.group.tag, eph.publicX963, ns)
        conn.write(helloS)
        val th = Crypto.sha256(hello.raw, helloS)
        val okm = Crypto.hkdf(z, creds.group.authKey, concat("nearclip-session".utf8, th), 64)
        conn.setReadTimeout(SESSION_READ_TIMEOUT_MS)
        val s = MemberSession(this, conn, SecureChannel.fromOkm(okm, isClient = false), pid, isClient = false,
            clientId = pid, groupId = creds.group.id, dialed = null, viaTailnet = viaTailnet,
            remote = viaTailnet || TailnetAddress.contains(conn.remoteHost))
        post { attach(s) }
    }

    // =====================================================================================
    // Session callbacks (called from session threads)
    // =====================================================================================

    internal fun onSessionMessage(s: MemberSession, obj: JsonObject): BlobAssembly? = call {
        if (s.closed || s.retired) return@call null
        if (s.groupId != group.id) {
            s.close()
            return@call null
        }
        val t = obj.str("t")
        if (t == null) {
            s.close()
            return@call null
        }
        when (t) {
            "ping" -> { s.sendJson(Msg.PONG); null }
            "pong" -> null
            "bye" -> {
                handleBye(s, obj.str("reason") ?: "shutdown")
                null
            }
            else -> if (!s.welcomed) {
                if (t == "welcome") handleWelcome(s, obj) else {
                    log("session ${s.shortPeer}: expected welcome, got ${t}")
                    s.close()
                }
                null
            } else {
                when (t) {
                    "rekey" -> { applyRekey(obj, s); null }
                    "clip" -> handleClip(s, obj)
                    "inv" -> { handleInventory(s, obj); null }
                    "want" -> { handleWant(s, obj); null }
                    "del" -> { applyDeletes(parseIdTs(obj, "items"), s); null }
                    "members" -> { mergeMembers(parseMembers(obj), s); null }
                    "incoming" -> { handleIncoming(s, obj); null }
                    "error" -> { log("peer ${s.shortPeer} error: ${obj.str("code")} ${obj.str("msg") ?: ""}"); null }
                    else -> null
                }
            }
        }
    }

    internal fun onBlobComplete(s: MemberSession, asm: BlobAssembly) {
        try {
            call {
                val id = asm.clip.id
                if (s.retired || index.containsKey(id) || st.tombstones.containsKey(id) || s.groupId != group.id) {
                    asm.file.delete()
                    dropTransfer(id, s, "cancelled")
                    return@call
                }
                if (!canReceive(asm.clip)) { asm.file.delete(); dropTransfer(id, s, "cancelled"); return@call }
                store.writeFile(Persistence.blobFileName(asm.clip), asm.file.readBytes())
                asm.file.delete()
                acceptClip(asm.clip, asm.live, s)
            }
        } catch (_: RejectedExecutionException) {
            asm.file.delete()
        }
    }

    /** Reader thread: another chunk of a live image arrived (PROTOCOL §6.6). */
    internal fun onBlobProgress(s: MemberSession, clipId: String, received: Long) = post { noteProgress(clipId, received, s) }

    /** Reader thread: the session dropped an image transfer (bad chunk, checksum mismatch, too many at once). */
    internal fun onBlobDropped(s: MemberSession, clipId: String, reason: String) = post { dropTransfer(clipId, s, reason) }

    internal fun onSessionClosed(s: MemberSession) = post {
        sessions.remove(s)
        for (id in transfers.filterValues { s.sid in it.sessions }.keys.toList()) dropTransfer(id, s, "disconnected")
        if (online[s.peerId] === s) {
            online.remove(s.peerId)
            st.lastSeen[s.peerId] = clock()
            markPersist()
            emit(EngineEvent.PeerDown(s.peerId))
            // Reconnect soon: the lower id first, the other side a little later (fewer duplicate sessions).
            if (running && !paused && st.members[s.peerId]?.removed != true) {
                val delay = if (deviceId < s.peerId) 1_000L else 4_000L
                backoff[s.peerId] = Backoff(clock() + delay, config.dialIntervalMs)
            }
        }
    }

    private fun handleBye(s: MemberSession, reason: String) {
        if (reason == "removed" && s.groupId == group.id) {
            leave("removed", announce = false)
        }
        s.close()
    }

    private fun handleWelcome(s: MemberSession, obj: JsonObject) {
        val device = MemberRecord.fromJson(obj.obj("device"))?.copy(id = s.peerId)
        if (device == null) {
            log("session ${s.shortPeer}: malformed welcome")
            s.close()
            return
        }
        s.supportsPolicies = obj.arr("features")?.any { (it as? JsonPrimitive)?.content == "policy1" } == true
        s.supportsRekey = obj.arr("features")?.any { (it as? JsonPrimitive)?.content == "rekey1" } == true
        s.welcomed = true
        val addrs = obj.arr("addrs")?.objects()?.mapNotNull { Endpoint.fromJson(it) }.orEmpty()
        val eps = ArrayList<Endpoint>()
        val dialed = s.dialed
        if (dialed != null) {
            eps.add(dialed)
        } else if (!s.viaTailnet) {
            // Never remember the loopback address of connections relayed by the tailnet bridge (PROTOCOL §10.1).
            val host = s.conn.remoteHost
            val p = addrs.firstOrNull()?.port
            if (host != null && p != null) runCatching { Endpoint(host, p) }.getOrNull()?.let { eps.add(it) }
        }
        eps.addAll(addrs)
        rememberEndpoints(s.peerId, eps)
        mergeMembers(parseMembers(obj) + device, s)
        if (s.closed || s.groupId != group.id) return
        if (st.members[s.peerId]?.removed == true) {
            s.bye("removed")
            return
        }
        if (!registerOnline(s)) return
        backoff.remove(s.peerId)
        flushPendingLive(s)
        sendInventory(s)
    }

    private fun flushPendingLive(s: MemberSession) {
        if (pendingLive.isEmpty()) return
        val now = clock()
        pendingLive.values.removeAll { it < now }
        for (id in pendingLive.keys) {
            val c = index[id] ?: continue
            if (c.groupId == group.id) sendClip(s, c, live = true)
        }
    }

    private fun registerOnline(s: MemberSession): Boolean {
        val existing = online[s.peerId]
        if (existing != null && existing !== s && !existing.closed) {
            // PROTOCOL §4.4: keep the session whose client has the smaller deviceId.
            if (s.clientId < existing.clientId) {
                online[s.peerId] = s
                s.registered = true
                existing.registered = false
                existing.bye("duplicate")
                return true
            }
            s.bye("duplicate")
            return false
        }
        online[s.peerId] = s
        s.registered = true
        st.lastSeen[s.peerId] = clock()
        markPersist()
        val rec = st.members[s.peerId]
        if (rec != null) emit(EngineEvent.PeerUp(rec, if (s.remote) PeerRoute.REMOTE else PeerRoute.LAN))
        return true
    }

    private fun rotateAfterRemoval() {
        val message = kotlinx.serialization.json.buildJsonObject {
            put("t", JsonPrimitive("rekey")); put("previous", JsonPrimitive(group.tag)); put("groupId", JsonPrimitive(group.id))
            put("key", JsonPrimitive(B64u.encode(Crypto.random(32))))
            put("members", kotlinx.serialization.json.JsonArray(memberList().map { it.toJson() }))
        }
        applyRekey(message, null)
    }
    private fun applyRekey(obj: JsonObject, source: MemberSession?) {
        if (obj.str("previous") != group.tag || obj.str("groupId") != group.id) return
        if (source != null && online[source.peerId] !== source) return
        val key = runCatching { B64u.decode(obj.str("key") ?: "") }.getOrNull()?.takeIf { it.size == 32 } ?: return
        val members = parseMembers(obj)
        if (members.none { it.id == deviceId && !it.removed }) return
        val removed = members.filter { it.removed }.map { it.id }.toSet()
        // Persist before announcing the key. Never retain the old group key for offline recovery.
        st.groupKey = key
        markPersist(); writeNow()
        for ((id, s) in online) if (id !in removed && s !== source && s.supportsRekey) s.sendJson(obj)
        group = Group(group.id, key, group.createdAt)
        mergeMembers(members, source)
        for (s in sessions.toList()) { s.retired = true; s.bye("rekey") }
        backoff.clear()
        publish()
    }

    // ---- clips ----

    fun policyFor(id: String): studio.ivlis.nearclip.core.model.SyncPolicy = call { st.policies[id] ?: studio.ivlis.nearclip.core.model.SyncPolicy() }
    fun setPolicy(id: String, policy: studio.ivlis.nearclip.core.model.SyncPolicy) = call { st.policies[id] = policy; markPersist(); writeNow() }
    private fun canSend(c: Clip, s: MemberSession) = !c.isExpired(clock()) &&
        (c.recipients == null || (s.supportsPolicies && c.isAddressedTo(s.peerId))) &&
        (st.policies[s.peerId] ?: studio.ivlis.nearclip.core.model.SyncPolicy()).permits(c, true)
    private fun canReceive(c: Clip) = !c.isExpired(clock()) && c.isAddressedTo(deviceId) &&
        (st.policies[c.src] ?: studio.ivlis.nearclip.core.model.SyncPolicy()).permits(c, false)

    private fun produce(original: Clip): SendResult {
        val c = if (st.policies.values.any { !it.permits(original, true) }) original.copy(recipients = st.members.values
            .filter { !it.removed && it.id != deviceId && (st.policies[it.id] ?: studio.ivlis.nearclip.core.model.SyncPolicy()).permits(original, true) }
            .map { it.id }) else original
        st.newestLocalTs = c.ts
        markPersist()
        addToHistory(c)
        var sent = 0
        if (!c.localOnly) {
            for (s in online.values) {
                sendClip(s, c, live = true)
                sent++
            }
        }
        emit(EngineEvent.ClipAdded(c, live = true, apply = false, local = true, sentTo = sent))
        if (sent == 0 && !c.localOnly && config.liveRetryMs > 0) pendingLive[c.id] = clock() + config.liveRetryMs
        prune()
        return SendResult(index[c.id] ?: c, sent, tooLarge = c.localOnly)
    }

    private fun sendClip(s: MemberSession, c: Clip, live: Boolean) {
        if (c.localOnly || !canSend(c, s)) return
        if (c.isImage) {
            val f = blobFile(c)
            if (!f.isFile) return
            s.sendJson(Msg.clip(c, live))
            s.sendBlob(c.id, f, c.size ?: f.length())
        } else {
            s.sendJson(Msg.clip(c, live))
        }
    }

    private fun handleClip(s: MemberSession, obj: JsonObject): BlobAssembly? {
        val live = obj.bool("live") ?: false
        val c = Clip.fromWire(obj.obj("clip"), group.id, clock()) ?: return null
        if (!canReceive(c) || index.containsKey(c.id) || st.tombstones.containsKey(c.id)) return null
        if (c.isText) {
            acceptClip(c, live, s)
            return null
        }
        if (!syncImages) {
            s.requested.add(c.id)
            return null
        }
        return try {
            BlobAssembly(c, live, store.newTempFile()).also { if (live) startTransfer(it.clip, s) }
        } catch (e: IOException) {
            log("cannot receive image: ${e.message}")
            null
        }
    }

    private fun acceptClip(c: Clip, live: Boolean, from: MemberSession?) {
        if (!canReceive(c)) return
        transfers.remove(c.id)
        val src = st.members[c.src]
        val stored = c.copy(
            groupId = group.id, receivedAt = clock(), pinned = false,
            sourceName = src?.name ?: c.sourceName, sourcePlatform = src?.platform ?: c.sourcePlatform, localOnly = false,
        )
        addToHistory(stored)
        for (o in online.values) if (o !== from) sendClip(o, stored, live)
        // A verification code is offered by the app, not written to the clipboard on its own (PROTOCOL §6.7).
        val apply = live && c.src != deviceId && c.ts > st.newestLocalTs && !c.isCode
        if (apply) {
            st.newestLocalTs = c.ts
            markPersist()
        }
        emit(EngineEvent.ClipAdded(stored, live, apply, local = false, sentTo = 0))
        prune()
    }

    // ---- transfers in progress (PROTOCOL §6.6) ----

    private class Transfer(var from: String, var total: Long, var received: Long, val sessions: HashSet<Long>, var updated: Long)

    private fun handleIncoming(s: MemberSession, obj: JsonObject) {
        val id = normalizeId(obj.str("id")) ?: return
        if (obj.bool("cancel") == true) {
            // Only an announcement can be cancelled; once the clip message came, the chunks decide.
            if (transfers[id]?.total == 0L) dropTransfer(id, s, "cancelled")
            return
        }
        val policy = st.policies[s.peerId] ?: studio.ivlis.nearclip.core.model.SyncPolicy()
        if (!policy.receive || !policy.images || obj.str("kind") != ClipKind.IMAGE || !syncImages) return
        if (transfers.containsKey(id) || index.containsKey(id) || st.tombstones.containsKey(id)) return
        transfers[id] = Transfer(s.peerId, 0, 0, hashSetOf(s.sid), clock())
        emitTransfer(id, IncomingTransfer.State.PREPARING)
    }

    private fun startTransfer(c: Clip, s: MemberSession) {
        val size = c.size ?: return
        val t = transfers.getOrPut(c.id) { Transfer(c.src, size, 0, HashSet(), clock()) }
        t.from = c.src
        t.total = size
        t.sessions.add(s.sid)
        t.updated = clock()
        emitTransfer(c.id, IncomingTransfer.State.RECEIVING)
    }

    private fun noteProgress(id: String, received: Long, s: MemberSession) {
        val t = transfers[id] ?: return
        if (s.sid !in t.sessions || received <= t.received) return
        t.received = received
        t.updated = clock()
        emitTransfer(id, IncomingTransfer.State.RECEIVING)
    }

    /** The session will not deliver the clip; the transfer fails once no other session is bringing it. */
    private fun dropTransfer(id: String, s: MemberSession, reason: String) {
        val t = transfers[id] ?: return
        if (!t.sessions.remove(s.sid)) return
        if (t.sessions.isNotEmpty()) return
        transfers.remove(id)
        emit(EngineEvent.Transfer(IncomingTransfer(id, t.from, IncomingTransfer.State.FAILED, t.received, t.total, reason)))
    }

    private fun emitTransfer(id: String, state: IncomingTransfer.State) {
        val t = transfers[id] ?: return
        emit(EngineEvent.Transfer(IncomingTransfer(id, t.from, state, t.received, t.total)))
    }

    private fun expireTransfers(now: Long) {
        val stale = transfers.filterValues { now - it.updated > TRANSFER_TIMEOUT_MS }
        for ((id, t) in stale) {
            transfers.remove(id)
            emit(EngineEvent.Transfer(IncomingTransfer(id, t.from, IncomingTransfer.State.FAILED, t.received, t.total, "timeout")))
        }
        announced.values.removeAll { now - it > 5 * 60_000L }
    }

    private fun sendInventory(s: MemberSession) {
        val now = clock()
        val clips = history.asSequence()
            .filter { it.groupId == group.id && !it.localOnly && it.ts >= now - 7 * DAY && canSend(it, s) }
            .take(200)
            .map { Tombstone(it.id, it.ts) }
            .toList()
        val dels = st.tombstones.filter { it.value >= now - 30 * DAY }.map { Tombstone(it.key, it.value) }
        s.sendJson(Msg.inv(clips, dels))
    }

    private fun handleInventory(s: MemberSession, obj: JsonObject) {
        applyDeletes(parseIdTs(obj, "dels"), s)
        val cutoff = if (retentionDays > 0) clock() - retentionDays * DAY else 0L
        val want = parseIdTs(obj, "clips")
            .filter { !index.containsKey(it.id) && !st.tombstones.containsKey(it.id) && it.ts >= cutoff && it.id !in s.requested }
            .map { it.id }
            .distinct()
        if (want.isEmpty()) return
        s.requested.addAll(want)
        s.sendJson(Msg.want(want))
    }

    private fun handleWant(s: MemberSession, obj: JsonObject) {
        val ids = obj.arr("ids")?.mapNotNull { normalizeId((it as? JsonPrimitive)?.contentOrNull) }.orEmpty()
        for (id in ids.take(500)) {
            val c = index[id] ?: continue
            if (c.groupId != group.id || c.localOnly) continue
            if (c.isImage && (c.size ?: 0) > Clip.MAX_CATCHUP_IMAGE_BYTES) continue
            sendClip(s, c, live = false)
        }
    }

    private fun applyDeletes(items: List<Tombstone>, from: MemberSession?) {
        val fresh = ArrayList<Tombstone>()
        for (it in items) {
            if (st.tombstones.containsKey(it.id) || fresh.any { f -> f.id == it.id }) continue
            st.tombstones[it.id] = it.ts
            removeFromHistory(it.id)
            pendingLive.remove(it.id)
            fresh.add(it)
        }
        if (fresh.isEmpty()) return
        markPersist()
        for (o in online.values) if (o !== from) o.sendJson(Msg.del(fresh))
        emit(EngineEvent.ClipsDeleted(fresh.map { it.id }))
    }

    private fun parseIdTs(obj: JsonObject, key: String): List<Tombstone> =
        obj.arr(key)?.objects()?.mapNotNull { Tombstone.fromJson(it) }.orEmpty()

    // ---- members ----

    private fun parseMembers(obj: JsonObject): List<MemberRecord> =
        obj.arr("members")?.objects()?.mapNotNull { MemberRecord.fromJson(it) }.orEmpty()

    private fun mergeMembers(incoming: List<MemberRecord>, from: MemberSession?) {
        val changed = ArrayList<MemberRecord>()
        var mustLeave = false
        for (r in incoming) {
            if (r.id == deviceId) {
                if (r.removed && r.updatedAt >= ownRecord.updatedAt) mustLeave = true
                continue
            }
            val merged = MemberRecord.merge(st.members[r.id], r) ?: continue
            st.members[r.id] = merged
            changed.add(merged)
        }
        if (changed.isNotEmpty()) {
            markPersist()
            for (r in changed) if (r.removed) {
                for (s in sessions.toList()) if (s.peerId == r.id) s.bye("removed")
                st.endpoints.remove(r.id)
            }
            for ((pid, o) in online) if (o !== from && st.members[pid]?.removed != true) o.sendJson(Msg.members(changed))
            emit(EngineEvent.MembersChanged(memberList()))
        }
        if (mustLeave) leave("removed", announce = false)
    }

    private fun switchGroup(g: Group) {
        group = g
        st.groupId = g.id
        st.groupKey = g.key
        st.joinedAt = g.createdAt
        ticket = null
    }

    private fun closeAllSessions(reason: String) {
        for (s in sessions.toList()) s.bye(reason)
        online.clear()
        dialing.clear()
        backoff.clear()
    }

    private fun leave(reason: String, announce: Boolean) {
        val now = clock()
        if (announce) {
            val me = ownRecord.copy(removed = true, updatedAt = max(now, ownRecord.updatedAt + 1))
            for (o in online.values) o.sendJson(Msg.members(listOf(me)))
        }
        closeAllSessions(if (reason == "removed") "shutdown" else "leaving")
        codeInvite?.let { ci ->
            codeInvite = null
            ci.decision.completeExceptionally(IOException("left group"))
            if (ci.prompt != null) emit(EngineEvent.PairPromptDismissed)
        }
        switchGroup(Group.create(now))
        st.members.clear()
        st.members[deviceId] = freshOwnRecord(now)
        st.endpoints.clear()
        st.lastSeen.clear()
        persistDirty = true
        writeNow()
        emit(EngineEvent.Left(reason))
        emit(EngineEvent.MembersChanged(memberList()))
    }

    // =====================================================================================
    // Pairing — inviter
    // =====================================================================================

    private fun currentTicketSecret(): ByteArray? {
        val t = ticket ?: return null
        return if (t.expiresAt > clock()) t.secret else null
    }

    private fun ticketDecryptFailed(secret: ByteArray) {
        val t = ticket ?: return
        if (!t.secret.contentEquals(secret)) return
        t.failures++
        if (t.failures >= 10) {
            ticket = null
            emit(EngineEvent.TicketExpired)
        }
    }

    private fun parsePairRequest(plain: ByteArray, pid: String): MemberRecord? {
        if (plain.isEmpty() || plain[0] != Plain.TYPE_JSON) return null
        val obj = try { Wire.parseObject(plain, 1) } catch (_: Exception) { return null }
        if (obj.str("t") != "pair_request") return null
        return MemberRecord.fromJson(obj.obj("device"))?.copy(id = pid)
    }

    private fun servePairQr(conn: Conn, hello: HelloFrame, pid: String, e: ByteArray) {
        val secret = call { if (running && !paused) currentTicketSecret() else null }
        if (secret == null) { reject(conn, "no_ticket"); return }
        val n = hello.nonce
        if (n == null || n.isEmpty()) { reject(conn, "bad_request"); return }
        val eph = P256.generate()
        val z = try { P256.ecdh(eph.private, e) } catch (_: Exception) { reject(conn, "bad_request"); return }
        val ns = Crypto.random(16)
        val helloS = Hello.pairQr(deviceId, eph.publicX963, ns)
        conn.write(helloS)
        val th = Crypto.sha256(hello.raw, helloS)
        val ch = SecureChannel.fromOkm(Crypto.hkdf(z, secret, concat("nearclip-pair-qr".utf8, th), 64), isClient = false)
        val frame = conn.read()
        val plain = try { ch.open(frame) } catch (_: Exception) {
            post { ticketDecryptFailed(secret) }
            conn.close()
            return
        }
        val req = parsePairRequest(plain, pid) ?: run { conn.close(); return }
        val accept = call { inviterAccept(pid, req, secret) } ?: run { conn.close(); return }
        conn.write(ch.seal(Plain.json(accept)))
        lingerClose(conn)
    }

    private fun reserveCodePairing(conn: Conn): CodeInvite? {
        val now = clock()
        while (codeAttempts.isNotEmpty() && now - codeAttempts.first() > 60_000) codeAttempts.removeFirst()
        val cur = codeInvite
        if (cur != null && !cur.conn.closed) return null
        if (codeAttempts.size >= 10) return null
        codeAttempts.addLast(now)
        return CodeInvite(conn).also { codeInvite = it }
    }

    private fun servePairCode(conn: Conn, hello: HelloFrame, pid: String, e: ByteArray) {
        val ci = call { if (running && !paused) reserveCodePairing(conn) else null }
        if (ci == null) { reject(conn, "busy"); return }
        var timedOut = false
        var promptName: String? = hello.name
        try {
            val me = call { ownRecord }
            val eph = P256.generate()
            val z = P256.ecdh(eph.private, e)
            val ns = Crypto.random(16)
            val commit = Crypto.sha256("nearclip-commit".utf8, eph.publicX963, e, ns)
            val helloS = Hello.pairCodeInviter(deviceId, eph.publicX963, commit, me.name, me.platform)
            conn.write(helloS)
            val nonce = HelloFrame(conn.read())
            if (nonce.t != "pair_nonce") throw HandshakeError("protocol")
            val nc = nonce.nonce?.takeIf { it.isNotEmpty() && it.size <= 64 } ?: throw HandshakeError("protocol")
            conn.write(Msg.pairNonce(ns))
            val th = Crypto.sha256(hello.raw, helloS, nc, ns)
            val sas = Sas.compute(th)
            val ch = SecureChannel.fromOkm(Crypto.hkdf(z, "nearclip-pair-code".utf8, th, 64), isClient = false)
            val plain = ch.open(conn.read())
            val req = parsePairRequest(plain, pid) ?: throw HandshakeError("protocol")
            val name = req.name.ifBlank { hello.name ?: "" }
            val platform = req.platform.ifBlank { hello.platform ?: "" }
            promptName = name
            val prompt = PairPromptInfo(pid, name, platform, sas)
            val ours = call {
                if (codeInvite === ci) {
                    ci.prompt = prompt
                    emit(EngineEvent.PairPrompt(prompt))
                    true
                } else {
                    false
                }
            }
            if (!ours) return
            // Watch for the joiner giving up while the user decides.
            conn.setReadTimeout(0)
            io.execute {
                try { conn.read() } catch (_: Exception) {}
                ci.decision.completeExceptionally(IOException("joiner left"))
            }
            val accepted: Boolean? = try {
                ci.decision.get(config.pairingDecisionMs, TimeUnit.MILLISECONDS)
            } catch (_: TimeoutException) {
                timedOut = true
                null
            } catch (_: ExecutionException) {
                null
            }
            when (accepted) {
                true -> {
                    val accept = call { inviterAccept(pid, req, null) } ?: throw HandshakeError("io")
                    conn.write(ch.seal(Plain.json(accept)))
                }
                false -> conn.write(ch.seal(Plain.json(Msg.PAIR_DECLINE)))
                null -> Unit
            }
        } catch (ex: Exception) {
            log("code pairing with ${pid.take(8)} ended: ${ex.message ?: ex.javaClass.simpleName}")
        } finally {
            val name = promptName
            post {
                if (codeInvite === ci) {
                    codeInvite = null
                    if (ci.prompt != null) emit(EngineEvent.PairPromptDismissed)
                }
                if (timedOut) emit(EngineEvent.PairFailed("timeout", name))
            }
            lingerClose(conn)
        }
    }

    private fun inviterAccept(pid: String, rec: MemberRecord, ticketSecret: ByteArray?): JsonObject? {
        if (ticketSecret != null) {
            val t = ticket
            if (t == null || !t.secret.contentEquals(ticketSecret) || t.expiresAt <= clock()) return null
            ticket = null
        }
        val now = clock()
        val existing = st.members[pid]
        val r = rec.copy(id = pid, addedAt = now, updatedAt = max(now, (existing?.updatedAt ?: 0) + 1), removed = false)
        st.members[pid] = r
        markPersist()
        for ((opid, o) in online) if (opid != pid && !o.supportsRekey) o.sendJson(Msg.members(listOf(r)))
        emit(EngineEvent.MembersChanged(memberList()))
        emit(EngineEvent.Paired(group.id, pid, r.name, r.platform, joined = false))
        return Msg.pairAccept(group.id, group.key, ownRecord, memberList())
    }

    // =====================================================================================
    // Pairing — joiner
    // =====================================================================================

    private fun runJoin(op: JoinOp, targets: List<DialCandidate>, handshake: (Conn) -> PairAccept) {
        var conn: Conn? = null
        try {
            val (sock, cand) = try {
                Conn.race(targets, config.connectTimeoutMs, io)
            } catch (e: IOException) {
                throw PairError("unreachable")
            }
            conn = Conn(sock)
            op.conn = conn
            if (op.cancelled) throw PairError("cancelled")
            val accept = handshake(conn)
            post { completeJoin(op, accept, cand.address) }
        } catch (e: PairError) {
            post { finishJoin(op, e.reason) }
        } catch (e: SocketTimeoutException) {
            post { finishJoin(op, "timeout") }
        } catch (e: Exception) {
            post { finishJoin(op, if (op.reachedInviter) "io" else "unreachable") }
        } finally {
            conn?.close()
        }
    }

    private fun finishJoin(op: JoinOp, reason: String) {
        if (join !== op) return
        join = null
        emit(EngineEvent.PairFailed(reason, op.peerName))
    }

    private fun readPairResult(conn: Conn, ch: SecureChannel): PairAccept {
        val plain = try { ch.open(conn.read()) } catch (e: IOException) { throw e } catch (e: Exception) { throw PairError("protocol") }
        if (plain.isEmpty() || plain[0] != Plain.TYPE_JSON) throw PairError("protocol")
        val obj = try { Wire.parseObject(plain, 1) } catch (_: Exception) { throw PairError("protocol") }
        when (obj.str("t")) {
            "pair_accept" -> {
                val g = obj.obj("group") ?: throw PairError("protocol")
                val gid = normalizeId(g.str("id")) ?: throw PairError("protocol")
                val key = B64u.decodeOrNull(g.str("key"))?.takeIf { it.size == 32 } ?: throw PairError("protocol")
                val device = MemberRecord.fromJson(obj.obj("device")) ?: throw PairError("protocol")
                return PairAccept(gid, key, device, parseMembers(obj))
            }
            "pair_decline" -> throw PairError("declined")
            "error" -> throw PairError(obj.str("code") ?: "error")
            else -> throw PairError("protocol")
        }
    }

    private fun qrHandshake(op: JoinOp, conn: Conn, uri: PairingUri, me: MemberRecord): PairAccept {
        conn.setReadTimeout(config.handshakeTimeoutMs)
        val eph = P256.generate()
        val nc = Crypto.random(16)
        val helloC = Hello.pairQr(deviceId, eph.publicX963, nc)
        conn.write(helloC)
        val resp = HelloFrame(conn.read())
        if (resp.t == "error") throw PairError(resp.code ?: "error")
        op.reachedInviter = true
        if (resp.t != "hello" || resp.mode != "pair-qr") throw PairError("protocol")
        if (resp.version != 1L) throw PairError("version")
        val pid = resp.id ?: throw PairError("protocol")
        if (pid != uri.inviterId) throw PairError("wrong_device")
        val e = resp.ephemeral ?: throw PairError("protocol")
        val z = try { P256.ecdh(eph.private, e) } catch (_: Exception) { throw PairError("protocol") }
        val th = Crypto.sha256(helloC, resp.raw)
        val ch = SecureChannel.fromOkm(Crypto.hkdf(z, uri.ticket, concat("nearclip-pair-qr".utf8, th), 64), isClient = true)
        conn.write(ch.seal(Plain.json(Msg.pairRequest(me))))
        conn.setReadTimeout(30_000)
        return readPairResult(conn, ch)
    }

    private fun codeHandshake(op: JoinOp, conn: Conn, me: MemberRecord): PairAccept {
        conn.setReadTimeout(config.handshakeTimeoutMs)
        val eph = P256.generate()
        val nc = Crypto.random(16)
        val helloC = Hello.pairCodeJoiner(deviceId, eph.publicX963, me.name, me.platform)
        conn.write(helloC)
        val resp = HelloFrame(conn.read())
        if (resp.t == "error") throw PairError(resp.code ?: "error")
        op.reachedInviter = true
        if (resp.t != "hello" || resp.mode != "pair-code") throw PairError("protocol")
        if (resp.version != 1L) throw PairError("version")
        val pid = resp.id ?: throw PairError("protocol")
        if (pid == deviceId) throw PairError("self")
        val e = resp.ephemeral ?: throw PairError("protocol")
        val commit = resp.commit?.takeIf { it.size == 32 } ?: throw PairError("protocol")
        resp.name?.takeIf { it.isNotBlank() }?.let { op.peerName = it }
        conn.write(Msg.pairNonce(nc))
        val nonce = HelloFrame(conn.read())
        if (nonce.t == "error") throw PairError(nonce.code ?: "error")
        if (nonce.t != "pair_nonce") throw PairError("protocol")
        val ns = nonce.nonce?.takeIf { it.isNotEmpty() } ?: throw PairError("protocol")
        val expected = Crypto.sha256("nearclip-commit".utf8, e, eph.publicX963, ns)
        if (!MessageDigest.isEqual(expected, commit)) throw PairError("commit")
        val z = try { P256.ecdh(eph.private, e) } catch (_: Exception) { throw PairError("protocol") }
        val th = Crypto.sha256(helloC, resp.raw, nc, ns)
        val sas = Sas.compute(th)
        op.sas = sas
        post { if (join === op) emit(EngineEvent.PairSas(sas, resp.name ?: "", resp.platform ?: "")) }
        val ch = SecureChannel.fromOkm(Crypto.hkdf(z, "nearclip-pair-code".utf8, th, 64), isClient = true)
        conn.write(ch.seal(Plain.json(Msg.pairRequest(me))))
        conn.setReadTimeout((config.pairingDecisionMs + 10_000).toInt())
        return readPairResult(conn, ch)
    }

    private fun completeJoin(op: JoinOp, accept: PairAccept, ep: Endpoint) {
        if (join !== op) return
        join = null
        val now = clock()
        val inviter = accept.device.id
        // Tell the old group we are gone, so it does not keep showing this device.
        if (st.members.values.any { it.id != deviceId && !it.removed }) {
            val gone = ownRecord.copy(removed = true, updatedAt = max(now, ownRecord.updatedAt + 1))
            for (o in online.values) o.sendJson(Msg.members(listOf(gone)))
        }
        closeAllSessions("leaving")
        switchGroup(Group(accept.groupId, accept.key, now))
        st.members.clear()
        for (r in accept.members + accept.device) {
            val cur = st.members[r.id]
            if (cur == null || r.updatedAt > cur.updatedAt || (r.updatedAt == cur.updatedAt && r.removed)) st.members[r.id] = r
        }
        val mine = st.members[deviceId]
        st.members[deviceId] = (mine ?: freshOwnRecord(now)).copy(
            name = st.deviceName, platform = config.platform, model = config.model, app = config.appVersion,
            removed = false, updatedAt = max(now, (mine?.updatedAt ?: 0) + 1),
        )
        st.endpoints.clear()
        st.lastSeen.clear()
        st.endpoints[inviter] = mutableListOf(ep)
        persistDirty = true
        writeNow()
        emit(EngineEvent.MembersChanged(memberList()))
        emit(EngineEvent.Paired(group.id, inviter, accept.device.name, accept.device.platform, joined = true))
        dialMember(inviter, dialCandidates(inviter))
        for (d in discovered.values.toList()) if (d.groupTag == group.tag && d.id != inviter) considerDial(d)
    }

    companion object {
        const val DAY = 86_400_000L
        const val HOUR = 3_600_000L
        const val SESSION_READ_TIMEOUT_MS = 60_000
        /** A transfer that makes no progress for this long is reported as failed (PROTOCOL §6.6). */
        const val TRANSFER_TIMEOUT_MS = 60_000L
    }
}
