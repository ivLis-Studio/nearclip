package studio.ivlis.nearclip.runtime

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.engine.EngineSnapshot
import studio.ivlis.nearclip.core.engine.IncomingTransfer
import studio.ivlis.nearclip.core.engine.PairPromptInfo
import studio.ivlis.nearclip.core.engine.Sas
import studio.ivlis.nearclip.service.NotificationActionReceiver
import studio.ivlis.nearclip.ui.MainActivity
import studio.ivlis.nearclip.ui.Routes
import studio.ivlis.nearclip.ui.SendActivity
import java.util.Locale

object Notifications {
    const val CHANNEL_SYNC = "sync"
    const val CHANNEL_PAIRING = "pairing"
    const val CHANNEL_TRANSFERS = "incoming_images"
    const val CHANNEL_CODES = "codes"
    const val ID_SYNC = 7
    const val ID_PAIRING = 8
    const val ID_TRANSFER = 9
    const val ID_CODE = 10
    const val ID_CODES_HIDDEN = 11
    private const val IRIS = 0xFF4C5BF5.toInt()
    /** The transfer notification currently shows progress (not "Copied from …" or a failure). */
    @Volatile private var transferProgressShown = false
    /** The clip the transfer notification shows as arrived, so its thumbnail can be filled in later. */
    @Volatile var transferDoneFor: String? = null
        private set

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
                // A quiet banner, like the toast on a computer: once when an image starts coming, once when it is in.
                NotificationChannel(CHANNEL_TRANSFERS, context.getString(R.string.channel_transfers), NotificationManager.IMPORTANCE_HIGH).apply {
                    description = context.getString(R.string.channel_transfers_description)
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                },
                // "A verification code arrived from MacBook Pro. Copy it?" — a banner, like the popup on a computer.
                NotificationChannel(CHANNEL_CODES, context.getString(R.string.channel_codes), NotificationManager.IMPORTANCE_HIGH).apply {
                    description = context.getString(R.string.channel_codes_description)
                    setShowBadge(false)
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

    // ---------------------------------------------------------------- images on their way (PROTOCOL §6.6)

    /** "3.1 / 8.4 MB": both in the unit of the total, so the numbers don't jump between units. */
    fun progressText(context: Context, t: IncomingTransfer): String = when {
        t.total <= 0 -> context.getString(R.string.transfer_preparing)
        t.total >= 1_000_000 -> String.format(Locale.ROOT, "%.1f / %.1f MB", t.received / 1e6, t.total / 1e6)
        else -> String.format(Locale.ROOT, "%d / %d KB", t.received / 1000, maxOf(1L, t.total / 1000))
    }

    /**
     * "Receiving an image from MacBook Pro…" with a progress bar, while Nearclip is not on screen. Only the first post
     * shows the banner; progress updates are quiet. No setSilent: it would put these in one bundle with the sync
     * notification (NotificationCompat's "silent" group), hiding the bar. The channel itself makes no sound.
     */
    @SuppressLint("MissingPermission")
    fun transfer(context: Context, name: String, t: IncomingTransfer) {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return
        val percent = ((t.fraction ?: 0f) * 100).toInt()
        val n = NotificationCompat.Builder(context, CHANNEL_TRANSFERS)
            .setSmallIcon(R.drawable.ic_stat_nearclip)
            .setColor(IRIS)
            .setContentTitle(context.getString(R.string.receiving_image_from, name))
            .setContentText(progressText(context, t))
            .setProgress(100, percent, t.total <= 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openApp(context, 5))
            .build()
        transferProgressShown = true
        transferDoneFor = null
        try { nm.notify(ID_TRANSFER, n) } catch (_: SecurityException) {}
    }

    /** The image is in: "Copied from MacBook Pro" (or "Image from …" when it was not copied) for a few seconds. It
     *  replaces the progress notification at once with a banner; the thumbnail comes in a quiet second call. */
    @SuppressLint("MissingPermission")
    fun transferDone(context: Context, clipId: String, title: String, text: String, thumb: Bitmap?) {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return
        val update = transferDoneFor == clipId
        val n = NotificationCompat.Builder(context, CHANNEL_TRANSFERS)
            .setSmallIcon(R.drawable.ic_stat_nearclip)
            .setColor(IRIS)
            .setContentTitle(title)
            .setContentText(text)
            .apply { if (thumb != null) setLargeIcon(thumb) }
            .setOnlyAlertOnce(update)
            .setAutoCancel(true)
            .setTimeoutAfter(4_000)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openApp(context, 5))
            .build()
        transferProgressShown = false
        transferDoneFor = clipId
        try { nm.notify(ID_TRANSFER, n) } catch (_: SecurityException) {}
    }

    @SuppressLint("MissingPermission")
    fun transferFailed(context: Context, name: String) {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return
        val n = NotificationCompat.Builder(context, CHANNEL_TRANSFERS)
            .setSmallIcon(R.drawable.ic_stat_nearclip)
            .setColor(IRIS)
            .setContentTitle(context.getString(R.string.transfer_failed))
            .setContentText(context.getString(R.string.transfer_failed_body, name))
            .setAutoCancel(true)
            .setTimeoutAfter(8_000)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openApp(context, 5))
            .build()
        transferProgressShown = false
        transferDoneFor = null
        try { nm.notify(ID_TRANSFER, n) } catch (_: SecurityException) {}
    }

    /** Removes the progress notification (a "Copied from …" one stays until it times out). */
    fun cancelTransferProgress(context: Context) {
        if (!transferProgressShown) return
        transferProgressShown = false
        NotificationManagerCompat.from(context).cancel(ID_TRANSFER)
    }

    fun cancelTransfer(context: Context) {
        transferProgressShown = false
        transferDoneFor = null
        NotificationManagerCompat.from(context).cancel(ID_TRANSFER)
    }

    // ---------------------------------------------------------------- verification codes (PROTOCOL §6.7)

    /**
     * "Verification code from Junseo's iPhone · 482915 · Copy it?" with a Copy button, while Nearclip is not on screen.
     * The lock screen shows only that a code arrived. Codes expire quickly, and so does the notification.
     */
    @SuppressLint("MissingPermission")
    fun code(context: Context, clipId: String, name: String, code: String, expiresAt: Long) {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return
        val copy = PendingIntent.getBroadcast(
            context, 6,
            Intent(context, NotificationActionReceiver::class.java)
                .setAction(NotificationActionReceiver.ACTION_COPY_CODE)
                .putExtra(NotificationActionReceiver.EXTRA_CLIP_ID, clipId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val public = NotificationCompat.Builder(context, CHANNEL_CODES)
            .setSmallIcon(R.drawable.ic_stat_nearclip)
            .setColor(IRIS)
            .setContentTitle(context.getString(R.string.code_arrived_public))
            .build()
        val n = NotificationCompat.Builder(context, CHANNEL_CODES)
            .setSmallIcon(R.drawable.ic_stat_nearclip)
            .setColor(IRIS)
            .setContentTitle(context.getString(R.string.code_arrived_title, name))
            .setContentText(context.getString(R.string.code_arrived_text, code))
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setTimeoutAfter((expiresAt - System.currentTimeMillis()).coerceIn(1, Nearclip.CODE_OFFER_MS))
            .setContentIntent(openApp(context, 7))
            .addAction(R.drawable.ic_content_copy, context.getString(R.string.copy), copy)
            .build()
        try { nm.notify(ID_CODE, n) } catch (_: SecurityException) {}
    }

    fun cancelCode(context: Context) {
        NotificationManagerCompat.from(context).cancel(ID_CODE)
    }

    /** Once: Android 15+ hid a code from Nearclip; the fix is in Settings. */
    @SuppressLint("MissingPermission")
    fun codesHidden(context: Context) {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return
        val open = PendingIntent.getActivity(
            context, 8,
            MainActivity.routeIntent(context, Routes.SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, CHANNEL_CODES)
            .setSmallIcon(R.drawable.ic_stat_nearclip)
            .setColor(IRIS)
            .setContentTitle(context.getString(R.string.codes_hidden_title))
            .setContentText(context.getString(R.string.codes_hidden_text))
            .setStyle(NotificationCompat.BigTextStyle().bigText(context.getString(R.string.codes_hidden_text)))
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        try { nm.notify(ID_CODES_HIDDEN, n) } catch (_: SecurityException) {}
    }
}
