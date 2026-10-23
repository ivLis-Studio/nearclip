package studio.ivlis.nearclip.ui

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.runtime.SendOutcome
import java.io.File

object Actions {
    fun share(context: Context, clip: Clip, file: File?) {
        val intent = if (clip.isImage && file != null) {
            val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
            Intent(Intent.ACTION_SEND).setType(clip.mime ?: "image/png").putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } else {
            Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, clip.text ?: "")
        }
        val chooser = Intent.createChooser(intent, null)
            .putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, arrayOf(ComponentName(context, SendActivity::class.java)))
        try { context.startActivity(chooser) } catch (_: ActivityNotFoundException) {}
    }

    fun openLink(context: Context, url: String): Boolean = try {
        context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri()).addCategory(Intent.CATEGORY_BROWSABLE))
        true
    } catch (_: Exception) {
        false
    }

    /**
     * Shows the system "Let Nearclip always run in the background?" dialog. Only on the user's tap, and optional
     * (onboarding, Settings › Battery optimization): the connectedDevice foreground service holds a persistent
     * LAN connection to the user's own devices, which Doze would otherwise cut while the screen is off.
     */
    @SuppressLint("BatteryLife")
    fun requestUnrestrictedBattery(context: Context) {
        runCatching {
            context.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, "package:${context.packageName}".toUri()))
        }
    }

    /** User-facing text for a send result (snackbar in the app, toast from background surfaces). */
    fun sendMessage(context: Context, outcome: SendOutcome): String = when (outcome) {
        is SendOutcome.Sent -> when {
            outcome.peers > 0 -> context.resources.getQuantityString(R.plurals.sent_to_devices, outcome.peers, outcome.peers)
            outcome.members > 0 -> context.getString(R.string.sent_saved)
            else -> context.getString(R.string.sent_no_devices)
        }
        SendOutcome.Paused -> context.getString(R.string.send_paused)
        SendOutcome.Empty -> context.getString(R.string.clipboard_empty)
        SendOutcome.Sensitive -> context.getString(R.string.clipboard_sensitive)
        SendOutcome.AlreadySynced -> context.getString(R.string.clipboard_already_synced)
        SendOutcome.TooLarge -> context.getString(R.string.too_large_to_sync)
        SendOutcome.Unreadable -> context.getString(R.string.image_unreadable)
        SendOutcome.ImagesOff -> context.getString(R.string.images_off)
        SendOutcome.Failed -> context.getString(R.string.send_failed)
    }
}
