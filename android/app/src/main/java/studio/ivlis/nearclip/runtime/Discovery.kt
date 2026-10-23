package studio.ivlis.nearclip.runtime

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import studio.ivlis.nearclip.core.engine.DiscoveredService
import studio.ivlis.nearclip.core.engine.EngineConfig
import studio.ivlis.nearclip.core.engine.NearclipEngine
import studio.ivlis.nearclip.core.model.Endpoint
import java.net.Inet4Address
import java.net.InetAddress
import java.util.ArrayDeque
import java.util.concurrent.Executors

/**
 * DNS-SD for PROTOCOL §2 with NsdManager: advertises _nearclip._tcp with the TXT keys and browses continuously
 * while the engine runs. A Wi-Fi multicast lock is held while browsing. All entry points are main-thread only.
 */
class Discovery(private val context: Context, private val engine: NearclipEngine) {
    data class Advert(val name: String, val id: String, val platform: String, val groupTag: String, val pairing: Boolean, val port: Int)

    private val nsd: NsdManager? = context.getSystemService(NsdManager::class.java)
    private val wifi: WifiManager? = context.applicationContext.getSystemService(WifiManager::class.java)
    private val multicast = wifi?.createMulticastLock("nearclip")?.apply { setReferenceCounted(false) }
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "nearclip-nsd").apply { isDaemon = true } }

    private var advert: Advert? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var browsing: NsdManager.DiscoveryListener? = null
    private val ids = HashMap<String, String>()
    private val infoCallbacks = HashMap<String, Any>()
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    /** Applies the desired state: [desired] null = neither advertise nor browse. */
    fun update(desired: Advert?) {
        if (desired != advert) {
            unregister()
            advert = desired
            if (desired != null) register(desired)
        }
        if (desired != null && browsing == null) startBrowsing()
        if (desired == null && browsing != null) stopBrowsing()
    }

    private fun register(a: Advert) {
        val nsd = nsd ?: return
        val info = NsdServiceInfo().apply {
            serviceName = truncateUtf8(a.name.ifBlank { "Nearclip" }, 63)
            serviceType = EngineConfig.SERVICE_TYPE
            port = a.port
            setAttribute("v", "1")
            setAttribute("id", a.id)
            setAttribute("nm", truncateUtf8(a.name, 60))
            setAttribute("pf", a.platform)
            setAttribute("gt", a.groupTag)
            if (a.pairing) setAttribute("pm", "1")
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                engine.log("DNS-SD registration failed: ${errorCode}")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        try {
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            registration = listener
        } catch (e: Exception) {
            engine.log("DNS-SD registration failed: ${e.message}")
        }
    }

    private fun unregister() {
        val l = registration ?: return
        registration = null
        try { nsd?.unregisterService(l) } catch (_: Exception) {}
    }

    private fun startBrowsing() {
        val nsd = nsd ?: return
        multicast?.let { runCatching { it.acquire() } }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                main.post { if (browsing === this) browsing = null }
                engine.log("DNS-SD browse failed: ${errorCode}")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) { main.post { if (browsing === this) resolve(info) } }
            override fun onServiceLost(info: NsdServiceInfo) { main.post { lost(info.serviceName) } }
        }
        try {
            nsd.discoverServices(EngineConfig.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            browsing = listener
        } catch (e: Exception) {
            engine.log("DNS-SD browse failed: ${e.message}")
        }
    }

    private fun stopBrowsing() {
        val l = browsing ?: return
        browsing = null
        try { nsd?.stopServiceDiscovery(l) } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= 34) for (cb in infoCallbacks.values) {
            try { nsd?.unregisterServiceInfoCallback(cb as NsdManager.ServiceInfoCallback) } catch (_: Exception) {}
        }
        infoCallbacks.clear()
        resolveQueue.clear()
        ids.clear()
        engine.clearDiscovered()
        multicast?.let { runCatching { if (it.isHeld) it.release() } }
    }

    private fun lost(serviceName: String) {
        if (Build.VERSION.SDK_INT >= 34) {
            (infoCallbacks.remove(serviceName) as? NsdManager.ServiceInfoCallback)?.let { cb ->
                try { nsd?.unregisterServiceInfoCallback(cb) } catch (_: Exception) {}
            }
        }
        ids.remove(serviceName)?.let { engine.onServiceLost(it) }
    }

    private fun resolve(info: NsdServiceInfo) {
        val nsd = nsd ?: return
        if (Build.VERSION.SDK_INT >= 34) {
            if (infoCallbacks.containsKey(info.serviceName)) return
            val cb = object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
                override fun onServiceUpdated(si: NsdServiceInfo) { main.post { resolved(si) } }
                override fun onServiceLost() { main.post { lost(info.serviceName) } }
                override fun onServiceInfoCallbackUnregistered() {}
            }
            try {
                nsd.registerServiceInfoCallback(info, executor, cb)
                infoCallbacks[info.serviceName] = cb
            } catch (_: Exception) {
            }
        } else {
            resolveQueue.add(info)
            pumpResolve()
        }
    }

    @Suppress("DEPRECATION")
    private fun pumpResolve() {
        if (resolving) return
        val next = resolveQueue.pollFirst() ?: return
        val nsd = nsd ?: return
        resolving = true
        try {
            nsd.resolveService(next, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    main.post {
                        resolving = false
                        if (errorCode == NsdManager.FAILURE_ALREADY_ACTIVE) main.postDelayed({ resolveQueue.add(info); pumpResolve() }, 300)
                        pumpResolve()
                    }
                }
                override fun onServiceResolved(info: NsdServiceInfo) {
                    main.post {
                        resolving = false
                        resolved(info)
                        pumpResolve()
                    }
                }
            })
        } catch (_: Exception) {
            resolving = false
        }
    }

    @Suppress("DEPRECATION")
    private fun resolved(si: NsdServiceInfo) {
        if (browsing == null) return
        val attrs = si.attributes ?: return
        fun attr(k: String) = attrs[k]?.let { String(it, Charsets.UTF_8) }
        if (attr("v") != "1") return
        val id = attr("id")?.lowercase() ?: return
        if (id == engine.deviceId) return
        val hosts: List<InetAddress> = if (Build.VERSION.SDK_INT >= 34) si.hostAddresses else listOfNotNull(si.host)
        val port = si.port
        if (port !in 1..65535) return
        val endpoints = hosts.sortedBy { if (it is Inet4Address) 0 else 1 }
            .mapNotNull { a -> a.hostAddress?.let { h -> runCatching { Endpoint(h, port) }.getOrNull() } }
        if (endpoints.isEmpty()) return
        ids[si.serviceName] = id
        engine.onServiceDiscovered(
            DiscoveredService(
                id = id,
                name = attr("nm")?.takeIf { it.isNotBlank() } ?: si.serviceName,
                platform = attr("pf") ?: "",
                groupTag = attr("gt")?.lowercase() ?: "",
                pairingMode = attr("pm") == "1",
                endpoints = endpoints,
            ),
        )
    }

    companion object {
        fun truncateUtf8(s: String, limit: Int): String {
            val out = StringBuilder()
            var used = 0
            var i = 0
            while (i < s.length) {
                val cp = s.codePointAt(i)
                val chars = Character.charCount(cp)
                val n = String(Character.toChars(cp)).toByteArray(Charsets.UTF_8).size
                if (used + n > limit) break
                out.appendCodePoint(cp)
                used += n
                i += chars
            }
            return out.toString()
        }
    }
}
