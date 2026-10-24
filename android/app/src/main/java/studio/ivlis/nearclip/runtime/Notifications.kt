package studio.ivlis.nearclip.runtime

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.engine.EngineSnapshot
import studio.ivlis.nearclip.core.engine.PairPromptInfo
import studio.ivlis.nearclip.core.engine.Sas
import studio.ivlis.nearclip.service.NotificationActionReceiver
import studio.ivlis.nearclip.ui.MainActivity
import studio.ivlis.nearclip.ui.SendActivity

object Notifications {
    const val CHANNEL_SYNC = "sync"
    const val CHANNEL_PAIRING = "pairing"
    const val ID_SYNC = 7
    const val ID_PAIRING = 8
    private const val IRIS = 0xFF4C5BF5.toInt()

    fun ensureChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannels(
            listOf(
                NotificationChannel(CHANNEL_SYNC, context.getString(R.string.channel_sync), NotificationManager.IMPORTANCE_LOW).apply {
                    description = context.getString(R.string.channel_sync_description)
                    setShowBadge(false)
                },
                NotificationChannel(CHANNEL_PAIRING, context.getString(R.string.channel_pairing), NotificationManager.IMPORTANCE_HIGH).apply {
                    description = context.getString(R.string.channel_pairing_description)
                },
            ),
        )
    }

    private fun openApp(context: Context, requestCode: Int): PendingIntent = PendingIntent.getActivity(
        context, requestCode,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /**
     * "Nearclip · Connected to 2 devices" with Send clipboard + Pause/Resume (DESIGN §5 Android). With instant
     * capture on and Shizuku stopped (it does when the phone restarts), the header says so.
     */
    fun sync(context: Context, snap: EngineSnapshot, settings: AppSettings, capture: CaptureStatus? = null): Notification {
        val others = snap.otherMembers
        val online = others.filter { it.id in snap.online }
        val title = when {
            settings.paused -> context.getString(R.string.syncing_paused)
            others.isEmpty() -> context.getString(R.string.notification_no_devices)
            online.isEmpty() -> context.getString(R.string.notification_looking)
            else -> context.resources.getQuantityString(R.plurals.connected_to_devices, online.size, online.size)
        }
        val text = when {
            settings.paused -> context.getString(R.string.notification_paused_text)
            online.isNotEmpty() -> online.joinToString(", ") { it.name }
            others.isNotEmpty() -> context.getString(R.string.notification_looking_text)
            else -> null
        }
        val send = PendingIntent.getActivity(
            context, 1, SendActivity.clipboardIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val toggle = PendingIntent.getBroadcast(
            context, 2,
            Intent(context, NotificationActionReceiver::class.java)
                .setAction(if (settings.paused) NotificationActionReceiver.ACTION_RESUME else NotificationActionReceiver.ACTION_PAUSE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(context, CHANNEL_SYNC)
            .setSmallIcon(R.drawable.ic_stat_nearclip)
            .setColor(IRIS)
            .setContentTitle(title)
            .setContentText(text)
            .setSubText(if (shizukuStopped(settings, capture)) context.getString(R.string.notification_shizuku_off) else null)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openApp(context, 0))
            .apply {
                if (!settings.paused) addAction(R.drawable.ic_content_paste_go, context.getString(R.string.send_clipboard), send)
            }
            .addAction(
                if (settings.paused) R.drawable.ic_play_arrow else R.drawable.ic_pause,
                context.getString(if (settings.paused) R.string.resume else R.string.pause),
                toggle,
            )
            .build()
    }

    @SuppressLint("MissingPermission")
    fun showPairPrompt(context: Context, prompt: PairPromptInfo) {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return
        val decline = PendingIntent.getBroadcast(
            context, 4,
            Intent(context, NotificationActionReceiver::class.java).setAction(NotificationActionReceiver.ACTION_DECLINE_PAIRING),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, CHANNEL_PAIRING)
            .setSmallIcon(R.drawable.ic_stat_nearclip)
            .setColor(IRIS)
            .setContentTitle(context.getString(R.string.pair_inviter_title, prompt.name))
            .setContentText(context.getString(R.string.pair_prompt_notification, prompt.name, Sas.display(prompt.sas)))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setTimeoutAfter(120_000)
            .setContentIntent(openApp(context, 3))
            .addAction(0, context.getString(R.string.decline), decline)
            .build()
        try { nm.notify(ID_PAIRING, n) } catch (_: SecurityException) {}
    }

    fun cancelPairPrompt(context: Context) {
        NotificationManagerCompat.from(context).cancel(ID_PAIRING)
    }

    fun shizukuStopped(settings: AppSettings, capture: CaptureStatus?): Boolean =
        settings.instantCapture && capture?.setup == CaptureSetup.NOT_RUNNING
}
