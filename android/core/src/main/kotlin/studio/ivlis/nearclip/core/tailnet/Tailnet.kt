package studio.ivlis.nearclip.core.tailnet

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.io.File

/** Another Nearclip node in the user's tailnet (PROTOCOL §10.2). */
@Serializable
data class TailnetPeer(
    val host: String = "",
    val idPrefix: String? = null,
    val ip: String = "",
    val online: Boolean = false,
    val os: String? = null,
    val direct: Boolean = false,
    val relay: String? = null,
)

/** Status of the embedded Tailscale node (tailnet/README.md). */
@Serializable
data class TailnetStatus(
    /** off, starting, needsLogin, needsApproval, running, stopped, error */
    val state: String = "off",
    val backend: String? = null,
    val authURL: String? = null,
    val ip: String? = null,
    val ip6: String? = null,
    val hostname: String? = null,
    val dnsName: String? = null,
    val account: String? = null,
    val tailnet: String? = null,
    val proxyPort: Int? = null,
    val token: String? = null,
    val ports: List<Int>? = null,
    val peers: List<TailnetPeer> = emptyList(),
    val health: List<String>? = null,
    val error: String? = null,
    val version: String? = null,
) {
    val isRunning: Boolean get() = state == "running" && ip != null

    /** What the UI and the engine care about (ignores health chatter). */
    fun sameEssentials(o: TailnetStatus): Boolean =
        state == o.state && authURL == o.authURL && ip == o.ip && account == o.account && error == o.error &&
            proxyPort == o.proxyPort && token == o.token && peers == o.peers

    companion object {
        val OFF = TailnetStatus()
    }
}

/**
 * Options for the embedded node; it only runs while remote connection is enabled.
 * [netInfo] (Android) reports the device's interfaces before the node starts (tailscale/tailscale#17311).
 */
data class TailnetOptions(
    val directory: File,
    val controlUrl: String? = null,
    val logPath: String? = null,
    /** Test control servers: no interface binding. */
    val testMode: Boolean = false,
    val netInfo: (() -> String?)? = null,
)

/** How a session reaches its peer (PROTOCOL §10.3). */
enum class PeerRoute(val wire: String) { LAN("lan"), REMOTE("remote") }

/** Tailnet addresses: 100.64.0.0/10 and fd7a:115c:a1e0::/48. */
object TailnetAddress {
    fun contains(host: String?): Boolean {
        val h = host?.lowercase() ?: return false
        if (h.startsWith("fd7a:115c:a1e0:")) return true
        val parts = h.split('.')
        if (parts.size != 4) return false
        val a = parts[0].toIntOrNull() ?: return false
        val b = parts[1].toIntOrNull() ?: return false
        return a == 100 && b in 64..127
    }
}

/** Calls into the embedded node. All calls block: never on the engine or UI thread. */
object TailnetBridge {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val loadError: String? by lazy { TailnetNative.load() }

    /** Whether the native library is present (it is not in unit tests without a desktop build). */
    val available: Boolean get() = loadError == null

    private inline fun call(f: () -> String): TailnetStatus {
        loadError?.let { return TailnetStatus(state = "error", error = "tailnet library: $it") }
        return try {
            json.decodeFromString(TailnetStatus.serializer(), f())
        } catch (t: Throwable) {
            TailnetStatus(state = "error", error = t.message ?: t.javaClass.simpleName)
        }
    }

    fun start(config: JsonObject): TailnetStatus = call { TailnetNative.nativeStart(config.toString()) }
    fun status(): TailnetStatus = call { TailnetNative.nativeStatus() }
    fun login(): TailnetStatus = call { TailnetNative.nativeLogin() }
    fun logout(): TailnetStatus = call { TailnetNative.nativeLogout() }
    fun stop(): TailnetStatus = call { TailnetNative.nativeStop() }
    fun setNetwork(info: String): TailnetStatus = call { TailnetNative.nativeSetNetwork(info) }
    fun networkChanged() {
        if (available) runCatching { TailnetNative.nativeNetworkChanged() }
    }
}
