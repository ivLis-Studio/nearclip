package studio.ivlis.nearclip.runtime

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import studio.ivlis.nearclip.BuildConfig
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.engine.DiscoveredService
import studio.ivlis.nearclip.core.engine.EngineConfig
import studio.ivlis.nearclip.core.engine.EngineEvent
import studio.ivlis.nearclip.core.engine.EngineSnapshot
import studio.ivlis.nearclip.core.engine.IncomingTransfer
import studio.ivlis.nearclip.core.engine.NearclipEngine
import studio.ivlis.nearclip.core.engine.SendResult
import studio.ivlis.nearclip.core.engine.TicketInfo
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.ContentKey
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.model.Platform
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.core.store.FileStore
import studio.ivlis.nearclip.core.tailnet.TailnetOptions
import studio.ivlis.nearclip.service.SyncService
import java.io.File
import kotlin.math.max

sealed interface SendOutcome {
    data class Sent(val peers: Int, val members: Int) : SendOutcome
    data object Paused : SendOutcome
    data object Empty : SendOutcome
    data object Sensitive : SendOutcome
    data object AlreadySynced : SendOutcome
    data object TooLarge : SendOutcome
    data object Unreadable : SendOutcome
    data object ImagesOff : SendOutcome
    data object Failed : SendOutcome
}

sealed interface UiMessage {
    data class CopiedFrom(val name: String) : UiMessage
    data class Send(val outcome: SendOutcome) : UiMessage
    data class Deleted(val ids: Set<String>) : UiMessage
    data object Removed : UiMessage
    data class ImageSaved(val ok: Boolean) : UiMessage
    /** A large image that was shown arriving did not make it (PROTOCOL §6.6). */
    data class TransferFailed(val name: String) : UiMessage
    /** A verification code arrived from another device (PROTOCOL §6.7): "Copy it?". */
    data class CodeArrived(val id: String, val name: String, val code: String, val expiresAt: Long = System.currentTimeMillis() + 180_000) : UiMessage
}

sealed interface PairingUi {
    data object Idle : PairingUi
    /** A nearclip://pair link was opened: ask before joining (a link can come from anywhere). */
    data class ConfirmLink(val uri: PairingUri) : PairingUi
    data class Joining(val peerName: String, val byCode: Boolean) : PairingUi
    /** Joiner side of code pairing: show the code and wait for the other device. */
    data class CodeConfirm(val peerName: String, val sas: String) : PairingUi
    data class Success(val peerName: String, val peerPlatform: String) : PairingUi
    data class Failed(val reason: String, val peerName: String) : PairingUi
}

/**
 * App-wide runtime: owns the engine and connects it to Android (clipboard, DNS-SD, notifications, the
 * foreground service, settings). The engine runs while any UI is visible or while the service runs.
 */
class Nearclip private constructor(val app: Application) {
    val settings = SettingsStore(app)
    val clipboard = ClipboardBridge(app)
    val engine: NearclipEngine
    private val discovery: Discovery
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _messages = MutableSharedFlow<UiMessage>(extraBufferCapacity = 16)
    val messages: SharedFlow<UiMessage> = _messages.asSharedFlow()
    private val _pairing = MutableStateFlow<PairingUi>(PairingUi.Idle)
    val pairing: StateFlow<PairingUi> = _pairing.asStateFlow()
    private val _pendingDeletes = MutableStateFlow<Set<String>>(emptySet())
    val pendingDeletes: StateFlow<Set<String>> = _pendingDeletes.asStateFlow()
    private val deleteJobs = HashMap<Set<String>, Job>()
    /** The Tailscale sign-in page was opened and the node is not running yet. */
    private val _tailnetSigningIn = MutableStateFlow(false)
    val tailnetSigningIn: StateFlow<Boolean> = _tailnetSigningIn.asStateFlow()
    private var networkJob: Job? = null

    /** Opt-in "Bring copies into Nearclip instantly" (Shizuku on Android 10+). */
    val capture: InstantCapture
    private var captureWait: Job? = null
    /** "Allow" was tapped in the setup sheet: turn the feature on once Shizuku grants it. */
    private var enableWhenAllowed = false

    /** "Send verification codes to my devices" (notification access). */
    val codes: CodeForwarding
    /** Codes from other devices offered already: one "Copy it?" each. */
    private val offeredCodes = HashSet<String>()

    /** Live images arriving from other devices (PROTOCOL §6.6), oldest first; main thread. */
    private val transfers = LinkedHashMap<String, IncomingTransfer>()
    /** Transfers still running 0.3 s after they started: quick ones go straight to "Copied from …". */
    private val visibleTransfers = HashSet<String>()
    private val _incoming = MutableStateFlow<IncomingTransfer?>(null)
    /** The image shown arriving: a card on top of history, or a progress notification while Nearclip is closed. */
    val incoming: StateFlow<IncomingTransfer?> = _incoming.asStateFlow()

    /** Started MainActivity instances; a counter, because an old instance can stop after a new one started. */
    private var visibleActivities = 0
    val uiVisible: Boolean get() = visibleActivities > 0
    private var processVisible = false
    @Volatile var serviceRunning = false
        private set
    private var stopJob: Job? = null
    private var openWindowUntil = 0L
    private var openSentStamp = 0L

    /**
     * What the clipboard holds as far as Nearclip knows ([ContentKey]: the text, or an image file), its timestamp when
     * known, and when that was learned. The same content put there again is not a new copy, and a clip that is there
     * already is not written again (DESIGN §4.3): Link to Windows, for one, puts back what Nearclip just wrote.
     */
    @Volatile private var clipKey: String? = null
    @Volatile private var clipKeyStamp: Long? = null
    @Volatile private var clipKeyAt = 0L

    init {
        val s = settings.value
        // Debug builds only: files/tailnet-control.txt points the embedded node at a test control server
        // (tailnet/out/nctestcontrol); written with `adb shell run-as` by tools/acceptance/android.py.
        val testControl = if (BuildConfig.DEBUG) {
            File(app.filesDir, "tailnet-control.txt").takeIf { it.isFile }?.readText()?.trim()?.takeIf { it.isNotEmpty() }
        } else null
        engine = NearclipEngine(
            FileStore(File(app.filesDir, "nearclip"), KeystoreKeyProtector()),
            EngineConfig(
                platform = Platform.ANDROID,
                defaultName = DeviceInfo.defaultName(app),
                model = DeviceInfo.model,
                appVersion = BuildConfig.VERSION_NAME,
                retentionDays = s.retentionDays,
                syncImages = s.syncImages,
                liveRetryMs = 60_000,
                // Remote connection: embedded Tailscale node; Android reports its interfaces (tailscale#17311).
                tailnet = TailnetOptions(File(app.filesDir, "tailnet"), controlUrl = testControl, testMode = testControl != null,
                    logPath = if (BuildConfig.DEBUG) File(app.filesDir, "tailnet.log").path else null,
                    netInfo = { NetInfo.json(app) }),
            ),
        )
        engine.setPaused(s.paused)
        engine.setRemoteEnabled(s.remoteEnabled)
        discovery = Discovery(app, engine)
        capture = InstantCapture(app, onChanged = ::onClipboardChanged, onPermissionResult = ::onCapturePermission, log = { engine.log(it) })
        codes = CodeForwarding(this)
        Notifications.ensureChannels(app)
        codes.refresh()
        scope.launch { engine.events.collect { onEvent(it) } }
        scope.launch {
            engine.state.combine(settings.state) { snap, _ -> advert(snap) }.distinctUntilChanged().collect { discovery.update(it) }
        }
        scope.launch { settings.state.map { it.retentionDays }.distinctUntilChanged().collect { engine.setRetention(it) } }
        scope.launch { settings.state.map { it.syncImages }.distinctUntilChanged().collect { engine.setSyncImages(it) } }
        scope.launch { settings.state.collect { updateCaptureWanted() } }
        // Wi-Fi ↔ mobile data, new addresses: redial at once and let the embedded node re-bind (PROTOCOL §4.5, §10.4).
        NetInfo.watch(app) {
            scope.launch {
                networkJob?.cancel()
                networkJob = launch {
                    delay(1_000)
                    val info = withContext(Dispatchers.IO) { NetInfo.json(app) }
                    engine.networkChanged(info)
                }
            }
        }
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            LifecycleEventObserver { _, event ->
                when (event) {
                    Lifecycle.Event.ON_START -> { processVisible = true; updateRunning() }
                    Lifecycle.Event.ON_STOP -> { processVisible = false; updateRunning() }
                    else -> Unit
                }
            },
        )
    }

    private fun advert(snap: EngineSnapshot): Discovery.Advert? =
        if (!snap.running || snap.paused || snap.port <= 0) null
        else Discovery.Advert(snap.deviceName, snap.deviceId, Platform.ANDROID, snap.groupTag, snap.pairingMode, snap.port)

    // ---------------------------------------------------------------- lifecycle

    private fun updateRunning() {
        updateCaptureWanted()
        if (processVisible || serviceRunning) {
            stopJob?.cancel()
            stopJob = null
            scope.launch(Dispatchers.IO) { engine.start() }
        } else if (stopJob == null) {
            stopJob = scope.launch {
                delay(20_000)
                withContext(Dispatchers.IO) { engine.stop() }
                stopJob = null
            }
        }
    }

    fun onServiceStarted() {
        serviceRunning = true
        updateRunning()
    }

    fun onServiceStopped() {
        serviceRunning = false
        updateRunning()
    }

    /** Starts or stops the foreground service to match "Stay connected in the background". */
    fun ensureService() {
        val s = settings.value
        val want = s.stayConnected && s.onboardingDone
        val intent = Intent(app, SyncService::class.java)
        if (want && !serviceRunning) {
            try { ContextCompat.startForegroundService(app, intent) } catch (e: Exception) { engine.log("cannot start service: ${e.message}") }
        } else if (!want && serviceRunning) {
            app.stopService(intent)
        }
    }

    fun setUiVisible(visible: Boolean) {
        visibleActivities = (visibleActivities + if (visible) 1 else -1).coerceAtLeast(0)
        updateCaptureWanted()
        if (visible) Notifications.cancelPairPrompt(app) else if (!uiVisible) flushDeletes()
        // The card in the app and the notification outside it show the same transfer.
        val shown = _incoming.value
        if (uiVisible) Notifications.cancelTransfer(app) else if (shown != null) Notifications.transfer(app, deviceName(shown.from), shown)
    }

    // ---------------------------------------------------------------- engine events

    private fun onEvent(e: EngineEvent) {
        when (e) {
            is EngineEvent.ClipAdded -> if (!e.local) onIncoming(e)
            is EngineEvent.Transfer -> onTransfer(e.transfer)
            is EngineEvent.PairPrompt -> if (!uiVisible) Notifications.showPairPrompt(app, e.prompt)
            is EngineEvent.PairPromptDismissed -> Notifications.cancelPairPrompt(app)
            is EngineEvent.PairSas -> {
                val name = e.peerName.ifBlank { (pairing.value as? PairingUi.Joining)?.peerName ?: "" }
                _pairing.value = PairingUi.CodeConfirm(name, e.sas)
            }
            is EngineEvent.Paired -> {
                Notifications.cancelPairPrompt(app)
                _pairing.value = PairingUi.Success(e.peerName, e.peerPlatform)
            }
            is EngineEvent.PairFailed -> {
                val cur = pairing.value
                if (cur is PairingUi.Joining || cur is PairingUi.CodeConfirm) {
                    val name = e.peerName ?: when (cur) {
                        is PairingUi.Joining -> cur.peerName
                        is PairingUi.CodeConfirm -> cur.peerName
                    }
                    _pairing.value = if (e.reason == "cancelled") PairingUi.Idle else PairingUi.Failed(e.reason, name)
                }
            }
            is EngineEvent.Left -> if (e.reason == "removed") _messages.tryEmit(UiMessage.Removed)
            is EngineEvent.TailnetChanged -> if (e.status.isRunning || e.status.state == "off") _tailnetSigningIn.value = false
            else -> Unit
        }
    }

    private fun onIncoming(e: EngineEvent.ClipAdded) {
        if (e.clip.isCode) {
            offerCode(e.clip, e.live)
            return
        }
        val wasShown = transfers.containsKey(e.clip.id) && endTransfer(e.clip.id)
        val copied = applyIncoming(e)
        if (wasShown && !uiVisible) notifyArrived(e.clip, copied)
        updateIncoming()
    }

    /**
     * A verification code from another device (PROTOCOL §6.7): offered with "Copy it?" — a snackbar in the app, a
     * notification outside it — and never copied on its own. One that arrives later (catch-up) is offered while it
     * can still be used.
     */
    private fun offerCode(clip: Clip, live: Boolean) {
        if (settings.value.paused || clip.isExpired(System.currentTimeMillis()) || clip.src == engine.state.value.deviceId) return
        if (!live && System.currentTimeMillis() - clip.ts > CODE_OFFER_MS) return
        val code = clip.text ?: return
        if (!offeredCodes.add(clip.id) || holds(clip)) return
        val name = sourceName(clip)
        if (uiVisible) _messages.tryEmit(UiMessage.CodeArrived(clip.id, name, code, clip.ts + CODE_OFFER_MS))
        else Notifications.code(app, clip.id, name, code, clip.ts + CODE_OFFER_MS)
    }

    /** "Copy" on a code offer: to this phone's clipboard only. */
    fun copyCode(id: String): Boolean {
        Notifications.cancelCode(app)
        val clip = engine.state.value.history.firstOrNull { it.id == id } ?: return false
        if (clip.isExpired(System.currentTimeMillis())) return false
        return holds(clip) || applyToClipboard(clip, announce = false)
    }

    /** Turns the progress notification into "Copied from …" right away; the thumbnail follows once it is decoded. */
    private fun notifyArrived(clip: Clip, copied: Boolean) {
        val name = sourceName(clip)
        val title = app.getString(if (copied) R.string.copied_from else R.string.image_from, name)
        val text = if (copied) imageLine(clip) else app.getString(R.string.saved_to_history)
        Notifications.transferDone(app, clip.id, title, text, null)
        val file = engine.blobFile(clip)
        scope.launch {
            val thumb = withContext(Dispatchers.IO) { ImageTools.thumbnail(file, 256) } ?: return@launch
            if (Notifications.transferDoneFor == clip.id && !uiVisible) Notifications.transferDone(app, clip.id, title, text, thumb)
        }
    }

    /** Applies a clip from another device to the clipboard when the settings say so; true when it was copied. */
    private fun applyIncoming(e: EngineEvent.ClipAdded): Boolean {
        val s = settings.value
        if (s.paused) return false
        // Already on the clipboard (copied here too, or put back by another sync app): not written again, no message.
        if (e.apply && s.autoApply) return holds(e.clip) || applyToClipboard(e.clip, announce = true)
        // "Copy the newest clip when Nearclip opens": catch-up that arrives right after opening counts too.
        if (!e.live && s.copyNewestOnOpen && System.currentTimeMillis() < openWindowUntil) {
            val snap = engine.state.value
            val clip = e.clip
            if (clip.src == snap.deviceId || clip.localOnly) return false
            if (System.currentTimeMillis() - clip.ts > NEWEST_WINDOW_MS) return false
            if (clip.ts <= maxOf(settings.lastAppliedTs, newestLocalTs(snap), openSentStamp)) return false
            return holds(clip) || applyToClipboard(clip, announce = true)
        }
        return false
    }

    private fun imageLine(c: Clip): String {
        val w = c.w ?: 0
        val h = c.h ?: 0
        return if (w > 0 && h > 0) app.getString(R.string.image_title_size, w, h) else app.getString(R.string.image_title)
    }

    // ---------------------------------------------------------------- images on their way (PROTOCOL §6.6)

    private fun onTransfer(t: IncomingTransfer) {
        if (!settings.value.syncImages) return
        if (t.state == IncomingTransfer.State.FAILED) {
            val wasShown = endTransfer(t.id)
            if (wasShown && t.reason != "cancelled") {
                val name = deviceName(t.from)
                if (uiVisible) _messages.tryEmit(UiMessage.TransferFailed(name))
                else Notifications.transferFailed(app, name)
            }
            updateIncoming()
            return
        }
        val isNew = !transfers.containsKey(t.id)
        transfers[t.id] = t
        if (!isNew) {
            updateIncoming()
            return
        }
        scope.launch {
            delay(300)
            if (transfers.containsKey(t.id)) {
                visibleTransfers.add(t.id)
                updateIncoming()
            }
        }
    }

    /** Forgets a transfer; returns whether it was the one shown. */
    private fun endTransfer(id: String): Boolean {
        val wasShown = _incoming.value?.id == id
        transfers.remove(id)
        visibleTransfers.remove(id)
        return wasShown
    }

    private fun updateIncoming() {
        val next = transfers.keys.lastOrNull { it in visibleTransfers }?.let { transfers[it] }
        val before = _incoming.value
        if (next == before) return
        _incoming.value = next
        if (uiVisible) return
        if (next != null) Notifications.transfer(app, deviceName(next.from), next)
        else if (before != null && transfers.isEmpty()) Notifications.cancelTransferProgress(app)
    }

    private fun deviceName(id: String): String =
        engine.state.value.members.firstOrNull { it.id == id }?.name?.takeIf { it.isNotBlank() } ?: app.getString(R.string.unknown_device)

    private fun newestLocalTs(snap: EngineSnapshot): Long =
        snap.history.firstOrNull { it.src == snap.deviceId }?.ts ?: 0L

    // ---------------------------------------------------------------- clipboard

    fun sourceName(clip: Clip, snap: EngineSnapshot = engine.state.value): String =
        if (clip.src == snap.deviceId) thisDeviceLabel()
        else snap.members.firstOrNull { it.id == clip.src }?.name ?: clip.sourceName ?: app.getString(R.string.unknown_device)

    fun thisDeviceLabel(): String = app.getString(if (DeviceInfo.isTablet(app)) R.string.this_tablet else R.string.this_phone)

    /** Writes a clip to the system clipboard (marked as ours, so it is never sent back). */
    fun applyToClipboard(clip: Clip, announce: Boolean): Boolean {
        if (clip.isExpired(System.currentTimeMillis())) return false
        val ok = when {
            clip.isText -> clip.text?.let { clipboard.writeText(it, clip.id, clip.isCode) } ?: false
            clip.isImage -> clipboard.writeImage(engine.blobFile(clip), clip.id)
            else -> false
        }
        if (!ok) return false
        if (clip.ts > settings.lastAppliedTs) settings.lastAppliedTs = clip.ts
        val stamp = clipboard.stamp()
        stamp?.let { settings.lastClipboardStamp = it }
        remember(ContentKey.of(clip), stamp)
        if (clip.isCode) scope.launch {
            delay((clip.ts + CODE_OFFER_MS - System.currentTimeMillis()).coerceAtLeast(0))
            clipboard.clearCode(clip.id, clip.text ?: "", stamp)
        }
        if (announce && uiVisible) _messages.tryEmit(UiMessage.CopiedFrom(sourceName(clip)))
        return true
    }

    private fun remember(key: String?, stamp: Long?) {
        clipKey = key
        clipKeyStamp = stamp
        clipKeyAt = System.currentTimeMillis()
    }

    /**
     * Whether the clipboard holds [clip] already. Android hides the clipboard from apps in the background, so without a
     * timestamp to check, what Nearclip knows counts for a minute.
     */
    private fun holds(clip: Clip): Boolean {
        val key = ContentKey.of(clip) ?: return false
        if (key != clipKey) return false
        val stamp = clipboard.stamp()
        val known = clipKeyStamp
        return if (stamp != null && known != null) stamp == known else System.currentTimeMillis() - clipKeyAt < 60_000
    }

    /** Called when MainActivity gains focus after coming to the foreground (DESIGN §4.3 / §4.6 mobile settings). */
    fun onAppOpened() {
        val s = settings.value
        openWindowUntil = System.currentTimeMillis() + 15_000
        if (!s.onboardingDone || s.paused) return
        val snap = engine.state.value
        val stamp = clipboard.stamp() ?: 0L
        val changed = stamp != 0L && stamp != settings.lastClipboardStamp
        val local = if (changed && s.sendOnOpen) clipboard.read() else null
        if (changed) settings.lastClipboardStamp = stamp
        val now = System.currentTimeMillis()
        val remote = snap.history.firstOrNull { it.groupId == snap.groupId && !it.localOnly && it.src != snap.deviceId }
            ?.takeIf { now - it.receivedAt <= NEWEST_WINDOW_MS && it.ts > maxOf(settings.lastAppliedTs, newestLocalTs(snap)) }
        if (local != null && !local.ours && !local.sensitive && (remote == null || stamp >= remote.receivedAt)) {
            openSentStamp = maxOf(stamp, now)
            scope.launch {
                val outcome = send(local)
                if (outcome is SendOutcome.Sent) _messages.tryEmit(UiMessage.Send(outcome))
            }
        } else if (remote != null && remote.isCode) {
            // A code is offered, not copied (it may have come while Nearclip was closed).
            offerCode(remote, live = false)
        } else if (remote != null && s.copyNewestOnOpen) {
            applyToClipboard(remote, announce = true)
        }
    }

    /** "Send clipboard": reads the clipboard (caller must have window focus) and sends it. */
    suspend fun sendFromClipboard(): SendOutcome {
        if (settings.value.paused) return SendOutcome.Paused
        val content = clipboard.read() ?: return SendOutcome.Empty
        settings.lastClipboardStamp = content.stamp
        if (content.sensitive) return SendOutcome.Sensitive
        if (content.ours) return SendOutcome.AlreadySynced
        return send(content)
    }

    /** Sends what was read from the clipboard, unless it is what Nearclip knows the clipboard held already. */
    suspend fun send(content: ClipboardBridge.Content): SendOutcome = when (content) {
        is ClipboardBridge.Text -> {
            val key = ContentKey.text(content.text)
            val again = key == clipKey
            remember(key, content.stamp)
            if (again) SendOutcome.AlreadySynced else sendText(content.text)
        }
        is ClipboardBridge.Image -> sendImage(content.uri, clipboardStamp = content.stamp)
    }

    // ---------------------------------------------------------------- instant capture

    /** Something was copied somewhere on the phone while instant capture listens. */
    private fun onClipboardChanged() {
        captureWait?.cancel()
        captureWait = scope.launch {
            delay(150) // some apps set a clip twice in a row
            scope.launch { captureCopy() }
        }
    }

    /** Sends new text from the clipboard right away; photos and files are left to sharing or opening Nearclip. */
    private suspend fun captureCopy() {
        val s = settings.value
        if (!s.instantCapture || s.paused || !s.onboardingDone || !(serviceRunning || uiVisible)) return
        val change = capture.read(settings.lastClipboardStamp) ?: return
        val current = settings.value
        if (!current.instantCapture || current.paused || !(serviceRunning || uiVisible)) return
        // Opening Nearclip may have sent it meanwhile: onAppOpened updates the stamp on this (main) thread.
        if (change.stamp == settings.lastClipboardStamp) return
        when (change) {
            is InstantCapture.Change.Copied -> {
                settings.lastClipboardStamp = change.stamp
                send(ClipboardBridge.Text(change.text, change.stamp, ours = false, sensitive = false))
            }
            is InstantCapture.Change.Skipped -> {
                settings.lastClipboardStamp = change.stamp
                // Nearclip's own clip: still what it wrote, now with its timestamp. A sensitive one: not known.
                if (change.ours) clipKeyStamp = change.stamp else remember(null, change.stamp)
            }
            is InstantCapture.Change.NotText -> remember(null, change.stamp)
        }
    }

    /** Turning it on also keeps Nearclip connected in the background, which it needs. */
    fun setInstantCapture(on: Boolean) {
        settings.update { it.copy(instantCapture = on, stayConnected = it.stayConnected || on) }
        updateCaptureWanted()
        ensureService()
    }

    private fun updateCaptureWanted() {
        val s = settings.value
        capture.setWanted(s.instantCapture && !s.paused && s.onboardingDone && (serviceRunning || uiVisible))
    }

    /** Asks Shizuku to allow Nearclip; the feature turns on when it does. */
    fun allowInstantCapture() {
        enableWhenAllowed = true
        capture.requestPermission()
    }

    private fun onCapturePermission(granted: Boolean) {
        if (granted && enableWhenAllowed) setInstantCapture(true)
        enableWhenAllowed = false
        codes.onShizukuPermission(granted)
    }

    suspend fun sendText(text: String): SendOutcome = withContext(Dispatchers.IO) {
        if (text.isBlank()) return@withContext SendOutcome.Empty
        if (settings.value.paused) return@withContext SendOutcome.Paused
        val snap = engine.state.value
        val newest = snap.history.firstOrNull { it.groupId == snap.groupId }
        // The newest clip already: it is on the other devices (DESIGN §4.3).
        if (newest != null && newest.isText && System.currentTimeMillis() - newest.receivedAt < NEWEST_WINDOW_MS &&
            ContentKey.of(newest) == ContentKey.text(text)
        ) {
            return@withContext SendOutcome.AlreadySynced
        }
        engine.start()
        awaitPeers()
        outcome(engine.sendText(text))
    }

    /**
     * A verification code found in a message (CodeForwarding): to the other devices, which offer to copy it. The engine
     * runs for it even when nothing else needs it, and stops again later (see updateRunning).
     */
    suspend fun sendCode(code: String): SendOutcome {
        if (settings.value.paused) return SendOutcome.Paused
        if (engine.state.value.otherMembers.isEmpty()) return SendOutcome.Sent(0, 0)
        stopJob?.cancel()
        stopJob = null
        val result = withContext(Dispatchers.IO) {
            engine.start()
            awaitPeers()
            outcome(engine.sendText(code, otp = true))
        }
        updateRunning()
        return result
    }

    fun setForwardCodes(on: Boolean) {
        settings.update { it.copy(forwardCodes = on, codesHidden = it.codesHidden && on) }
        codes.refresh()
    }

    /** [clipboardStamp]: the image was read from the clipboard (then the clipboard is known to hold it). */
    suspend fun sendImage(uri: Uri, clipboardStamp: Long? = null): SendOutcome = withContext(Dispatchers.IO) {
        if (settings.value.paused) return@withContext SendOutcome.Paused
        if (!settings.value.syncImages) return@withContext SendOutcome.ImagesOff
        engine.start()
        // The other devices show "Receiving…" while the image is read and encoded (PROTOCOL §6.6).
        val announced = if (engine.state.value.onlineCount > 0) engine.announceImage() else null
        val img = ImageTools.prepare(app, uri)
        if (img == null) {
            announced?.let { engine.cancelImage(it) }
            return@withContext SendOutcome.Unreadable
        }
        val file = ContentKey.file(img.bytes)
        val again = clipboardStamp != null && file == clipKey
        if (clipboardStamp != null) remember(file, clipboardStamp)
        // What the clipboard held already, or the newest clip: it is on the other devices (DESIGN §4.3).
        val snap = engine.state.value
        val newest = snap.history.firstOrNull { it.groupId == snap.groupId }
        if (again || newest != null && newest.isImage && System.currentTimeMillis() - newest.receivedAt < NEWEST_WINDOW_MS &&
            ContentKey.of(newest) == file
        ) {
            announced?.let { engine.cancelImage(it) }
            return@withContext SendOutcome.AlreadySynced
        }
        awaitPeers()
        outcome(engine.sendImage(img.bytes, img.mime, img.width, img.height, id = announced))
    }

    private suspend fun awaitPeers() {
        val snap = engine.state.value
        if (snap.onlineCount == 0 && snap.otherMembers.isNotEmpty() && !snap.paused) {
            withTimeoutOrNull(2_500) { engine.state.first { it.onlineCount > 0 } }
        }
    }

    private fun outcome(r: SendResult): SendOutcome = when {
        r.paused -> SendOutcome.Paused
        r.tooLarge -> SendOutcome.TooLarge
        r.clip == null -> SendOutcome.Failed
        else -> SendOutcome.Sent(r.peers, engine.state.value.otherMembers.size)
    }

    // ---------------------------------------------------------------- history actions

    /** Pins or unpins a history row: every copy of its content (DESIGN §4.4). */
    fun setPinned(ids: Collection<String>, pinned: Boolean) {
        for (id in ids) engine.setPinned(id, pinned)
    }

    /** Hides the clips now and deletes them everywhere after the undo window (DESIGN §4.4: 4 s). */
    fun deleteWithUndo(ids: Set<String>) {
        if (ids.isEmpty()) return
        _pendingDeletes.update { it + ids }
        _messages.tryEmit(UiMessage.Deleted(ids))
        deleteJobs[ids] = scope.launch {
            delay(4_500)
            commitDelete(ids)
        }
    }

    fun undoDelete(ids: Set<String>) {
        deleteJobs.remove(ids)?.cancel()
        _pendingDeletes.update { it - ids }
    }

    private suspend fun commitDelete(ids: Set<String>) {
        deleteJobs.remove(ids)
        engine.delete(ids)
        withTimeoutOrNull(3_000) { engine.state.first { snap -> snap.history.none { it.id in ids } } }
        _pendingDeletes.update { it - ids }
    }

    private fun flushDeletes() {
        for ((ids, job) in deleteJobs.toList()) {
            job.cancel()
            scope.launch { commitDelete(ids) }
        }
    }

    fun saveImage(clip: Clip) {
        scope.launch {
            val ok = withContext(Dispatchers.IO) {
                val ext = if (clip.mime == "image/jpeg") "jpg" else "png"
                ImageTools.saveToGallery(app, engine.blobFile(clip), clip.mime ?: "image/png", "Nearclip-" + clip.id.take(8) + "." + ext)
            }
            _messages.tryEmit(UiMessage.ImageSaved(ok))
        }
    }

    // ---------------------------------------------------------------- pairing

    fun openPairingLink(uri: PairingUri) {
        _pairing.value = PairingUi.ConfirmLink(uri)
    }

    fun joinWithUri(uri: PairingUri) {
        _pairing.value = PairingUi.Joining(uri.name, byCode = false)
        scope.launch(Dispatchers.IO) {
            engine.start()
            engine.joinWithUri(uri)
        }
    }

    fun pairWithNearby(d: DiscoveredService) {
        _pairing.value = PairingUi.Joining(d.name, byCode = true)
        engine.pairWithCode(d.endpoints, d.name)
    }

    fun pairWithAddress(endpoint: Endpoint) {
        _pairing.value = PairingUi.Joining(endpoint.toString(), byCode = true)
        engine.pairWithCode(listOf(endpoint), null)
    }

    fun cancelPairing() {
        engine.cancelJoin()
        _pairing.value = PairingUi.Idle
    }

    fun dismissPairing() {
        _pairing.value = PairingUi.Idle
    }

    suspend fun createTicket(): TicketInfo = withContext(Dispatchers.IO) {
        engine.start()
        engine.createTicket()
    }

    // ---------------------------------------------------------------- settings

    fun setPaused(paused: Boolean) {
        settings.update { it.copy(paused = paused) }
        engine.setPaused(paused)
    }

    fun setStayConnected(on: Boolean) {
        settings.update { it.copy(stayConnected = on) }
        ensureService()
    }

    // ---------------------------------------------------------------- remote connection (DESIGN §4.7)

    val remoteAvailable: Boolean get() = engine.tailnetAvailable

    fun setRemoteEnabled(on: Boolean) {
        settings.update { it.copy(remoteEnabled = on) }
        engine.setRemoteEnabled(on)
        if (!on) _tailnetSigningIn.value = false
    }

    /** Opens Tailscale's sign-in page with [open] (asks the node for one first when needed). */
    fun signInToTailscale(open: (String) -> Unit) {
        engine.state.value.tailnet.authURL?.let { url ->
            _tailnetSigningIn.value = true
            open(url)
            return
        }
        _tailnetSigningIn.value = true
        engine.tailnetLogin().thenAccept { st ->
            scope.launch {
                val url = st.authURL
                if (url != null) open(url) else _tailnetSigningIn.value = false
            }
        }
    }

    fun signOutOfTailscale() {
        _tailnetSigningIn.value = false
        engine.tailnetLogout()
    }

    /** Restarts the node after an error. */
    fun retryRemote() {
        engine.setRemoteEnabled(false)
        engine.setRemoteEnabled(true)
    }

    fun completeOnboarding() {
        settings.update { it.copy(onboardingDone = true) }
        settings.lastClipboardStamp = clipboard.stamp() ?: 0L
        ensureService()
    }

    companion object {
        const val NEWEST_WINDOW_MS = 10 * 60_000L
        /** How long a code that arrives later (catch-up) is still offered. */
        const val CODE_OFFER_MS = 3 * 60_000L

        @Volatile private var instance: Nearclip? = null

        fun get(context: Context): Nearclip = instance ?: synchronized(this) {
            instance ?: Nearclip(context.applicationContext as Application).also { instance = it }
        }
    }
}
