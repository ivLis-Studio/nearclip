package studio.ivlis.nearclip.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import studio.ivlis.nearclip.runtime.Nearclip
import studio.ivlis.nearclip.runtime.SendOutcome

/**
 * Transparent, focus-taking activity for sending from background surfaces (DESIGN §5 Android): the Quick
 * Settings tile and notification action (reads the clipboard once the window has focus), the share sheet
 * (text, images) and the text-selection menu "Send to my devices". Finishes right away with a toast.
 */
class SendActivity : ComponentActivity() {
    private lateinit var runtime: Nearclip
    private var started = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        runtime = Nearclip.get(this)
        if (savedInstanceState != null) {
            close()
            return
        }
        when (intent.action) {
            Intent.ACTION_SEND -> handleShare()
            Intent.ACTION_PROCESS_TEXT -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                run { if (text.isNullOrBlank()) SendOutcome.Empty else runtime.sendText(text) }
            }
            ACTION_SEND_CLIPBOARD -> Unit // waits for window focus
            else -> close()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && intent.action == ACTION_SEND_CLIPBOARD && !started) {
            run { runtime.sendFromClipboard() }
        }
    }

    private fun handleShare() {
        val type = intent.type ?: ""
        when {
            type.startsWith("image/") -> {
                val uri = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                run { if (uri == null) SendOutcome.Empty else runtime.sendImage(uri) }
            }
            else -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                run { if (text.isNullOrBlank()) SendOutcome.Empty else runtime.sendText(text) }
            }
        }
    }

    private fun run(block: suspend () -> SendOutcome) {
        if (started) return
        started = true
        lifecycleScope.launch {
            val outcome = block()
            Toast.makeText(applicationContext, Actions.sendMessage(applicationContext, outcome), Toast.LENGTH_SHORT).show()
            close()
        }
    }

    private fun close() {
        finish()
        if (Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(Activity.OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    companion object {
        const val ACTION_SEND_CLIPBOARD = "studio.ivlis.nearclip.action.SEND_CLIPBOARD"

        fun clipboardIntent(context: Context): Intent = Intent(context, SendActivity::class.java)
            .setAction(ACTION_SEND_CLIPBOARD)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
    }
}
