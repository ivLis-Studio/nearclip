package studio.ivlis.nearclip.runtime

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipDescription
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import androidx.annotation.Keep
import studio.ivlis.nearclip.capture.IClipboardAccess
import studio.ivlis.nearclip.capture.IClipboardEvents
import java.lang.reflect.Method
import kotlin.system.exitProcess

/**
 * Started only by Shizuku after the user grants permission and opts into instant capture.
 * Framework reflection stays in Shizuku's shell/root process, where Shizuku officially supports it.
 * The normal app process only uses our own AIDL interface; it never changes ART internals.
 */
@Keep
class ClipboardUserService : IClipboardAccess.Stub() {
    private var service: Any? = null
    private var methods = emptyMap<String, Method>()
    private var userId = 0
    private var callback: IClipboardEvents? = null
    private var frameworkListener: Any? = null
    private var clientDeath: IBinder.DeathRecipient? = null

    @Synchronized
    @SuppressLint("PrivateApi")
    override fun listen(events: IClipboardEvents, user: Int) {
        unlisten()
        userId = user
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "clipboard") as? IBinder ?: error("no clipboard service")
        service = Class.forName("android.content.IClipboard\$Stub").getMethod("asInterface", IBinder::class.java)
            .invoke(null, binder) ?: error("no clipboard interface")
        methods = service!!.javaClass.methods.associateBy { it.name }
        val cb = FrameworkListener { try { events.onPrimaryClipChanged() } catch (_: Exception) { destroy() } }
        val listener = Class.forName("android.content.IOnPrimaryClipChangedListener\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null, cb)!!
        val death = IBinder.DeathRecipient { destroy() }
        events.asBinder().linkToDeath(death, 0)
        callback = events
        clientDeath = death
        frameworkListener = listener
        try {
            call("addPrimaryClipChangedListener", listener)
        } catch (e: Throwable) {
            unlisten()
            throw IllegalStateException("clipboard listener registration failed", e)
        }
    }

    @Synchronized
    override fun description(): ClipDescription? = call("getPrimaryClipDescription") as ClipDescription?

    @Synchronized
    override fun clip(): ClipData? {
        // Check before fetching content, then again afterwards to cover a clipboard change between calls.
        if (!readable(description())) return null
        return (call("getPrimaryClip") as ClipData?)?.takeIf { readable(it.description) }
    }

    private fun readable(d: ClipDescription?): Boolean = d != null && ClipboardBridge.hasText(d) &&
        d.extras?.getString(ClipboardBridge.EXTRA_ORIGIN) == null &&
        d.extras?.getBoolean(ClipboardBridge.EXTRA_IS_SENSITIVE, false) != true

    @Synchronized
    override fun unlisten() {
        frameworkListener?.let { try { call("removePrimaryClipChangedListener", it) } catch (_: Throwable) {} }
        frameworkListener = null
        val events = callback
        val death = clientDeath
        callback = null
        clientDeath = null
        if (events != null && death != null) try { events.asBinder().unlinkToDeath(death, 0) } catch (_: Exception) {}
        service = null
        methods = emptyMap()
    }

    override fun destroy() {
        try { unlisten() } finally { exitProcess(0) }
    }

    /** Android 10/11: package+user; 12+: attribution tag; 14+: device id. No ART layout assumptions. */
    private fun call(name: String, listener: Any? = null): Any? {
        val target = service ?: return null
        val method = methods[name] ?: throw NoSuchMethodException(name)
        var strings = 0
        var ints = 0
        val args = method.parameterTypes.mapIndexed { i, type ->
            when {
                i == 0 && listener != null -> listener
                type == String::class.java -> if (strings++ == 0) "com.android.shell" else null
                type == Int::class.javaPrimitiveType -> if (ints++ == 0) userId else 0
                type == Boolean::class.javaPrimitiveType -> false
                else -> null
            }
        }
        return method.invoke(target, *args.toTypedArray())
    }

    private class FrameworkListener(val fire: () -> Unit) : Binder() {
        init { attachInterface(null, "android.content.IOnPrimaryClipChangedListener") }
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != FIRST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags)
            data.enforceInterface("android.content.IOnPrimaryClipChangedListener")
            fire()
            return true
        }
    }
}
