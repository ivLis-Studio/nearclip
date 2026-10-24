package studio.ivlis.nearclip.runtime

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * The device's interfaces and default route for the embedded Tailscale node (tailnet/README.md, NetInfo).
 * Go cannot enumerate interfaces inside the Android app sandbox (tailscale/tailscale#17311), Java can.
 */
object NetInfo {
    fun json(context: Context): String {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val lp = runCatching { cm?.getLinkProperties(cm.activeNetwork) }.getOrNull()
        val defaultIf = lp?.interfaceName ?: ""
        val gateway = lp?.routes?.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress ?: ""
        val interfaces = runCatching { NetworkInterface.getNetworkInterfaces()?.toList() }.getOrNull().orEmpty()
        return buildJsonObject {
            putJsonArray("interfaces") {
                for (nif in interfaces) {
                    val addrs = runCatching {
                        nif.interfaceAddresses.mapNotNull { ia ->
                            ia.address?.hostAddress?.substringBefore('%')?.let { "$it/${ia.networkPrefixLength}" }
                        }
                    }.getOrDefault(emptyList())
                    addJsonObject {
                        put("name", nif.name)
                        put("index", nif.index)
                        put("mtu", runCatching { nif.mtu }.getOrDefault(1500))
                        put("up", runCatching { nif.isUp }.getOrDefault(false))
                        put("loopback", runCatching { nif.isLoopback }.getOrDefault(false))
                        put("pointToPoint", runCatching { nif.isPointToPoint }.getOrDefault(false))
                        put("multicast", runCatching { nif.supportsMulticast() }.getOrDefault(false))
                        putJsonArray("addrs") { addrs.forEach { add(it) } }
                    }
                }
            }
            put("defaultInterface", defaultIf)
            put("gateway", gateway)
        }.toString()
    }

    /** Calls [onChange] whenever the default network or its addresses change. */
    fun watch(context: Context, onChange: () -> Unit) {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        runCatching {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = onChange()
                override fun onLost(network: Network) = onChange()
                override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) = onChange()
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = Unit
            })
        }
    }
}
