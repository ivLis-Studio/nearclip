package studio.ivlis.nearclip.runtime

import android.app.AppOpsManager
import android.app.Notification
import android.content.Context
import android.content.Intent
import android.content.res.Resources
import android.os.Build
import android.os.Process
import android.provider.Settings
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.ivlis.nearclip.core.model.OneTimeCode
import studio.ivlis.nearclip.service.CodeListenerService

/** Where "Send verification codes to my devices" stands (see [CodeForwarding]). */
data class CodeStatus(
    /** Notification access is on for Nearclip. */
    val access: Boolean = false,
    /** Android 15 and later hide codes from notification listeners they do not trust with them. */
    val mayHide: Boolean = Build.VERSION.SDK_INT >= 35,
    /** Nearclip may see codes: the shell allowed it, or nothing hides them. */
    val unhidden: Boolean = Build.VERSION.SDK_INT < 35,
    /** Shizuku is running the commands that let Nearclip see codes. */
    val unhiding: Boolean = false,
    /** Letting Nearclip see codes through Shizuku did not work. */
    val unhideFailed: Boolean = false,
)

/**
 * "Send verification codes to my devices" (PROTOCOL §6.7), on by default. With notification access, a 4–8 digit code in
 * a new text message or KakaoTalk message ([OneTimeCode]) goes to the other devices as a code clip, which they offer to
 * copy. Only the code leaves the phone: the message, its sender and every other notification stay here.
 *
 * Android 15 hides codes from the notification listeners it does not trust with them: it replaces the text with
 * "Sensitive notification content hidden". The shell can trust Nearclip (app op RECEIVE_SENSITIVE_NOTIFICATIONS):
 * through Shizuku with one tap in Settings, or with one adb command. Android decides when it binds the listener, so the
 * listener is bound again afterwards.
 */
class CodeForwarding(private val rt: Nearclip) {
    private val app = rt.app
    private val _status = MutableStateFlow(CodeStatus())
    val status: StateFlow<CodeStatus> = _status.asStateFlow()

    /** Codes sent lately, so that a notification posted twice or updated sends its code once. Main thread. */
    private val recent = LinkedHashMap<String, Long>()
    /** Whether Android looked at a permission that lets Nearclip see codes when it last bound the listener. */
    @Volatile private var boundUnhidden = false
    private var reboundAt = 0L
    /** "Let Nearclip see codes" was tapped and Shizuku is asking whether to allow Nearclip first. */
    private var unhideWhenAllowed = false

    /** The text Android puts in place of a hidden notification, in the phone's language. */
    private val hiddenText: String? by lazy {
        val res = Resources.getSystem()
        val id = res.getIdentifier("redacted_notification_message", "string", "android")
        if (id == 0) null else runCatching { res.getString(id) }.getOrNull()?.takeIf { it.isNotBlank() }
    }

    /** Checks notification access and the Android 15 permission again (on resume, and after the listener binds). */
    fun refresh() {
        val access = hasAccess(app)
        val unhidden = canSeeCodes(app)
        _status.update { it.copy(access = access, unhidden = unhidden) }
        // Allowed with adb while the listener was bound: bind it again, so that Android looks again.
        if (access && unhidden && !boundUnhidden && CodeListenerService.connected != null) rebind()
    }

    fun onListenerConnected() {
        boundUnhidden = canSeeCodes(app)
        refresh()
    }

    fun onListenerDisconnected() = refresh()

    /** A notification was posted or updated (main thread). */
    fun onPosted(sbn: StatusBarNotification) {
        val s = rt.settings.value
        if (!s.forwardCodes || !s.onboardingDone || s.paused) return
        if (!isMessagingApp(sbn.packageName)) return
        val n = sbn.notification ?: return
        if (sbn.isOngoing || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (isHidden(n)) {
            onHidden()
            return
        }
        val (text, at) = newestMessage(n, sbn.postTime) ?: return
        val now = System.currentTimeMillis()
        if (now - at > FRESH_MS) return
        val code = OneTimeCode.find(text) ?: return
        if (s.codesHidden) rt.settings.update { it.copy(codesHidden = false) }
        recent.entries.removeAll { now - it.value > REPEAT_MS }
        if (recent.containsKey(code)) return
        recent[code] = now
        rt.engine.log("verification code in a message from ${sbn.packageName}: sending it") // the code itself is never logged
        rt.scope.launch { rt.sendCode(code) }
    }

    /** "Let Nearclip see codes" through Shizuku; asks Shizuku to allow Nearclip first when needed. */
    fun unhide() {
        when (rt.capture.status.value.setup) {
            CaptureSetup.READY -> runUnhide()
            CaptureSetup.NEEDS_PERMISSION -> {
                unhideWhenAllowed = true
                rt.capture.requestPermission()
            }
            else -> rt.capture.refresh() // the sheet offers to install or open Shizuku
        }
    }

    /** Shizuku answered "Allow Nearclip?" (asked here or by instant capture). */
    fun onShizukuPermission(granted: Boolean) {
        if (granted && unhideWhenAllowed) runUnhide()
        unhideWhenAllowed = false
    }

    private fun runUnhide() {
        if (_status.value.unhiding) return
        _status.update { it.copy(unhiding = true, unhideFailed = false) }
        rt.scope.launch {
            val user = (Process.myUid() / PER_USER_RANGE).toString()
            val component = CodeListenerService.component(app).flattenToString()
            val ok = rt.capture.runShell("cmd", "appops", "set", "--user", user, app.packageName, OP_NAME, "allow")
            if (ok) {
                // Turning access off and on again makes Android look at Nearclip again (and turns it on if it was off).
                rt.capture.runShell("cmd", "notification", "disallow_listener", component, user)
                rt.capture.runShell("cmd", "notification", "allow_listener", component, user)
            }
            delay(400)
            val unhidden = canSeeCodes(app)
            if (ok && unhidden) rt.settings.update { it.copy(codesHidden = false) }
            _status.update { it.copy(unhiding = false, unhideFailed = !(ok && unhidden)) }
            refresh()
        }
    }

    private fun onHidden() {
        rt.engine.log("a verification code was hidden from Nearclip")
        val now = System.currentTimeMillis()
        // Allowed already but bound before that: bind again (once a minute at most; some phones keep hiding).
        if (canSeeCodes(app) && now - reboundAt > 60_000) {
            rebind()
            if (!boundUnhidden) return
        }
        if (!rt.settings.value.codesHidden) rt.settings.update { it.copy(codesHidden = true) }
        if (!rt.settings.codesHiddenNotified) {
            rt.settings.codesHiddenNotified = true
            Notifications.codesHidden(app)
        }
        refresh()
    }

    private fun rebind() {
        val service = CodeListenerService.connected ?: return
        reboundAt = System.currentTimeMillis()
        rt.engine.log("verification codes: binding the notification listener again")
        runCatching { service.requestUnbind() }
        rt.scope.launch {
            delay(800)
            runCatching { NotificationListenerService.requestRebind(CodeListenerService.component(app)) }
        }
    }

    private fun isMessagingApp(pkg: String): Boolean =
        pkg in MESSAGING_APPS || pkg == runCatching { Telephony.Sms.getDefaultSmsPackage(app) }.getOrNull()

    /** Android replaced the content of this notification (Android 15+): title, text and messages alike. */
    private fun isHidden(n: Notification): Boolean {
        val hidden = hiddenText ?: return false
        if (Build.VERSION.SDK_INT < 35) return false
        val ex = n.extras
        return listOf(Notification.EXTRA_TEXT, Notification.EXTRA_BIG_TEXT).any { ex.getCharSequence(it)?.toString()?.contains(hidden) == true } ||
            NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)?.messages?.any { it.text?.toString()?.contains(hidden) == true } == true
    }

    /**
     * The newest message a notification shows and when it came. Messages the user sent (no sender) are not looked at:
     * a code typed in a reply is not a code that arrived.
     */
    private fun newestMessage(n: Notification, posted: Long): Pair<String, Long>? {
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)
        if (style != null) {
            val m = style.messages.lastOrNull() ?: return null
            if (m.person == null) return null
            val text = m.text?.toString()?.takeIf { it.isNotBlank() } ?: return null
            return text to (m.timestamp.takeIf { it > 0 } ?: posted)
        }
        val ex = n.extras
        val text = ex.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: ex.getCharSequence(Notification.EXTRA_TEXT)
            ?: ex.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.lastOrNull()
        val s = text?.toString()?.takeIf { it.isNotBlank() } ?: return null
        return s to (n.`when`.takeIf { it > 0 } ?: posted)
    }

    companion object {
        /** The app op that lets a notification listener see codes on Android 15+, as `cmd appops` names it. */
        const val OP_NAME = "RECEIVE_SENSITIVE_NOTIFICATIONS"
        private const val OP = "android:receive_sensitive_notifications"
        private const val PER_USER_RANGE = 100_000
        /** A message older than this is not looked at (a notification posted again later, or caught up). */
        private const val FRESH_MS = 10 * 60_000L
        private const val REPEAT_MS = 5 * 60_000L

        /** Text-message and chat apps whose notifications are read; the default SMS app always counts. */
        private val MESSAGING_APPS = setOf(
            "com.google.android.apps.messaging", // Google Messages
            "com.samsung.android.messaging", // Samsung Messages
            "com.android.mms", // many phone makers' SMS apps
            "com.android.messaging", // AOSP Messaging
            "com.kakao.talk", // KakaoTalk
        )

        fun hasAccess(context: Context): Boolean =
            NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)

        /** Whether Android 15+ lets Nearclip see codes (nothing hides them before). */
        fun canSeeCodes(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < 35) return true
            return try {
                val ops = context.getSystemService(AppOpsManager::class.java)
                ops.unsafeCheckOpNoThrow(OP, Process.myUid(), context.packageName) == AppOpsManager.MODE_ALLOWED
            } catch (_: Exception) {
                false
            }
        }

        /** What to run on a computer when Shizuku is not used. */
        fun adbCommand(context: Context): String = "adb shell cmd appops set ${context.packageName} $OP_NAME allow"

        /** Notification access for Nearclip (its own page on Android 11+). */
        fun openAccessSettings(context: Context) {
            val component = CodeListenerService.component(context).flattenToString()
            val own = if (Build.VERSION.SDK_INT >= 30) {
                Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                    .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, component)
            } else null
            for (intent in listOfNotNull(own, Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))) {
                try {
                    context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    return
                } catch (_: Exception) {
                }
            }
        }

        /** App info, where "Allow restricted settings" is (in its ⋮ menu). */
        fun openAppInfo(context: Context) {
            runCatching {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", context.packageName, null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
        }

        /**
         * Android 13+ greys out notification access for an app installed from a file until "Allow restricted settings"
         * is chosen in its App info; installed from Google Play, it does not.
         */
        fun mayBeRestricted(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < 33) return false
            val installer = runCatching { context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName }.getOrNull()
            return installer != "com.android.vending"
        }
    }
}
