package studio.ivlis.nearclip.runtime

import android.content.Context
import android.os.Build
import android.provider.Settings

object DeviceInfo {
    /** The name the user gave the phone (Settings › About), falling back to the model. */
    fun defaultName(context: Context): String {
        val named = try {
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
        } catch (_: Exception) {
            null
        }
        return (named?.takeIf { it.isNotBlank() } ?: model).trim().take(64)
    }

    val model: String get() = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"

    /** "Android 16"; RELEASE_OR_CODENAME (API 30+) also names preview builds. */
    val osLabel: String
        get() = "Android " + if (Build.VERSION.SDK_INT >= 30) Build.VERSION.RELEASE_OR_CODENAME else Build.VERSION.RELEASE

    fun isTablet(context: Context): Boolean = context.resources.configuration.smallestScreenWidthDp >= 600
}
