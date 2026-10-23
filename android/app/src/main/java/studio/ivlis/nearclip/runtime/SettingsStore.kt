package studio.ivlis.nearclip.runtime

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** User settings (DESIGN §4.6). Retention: 1, 7, 30 days or 0 = forever. */
data class AppSettings(
    val paused: Boolean = false,
    val autoApply: Boolean = true,
    val syncImages: Boolean = true,
    val sendOnOpen: Boolean = true,
    val copyNewestOnOpen: Boolean = true,
    val stayConnected: Boolean = true,
    val retentionDays: Int = 30,
    val onboardingDone: Boolean = false,
)

class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("nearclip.settings", Context.MODE_PRIVATE)
    private val _state = MutableStateFlow(load())
    val state: StateFlow<AppSettings> = _state.asStateFlow()
    val value: AppSettings get() = _state.value

    private fun load() = AppSettings(
        paused = prefs.getBoolean(PAUSED, false),
        autoApply = prefs.getBoolean(AUTO_APPLY, true),
        syncImages = prefs.getBoolean(SYNC_IMAGES, true),
        sendOnOpen = prefs.getBoolean(SEND_ON_OPEN, true),
        copyNewestOnOpen = prefs.getBoolean(COPY_NEWEST, true),
        stayConnected = prefs.getBoolean(STAY_CONNECTED, true),
        retentionDays = prefs.getInt(RETENTION, 30),
        onboardingDone = prefs.getBoolean(ONBOARDED, false),
    )

    @Synchronized
    fun update(transform: (AppSettings) -> AppSettings) {
        val next = transform(_state.value)
        prefs.edit {
            putBoolean(PAUSED, next.paused)
            putBoolean(AUTO_APPLY, next.autoApply)
            putBoolean(SYNC_IMAGES, next.syncImages)
            putBoolean(SEND_ON_OPEN, next.sendOnOpen)
            putBoolean(COPY_NEWEST, next.copyNewestOnOpen)
            putBoolean(STAY_CONNECTED, next.stayConnected)
            putInt(RETENTION, next.retentionDays)
            putBoolean(ONBOARDED, next.onboardingDone)
        }
        _state.value = next
    }

    /** ClipDescription timestamp of the last clipboard content we looked at (send-on-open change detection). */
    var lastClipboardStamp: Long
        get() = prefs.getLong(CLIPBOARD_STAMP, 0L)
        set(v) = prefs.edit { putLong(CLIPBOARD_STAMP, v) }

    /** Newest clip timestamp this device wrote to the system clipboard. */
    var lastAppliedTs: Long
        get() = prefs.getLong(APPLIED_TS, 0L)
        set(v) = prefs.edit { putLong(APPLIED_TS, v) }

    private companion object {
        const val PAUSED = "paused"
        const val AUTO_APPLY = "autoApply"
        const val SYNC_IMAGES = "syncImages"
        const val SEND_ON_OPEN = "sendOnOpen"
        const val COPY_NEWEST = "copyNewestOnOpen"
        const val STAY_CONNECTED = "stayConnected"
        const val RETENTION = "retentionDays"
        const val ONBOARDED = "onboardingDone"
        const val CLIPBOARD_STAMP = "clipboardStamp"
        const val APPLIED_TS = "appliedTs"
    }
}
