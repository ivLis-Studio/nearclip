package studio.ivlis.nearclip.service

import android.annotation.SuppressLint
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import studio.ivlis.nearclip.runtime.Nearclip
import studio.ivlis.nearclip.runtime.Notifications

/**
 * Foreground service (type connectedDevice) that keeps the engine and DNS-SD running while
 * "Stay connected in the background" is on (DESIGN §5 Android).
 */
class SyncService : Service() {
    private var runtime: Nearclip? = null
    private var job: Job? = null

    private data class Key(val paused: Boolean, val members: List<String>, val online: List<String>)

    @SuppressLint("MissingPermission")
    override fun onCreate() {
        super.onCreate()
        val rt = Nearclip.get(this)
        val initial = Notifications.sync(this, rt.engine.state.value, rt.settings.value)
        val type = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        try {
            ServiceCompat.startForeground(this, Notifications.ID_SYNC, initial, type)
        } catch (e: Exception) {
            rt.engine.log("foreground service refused: ${e.message}")
            stopSelf()
            return
        }
        runtime = rt
        rt.onServiceStarted()
        job = rt.scope.launch {
            rt.engine.state.combine(rt.settings.state) { snap, st ->
                Key(st.paused, snap.otherMembers.map { it.id + it.name }, snap.otherMembers.filter { it.id in snap.online }.map { it.name })
            }.distinctUntilChanged().collect {
                val n = Notifications.sync(this@SyncService, rt.engine.state.value, rt.settings.value)
                try { NotificationManagerCompat.from(this@SyncService).notify(Notifications.ID_SYNC, n) } catch (_: SecurityException) {}
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        job?.cancel()
        runtime?.onServiceStopped()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
