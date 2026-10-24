package studio.ivlis.nearclip.core.tailnet

import java.io.File

/**
 * JNI entry points of the embedded Tailscale node (tailnet/capi/jni.c). Every function returns the JSON status
 * described in tailnet/README.md. All calls block; never call them on the engine or UI thread.
 */
object TailnetNative {
    /**
     * Loads libnctailnet: on Android from the APK, on desktop JVMs from `NEARCLIP_TAILNET_LIB` /
     * `-Dnearclip.tailnet.lib` (absolute path) or java.library.path. Returns an error message, or null.
     */
    fun load(): String? = try {
        val path = System.getenv("NEARCLIP_TAILNET_LIB") ?: System.getProperty("nearclip.tailnet.lib")
        if (path != null && File(path).isFile) System.load(path) else System.loadLibrary("nctailnet")
        null
    } catch (t: Throwable) {
        t.message ?: t.javaClass.simpleName
    }

    @JvmStatic external fun nativeStart(config: String): String
    @JvmStatic external fun nativeStatus(): String
    @JvmStatic external fun nativeLogin(): String
    @JvmStatic external fun nativeLogout(): String
    @JvmStatic external fun nativeStop(): String
    @JvmStatic external fun nativeSetNetwork(info: String): String
    @JvmStatic external fun nativeNetworkChanged()
}
