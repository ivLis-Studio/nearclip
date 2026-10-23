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
import studio.ivlis.nearclip.core.engine.NearclipEngine
import studio.ivlis.nearclip.core.engine.SendResult
import studio.ivlis.nearclip.core.engine.TicketInfo
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.model.Platform
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.core.store.FileStore
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

    /** Started MainActivity instances; a counter, because an old instance can stop after a new one started. */
    private var visibleActivities = 0
    val uiVisible: Boolean get() = visibleActivities > 0
    private var processVisible = false
    @Volatile var serviceRunning = false
        private set
    private var stopJob: Job? = null
    private var openWindowUntil = 0L
    private var openSentStamp = 0L

    init {
        val s = settings.value
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
            ),
        )
        engine.setPaused(s.paused)
        discovery = Discovery(app, engine)
        Notifications.ensureChannels(app)
        scope.launch { engine.events.collect { onEvent(it) } }
        scope.launch {
            engine.state.combine(settings.state) { snap, _ -> advert(snap) }.distinctUntilChanged().collect { discovery.update(it) }
        }
        scope.launch { settings.state.map { it.retentionDays }.distinctUntilChanged().collect { engine.setRetention(it) } }
        scope.launch { settings.state.map { it.syncImages }.distinctUntilChanged().collect { engine.setSyncImages(it) } }
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
        if (visible) Notifications.cancelPairPrompt(app) else if (!uiVisible) flushDeletes()
    }

    // ---------------------------------------------------------------- engine events

    private fun onEvent(e: EngineEvent) {
        when (e) {
            is EngineEvent.ClipAdded -> if (!e.local) onIncoming(e)
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
            else -> Unit
        }
    }

    private fun onIncoming(e: EngineEvent.ClipAdded) {
        val s = settings.value
        if (s.paused) return
        if (e.apply && s.autoApply) {
            applyToClipboard(e.clip, announce = true)
            return
        }
        // "Copy the newest clip when Nearclip opens": catch-up that arrives right after opening counts too.
        if (!e.live && s.copyNewestOnOpen && System.currentTimeMillis() < openWindowUntil) {
            val snap = engine.state.value
            val clip = e.clip
            if (clip.src == snap.deviceId || clip.localOnly) return
            if (System.currentTimeMillis() - clip.ts > NEWEST_WINDOW_MS) return
            if (clip.ts <= maxOf(settings.lastAppliedTs, newestLocalTs(snap), openSentStamp)) return
            applyToClipboard(clip, announce = true)
        }
    }

    private fun newestLocalTs(snap: EngineSnapshot): Long =
        snap.history.firstOrNull { it.src == snap.deviceId }?.ts ?: 0L

    // ---------------------------------------------------------------- clipboard

    fun sourceName(clip: Clip, snap: EngineSnapshot = engine.state.value): String =
        if (clip.src == snap.deviceId) thisDeviceLabel()
        else snap.members.firstOrNull { it.id == clip.src }?.name ?: clip.sourceName ?: app.getString(R.string.unknown_device)

    fun thisDeviceLabel(): String = app.getString(if (DeviceInfo.isTablet(app)) R.string.this_tablet else R.string.this_phone)

    /** Writes a clip to the system clipboard (marked as ours, so it is never sent back). */
    fun applyToClipboard(clip: Clip, announce: Boolean): Boolean {
        val ok = when {
            clip.isText -> clip.text?.let { clipboard.writeText(it, clip.id) } ?: false
            clip.isImage -> clipboard.writeImage(engine.blobFile(clip), clip.id)
            else -> false
        }
        if (!ok) return false
        if (clip.ts > settings.lastAppliedTs) settings.lastAppliedTs = clip.ts
        clipboard.stamp()?.let { settings.lastClipboardStamp = it }
        if (announce && uiVisible) _messages.tryEmit(UiMessage.CopiedFrom(sourceName(clip)))
        return true
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

    suspend fun send(content: ClipboardBridge.Content): SendOutcome = when (content) {
        is ClipboardBridge.Text -> sendText(content.text)
        is ClipboardBridge.Image -> sendImage(content.uri)
    }

    suspend fun sendText(text: String): SendOutcome = withContext(Dispatchers.IO) {
        if (text.isBlank()) return@withContext SendOutcome.Empty
        if (settings.value.paused) return@withContext SendOutcome.Paused
        val snap = engine.state.value
        val newest = snap.history.firstOrNull { it.groupId == snap.groupId }
        if (newest != null && newest.isText && newest.text == text && System.currentTimeMillis() - newest.receivedAt < NEWEST_WINDOW_MS) {
            return@withContext SendOutcome.AlreadySynced
        }
        engine.start()
        awaitPeers()
        outcome(engine.sendText(text))
    }

    suspend fun sendImage(uri: Uri): SendOutcome = withContext(Dispatchers.IO) {
        if (settings.value.paused) return@withContext SendOutcome.Paused
        if (!settings.value.syncImages) return@withContext SendOutcome.ImagesOff
        val img = ImageTools.prepare(app, uri) ?: return@withContext SendOutcome.Unreadable
        engine.start()
        awaitPeers()
        outcome(engine.sendImage(img.bytes, img.mime, img.width, img.height))
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

    fun togglePin(clip: Clip) = engine.setPinned(clip.id, !clip.pinned)

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

    fun completeOnboarding() {
        settings.update { it.copy(onboardingDone = true) }
        settings.lastClipboardStamp = clipboard.stamp() ?: 0L
        ensureService()
    }

    companion object {
        const val NEWEST_WINDOW_MS = 10 * 60_000L

        @Volatile private var instance: Nearclip? = null

        fun get(context: Context): Nearclip = instance ?: synchronized(this) {
            instance ?: Nearclip(context.applicationContext as Application).also { instance = it }
        }
    }
}
