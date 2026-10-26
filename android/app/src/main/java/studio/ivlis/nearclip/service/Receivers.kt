package studio.ivlis.nearclip.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.Toast
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.runtime.Nearclip

/** Pause / Resume from the persistent notification; Decline from the pairing notification; Copy from a code. */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val rt = Nearclip.get(context)
        when (intent.action) {
            ACTION_PAUSE -> rt.setPaused(true)
            ACTION_RESUME -> rt.setPaused(false)
            ACTION_DECLINE_PAIRING -> rt.engine.answerPairPrompt(false)
            ACTION_COPY_CODE -> {
                val copied = intent.getStringExtra(EXTRA_CLIP_ID)?.let { rt.copyCode(it) } == true
                // Android 13 and later confirm a copy themselves.
                if (copied && Build.VERSION.SDK_INT < 33) Toast.makeText(context, R.string.copied, Toast.LENGTH_SHORT).show()
            }
        }
    }

    companion object {
        const val ACTION_PAUSE = "studio.ivlis.nearclip.action.PAUSE"
        const val ACTION_RESUME = "studio.ivlis.nearclip.action.RESUME"
        const val ACTION_DECLINE_PAIRING = "studio.ivlis.nearclip.action.DECLINE_PAIRING"
        const val ACTION_COPY_CODE = "studio.ivlis.nearclip.action.COPY_CODE"
        const val EXTRA_CLIP_ID = "studio.ivlis.nearclip.extra.CLIP_ID"
    }
}

/** Restarts the background connection after a reboot or an app update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            Nearclip.get(context).ensureService()
        }
    }
}
