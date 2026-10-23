package studio.ivlis.nearclip.core.engine

import java.net.Inet4Address
import java.net.NetworkInterface

data class EngineConfig(
    val platform: String,
    /** Name used when this installation is created; later renames go through [NearclipEngine.rename]. */
    val defaultName: String,
    val model: String? = null,
    val appVersion: String? = null,
    /** Preferred listener port; falls back to an OS-assigned port when taken. 0 = OS-assigned. */
    val port: Int = DEFAULT_PORT,
    val keepAliveMs: Long = 15_000,
    val idleTimeoutMs: Long = 45_000,
    val tickMs: Long = 5_000,
    val dialIntervalMs: Long = 20_000,
    val maxBackoffMs: Long = 300_000,
    val connectTimeoutMs: Int = 4_000,
    val handshakeTimeoutMs: Int = 15_000,
    val pairingDecisionMs: Long = 120_000,
    val ticketLifetimeMs: Long = 600_000,
    val retentionDays: Int = 30,
    val maxItems: Int = 1000,
    val syncImages: Boolean = true,
    /**
     * When > 0, a clip produced while no member session is open is sent live (before the inventory) to every
     * member that connects within this window. Phones use this so that a clip sent from a cold start (tile,
     * share sheet) still lands on the other clipboards instead of arriving as catch-up. 0 = off (CLI default).
     */
    val liveRetryMs: Long = 0,
    /** Our own reachable IPv4 listener addresses (no loopback, no link-local). */
    val localAddresses: () -> List<String> = ::defaultLocalAddresses,
) {
    companion object {
        const val DEFAULT_PORT = 45821
        const val SERVICE_TYPE = "_nearclip._tcp"
    }
}

fun defaultLocalAddresses(): List<String> {
    val out = ArrayList<String>()
    try {
        val ifaces = NetworkInterface.getNetworkInterfaces() ?: return out
        for (nif in ifaces.toList()) {
            if (!nif.isUp || nif.isLoopback) continue
            for (addr in nif.inetAddresses.toList()) {
                if (addr !is Inet4Address || addr.isLoopbackAddress || addr.isLinkLocalAddress || addr.isAnyLocalAddress) continue
                val host = addr.hostAddress ?: continue
                if (host !in out) out.add(host)
            }
        }
    } catch (_: Exception) {
    }
    return out.sortedWith(compareBy({ !it.startsWith("192.168.") }, { !it.startsWith("10.") }, { it }))
}
