package studio.ivlis.nearclip.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import studio.ivlis.nearclip.runtime.Nearclip

/** Pause / Resume from the persistent notification; Decline from the pairing notification. */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val rt = Nearclip.get(context)
        when (intent.action) {
            ACTION_PAUSE -> rt.setPaused(true)
            ACTION_RESUME -> rt.setPaused(false)
            ACTION_DECLINE_PAIRING -> rt.engine.answerPairPrompt(false)
        }
    }

    companion object {
        const val ACTION_PAUSE = "studio.ivlis.nearclip.action.PAUSE"
        const val ACTION_RESUME = "studio.ivlis.nearclip.action.RESUME"
        const val ACTION_DECLINE_PAIRING = "studio.ivlis.nearclip.action.DECLINE_PAIRING"
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
