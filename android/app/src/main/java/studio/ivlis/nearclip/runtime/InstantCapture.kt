package studio.ivlis.nearclip.runtime

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import androidx.annotation.RequiresApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import moe.shizuku.server.IShizukuService
import org.lsposed.hiddenapibypass.HiddenApiBypass
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuBinderWrapper
import rikka.shizuku.SystemServiceHelper
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.util.concurrent.Executors

/** Setup of "Bring copies into Nearclip instantly", in the order the user completes it. */
enum class CaptureSetup {
    /** Android 9 and earlier let apps read the clipboard in the background: nothing to set up. */
    BUILT_IN,
    NOT_INSTALLED,
    NOT_RUNNING,
    /** Shizuku before v11, without the permission API. */
    OUTDATED,
    NEEDS_PERMISSION,
    /** Nearclip was denied in Shizuku's prompt, which then stops asking: it is allowed in Shizuku's app list. */
    DENIED,
    READY,
}

data class CaptureStatus(
    val setup: CaptureSetup,
    /** Registered for clipboard changes. */
    val listening: Boolean = false,
    /** Shizuku is ready, but reading the clipboard through it failed on this Android build. */
    val failed: Boolean = false,
) {
    val ready: Boolean get() = setup == CaptureSetup.READY || setup == CaptureSetup.BUILT_IN
}

/**
 * "Bring copies into Nearclip instantly": opt-in, off by default (DESIGN §5 Android).
 *
 * Android 10+ lets only the focused app and the default keyboard read the clipboard, so by default Nearclip sends
 * a copy when it opens, or from the tile, the notification, the share sheet or the text-selection menu. With
 * Shizuku, Nearclip calls the clipboard service as the shell user, which holds READ_CLIPBOARD_IN_BACKGROUND: it
 * hears about every change and reads new text right away. Android 9 and earlier need nothing extra.
 *
 * Reading a clip's content as the shell makes Android 12+ show "Shell pasted from your clipboard"; reading its
 * description shows nothing. Each change is checked through the description first, so Nearclip's own clips,
 * clips a password manager marked sensitive, and photos or files are never read.
 */
class InstantCapture(
    private val app: Context,
    private val onChanged: () -> Unit,
    private val onPermissionResult: (granted: Boolean) -> Unit,
    private val log: (String) -> Unit,
) {
    /** What a clipboard change brought. */
    sealed interface Change {
        val stamp: Long

        /** Text copied in another app. */
        data class Copied(val text: String, override val stamp: Long) : Change

        /** Nearclip's own clip ([ours]), or one marked sensitive: not read. */
        data class Skipped(override val stamp: Long, val ours: Boolean) : Change

        /** A photo or a file: left to sharing or to opening Nearclip, and not marked as seen. */
        data class NotText(override val stamp: Long) : Change
    }

    private val builtIn = Build.VERSION.SDK_INT < 29
    private val main = Handler(Looper.getMainLooper())

    /** Every clipboard and Shizuku call runs here, one at a time. */
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "nearclip-capture") }
    private val dispatcher = worker.asCoroutineDispatcher()
    private val _status = MutableStateFlow(CaptureStatus(if (builtIn) CaptureSetup.BUILT_IN else CaptureSetup.NOT_INSTALLED))
    val status: StateFlow<CaptureStatus> = _status.asStateFlow()

    @Volatile private var wanted = false
    private var source: Source? = null
    private val listener = ChangeListener { main.post { if (wanted) onChanged() } }

    init {
        if (!builtIn) {
            Shizuku.addBinderReceivedListenerSticky({ refresh() }, main)
            Shizuku.addBinderDeadListener({
                worker.execute {
                    source = null
                    _status.update { it.copy(listening = false) }
                }
                refresh()
            }, main)
            Shizuku.addRequestPermissionResultListener({ code, result ->
                if (code == REQUEST_CODE) {
                    refresh()
                    onPermissionResult(result == PackageManager.PERMISSION_GRANTED)
                }
            }, main)
        }
        refresh()
    }

    /** Checks the setup again (Shizuku may have been installed, started or allowed meanwhile), then follows it. */
    fun refresh() = worker.execute {
        val setup = setup()
        _status.update { it.copy(setup = setup, failed = false) }
        sync()
    }

    /** Follows the setting: listens while it is on and the setup is complete. */
    fun setWanted(on: Boolean) {
        wanted = on
        worker.execute { sync() }
    }

    /** Shows Shizuku's "Allow Nearclip?" prompt; the answer comes back through onPermissionResult. */
    fun requestPermission() {
        if (builtIn) return
        try {
            Shizuku.requestPermission(REQUEST_CODE)
        } catch (e: Exception) {
            log("instant capture: permission request failed: $e")
            refresh()
        }
    }

    /**
     * Runs a command as the shell user through Shizuku (it must be running, with Nearclip allowed); true when it
     * exited with 0. Used to let Nearclip see verification codes on Android 15+ (CodeForwarding).
     */
    suspend fun runShell(vararg cmd: String): Boolean = withContext(Dispatchers.IO) {
        if (builtIn) return@withContext false
        try {
            if (!Shizuku.pingBinder() || Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) return@withContext false
            val service = IShizukuService.Stub.asInterface(Shizuku.getBinder()) ?: return@withContext false
            val p = service.newProcess(arrayOf(*cmd), null, null) ?: return@withContext false
            val error = p.errorStream?.let { fd -> ParcelFileDescriptor.AutoCloseInputStream(fd).use { it.readBytes().decodeToString() } }
            p.waitFor()
            val code = p.exitValue()
            p.destroy()
            if (code != 0) log("shell: ${cmd.firstOrNull()} ${cmd.getOrNull(1)} exited with $code: ${error?.trim()}")
            code == 0
        } catch (e: Throwable) {
            log("shell: ${cmd.firstOrNull()} ${cmd.getOrNull(1)} failed: ${cause(e)}")
            false
        }
    }

    /** What the clipboard holds after a change; null when there is nothing to do (seen, locked, a photo or file). */
    suspend fun read(lastStamp: Long): Change? = withContext(dispatcher) {
        if (!wanted) return@withContext null
        val src = source ?: return@withContext null
        try {
            val desc = src.description() ?: return@withContext null
            val stamp = desc.timestamp
            val extras = desc.extras
            when {
                stamp == lastStamp -> null
                extras?.getString(ClipboardBridge.EXTRA_ORIGIN) != null -> Change.Skipped(stamp, ours = true)
                extras?.getBoolean(ClipboardBridge.EXTRA_IS_SENSITIVE, false) == true -> Change.Skipped(stamp, ours = false)
                !ClipboardBridge.hasText(desc) -> Change.NotText(stamp)
                // The clipboard may change between the description and the data fetch. Check the data's
                // own flags too, so that a fast password-manager copy can never slip through.
                else -> src.clip()?.let { clip ->
                    val actual = clip.description
                    when {
                        actual.timestamp == lastStamp -> null
                        actual.extras?.getString(ClipboardBridge.EXTRA_ORIGIN) != null -> Change.Skipped(actual.timestamp, ours = true)
                        actual.extras?.getBoolean(ClipboardBridge.EXTRA_IS_SENSITIVE, false) == true -> Change.Skipped(actual.timestamp, ours = false)
                        !ClipboardBridge.hasText(actual) -> Change.NotText(actual.timestamp)
                        else -> ClipboardBridge.plainText(clip)?.let { Change.Copied(it, actual.timestamp) }
                    }
                }
            }
        } catch (e: Throwable) {
            fail("read", e)
            null
        }
    }

    // ---------------------------------------------------------------- worker thread

    private fun sync() {
        val st = _status.value
        val want = wanted && st.ready && !st.failed
        if (want && !st.listening) start() else if (!want && st.listening) stop()
    }

    private fun start() {
        try {
            val src = source ?: connect().also { source = it }
            src.listen(listener)
            _status.update { it.copy(listening = true) }
            log("instant capture: listening")
        } catch (e: Throwable) {
            fail("start", e)
        }
    }

    private fun stop() {
        try {
            source?.unlisten(listener)
        } catch (e: Throwable) {
            log("instant capture: stop failed: ${cause(e)}")
        }
        _status.update { it.copy(listening = false) }
        log("instant capture: stopped")
    }

    private fun fail(what: String, e: Throwable) {
        log("instant capture: $what failed: ${cause(e)}")
        if (_status.value.listening) stop()
        source = null
        val setup = setup()
        _status.update { it.copy(setup = setup, listening = false, failed = setup == CaptureSetup.READY || setup == CaptureSetup.BUILT_IN) }
    }

    private fun setup(): CaptureSetup {
        if (builtIn) return CaptureSetup.BUILT_IN
        return try {
            when {
                !Shizuku.pingBinder() -> if (installed()) CaptureSetup.NOT_RUNNING else CaptureSetup.NOT_INSTALLED
                Shizuku.isPreV11() -> CaptureSetup.OUTDATED
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED -> CaptureSetup.READY
                Shizuku.shouldShowRequestPermissionRationale() -> CaptureSetup.DENIED
                else -> CaptureSetup.NEEDS_PERMISSION
            }
        } catch (e: Exception) {
            log("instant capture: Shizuku check failed: $e")
            if (installed()) CaptureSetup.NOT_RUNNING else CaptureSetup.NOT_INSTALLED
        }
    }

    private fun installed(): Boolean = try {
        val pm = app.packageManager
        if (Build.VERSION.SDK_INT >= 33) pm.getPackageInfo(SHIZUKU_PACKAGE, PackageManager.PackageInfoFlags.of(0))
        else @Suppress("DEPRECATION") pm.getPackageInfo(SHIZUKU_PACKAGE, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun connect(): Source =
        if (Build.VERSION.SDK_INT >= 29) connectShell() else DirectSource(app.getSystemService(ClipboardManager::class.java))

    /** The clipboard service's binder, called through Shizuku so that the service sees the shell user. */
    @RequiresApi(29)
    @SuppressLint("PrivateApi")
    private fun connectShell(): Source {
        HiddenApiBypass.addHiddenApiExemptions(
            "Landroid/content/IClipboard", "Landroid/content/IOnPrimaryClipChangedListener",
        )
        val binder = SystemServiceHelper.getSystemService(Context.CLIPBOARD_SERVICE) ?: error("no clipboard service")
        val service = Class.forName("android.content.IClipboard\$Stub").getMethod("asInterface", IBinder::class.java)
            .invoke(null, ShizukuBinderWrapper(binder)) ?: error("no clipboard interface")
        return ShellSource(service, Process.myUid() / PER_USER_RANGE)
    }

    private fun cause(e: Throwable): Throwable = (e as? InvocationTargetException)?.targetException ?: e

    // ---------------------------------------------------------------- clipboard access

    private interface Source {
        fun description(): ClipDescription?
        fun clip(): ClipData?
        fun listen(l: ChangeListener)
        fun unlisten(l: ChangeListener)
    }

    /** Android 9 and earlier: the public API works from the background. */
    private class DirectSource(private val cm: ClipboardManager) : Source {
        private var callback: ClipboardManager.OnPrimaryClipChangedListener? = null

        override fun description(): ClipDescription? = cm.primaryClipDescription
        override fun clip(): ClipData? = cm.primaryClip

        override fun listen(l: ChangeListener) {
            if (callback != null) return
            val cb = ClipboardManager.OnPrimaryClipChangedListener { l.fire() }
            callback = cb
            cm.addPrimaryClipChangedListener(cb)
        }

        override fun unlisten(l: ChangeListener) {
            callback?.let { cm.removePrimaryClipChangedListener(it) }
            callback = null
        }
    }

    /**
     * The hidden IClipboard interface. AIDL methods have no overloads, so they are found by name; their parameters
     * changed between releases — (package, user) on Android 10 and 11, then an attribution tag, then a device id
     * on 14 — so arguments are filled in by type: the listener first, then the calling package (the shell's, since
     * Shizuku calls as the shell) and a null attribution tag, then the user id and the default device.
     */
    private class ShellSource(private val service: Any, private val userId: Int) : Source {
        private val methods: Map<String, Method> = service.javaClass.methods.associateBy { it.name }

        override fun description(): ClipDescription? = call("getPrimaryClipDescription") as ClipDescription?
        override fun clip(): ClipData? = call("getPrimaryClip") as ClipData?
        override fun listen(l: ChangeListener) { call("addPrimaryClipChangedListener", l.asInterface) }
        override fun unlisten(l: ChangeListener) { call("removePrimaryClipChangedListener", l.asInterface) }

        private fun call(name: String, listener: Any? = null): Any? {
            val m = methods[name] ?: throw NoSuchMethodException(name)
            var strings = 0
            var ints = 0
            val args = m.parameterTypes.mapIndexed { i, type ->
                when {
                    i == 0 && listener != null -> listener
                    type == String::class.java -> if (strings++ == 0) SHELL_PACKAGE else null
                    type == Int::class.javaPrimitiveType -> if (ints++ == 0) userId else 0
                    type == Boolean::class.javaPrimitiveType -> false
                    else -> null
                }
            }
            return m.invoke(service, *args.toTypedArray())
        }
    }

    /** IOnPrimaryClipChangedListener on a plain Binder: its one call is the first transaction (oneway). */
    @SuppressLint("PrivateApi") // hidden listener type used only by the opt-in, version-adapted Shizuku path
    private class ChangeListener(val fire: () -> Unit) : Binder() {
        init {
            attachInterface(null, DESCRIPTOR)
        }

        /** This binder as the hidden listener type the clipboard service's proxy takes. */
        val asInterface: Any by lazy {
            Class.forName("$DESCRIPTOR\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, this)!!
        }

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != IBinder.FIRST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags)
            fire()
            return true
        }

        private companion object {
            const val DESCRIPTOR = "android.content.IOnPrimaryClipChangedListener"
        }
    }

    companion object {
        const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
        private const val SHELL_PACKAGE = "com.android.shell"
        private const val REQUEST_CODE = 0x4e43
        private const val PER_USER_RANGE = 100_000
    }
}
