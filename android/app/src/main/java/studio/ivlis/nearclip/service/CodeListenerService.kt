package studio.ivlis.nearclip.service

import android.content.ComponentName
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import studio.ivlis.nearclip.runtime.Nearclip

/**
 * Notification access for "Send verification codes to my devices" (runtime/CodeForwarding.kt). Only notifications of
 * text-message apps and KakaoTalk are looked at; only a code found in a new message leaves the phone.
 */
class CodeListenerService : NotificationListenerService() {
    override fun onListenerConnected() {
        connected = this
        Nearclip.get(this).codes.onListenerConnected()
    }

    override fun onListenerDisconnected() {
        if (connected === this) connected = null
        Nearclip.get(this).codes.onListenerDisconnected()
    }

    override fun onDestroy() {
        if (connected === this) connected = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        Nearclip.get(this).codes.onPosted(sbn)
    }

    companion object {
        /** The bound listener, if any (main thread). */
        @Volatile var connected: CodeListenerService? = null
            private set

        fun component(context: Context) = ComponentName(context, CodeListenerService::class.java)
    }
}
