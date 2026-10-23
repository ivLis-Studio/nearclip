package studio.ivlis.nearclip

import android.content.ClipData
import android.content.ClipboardManager
import android.os.PersistableBundle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import studio.ivlis.nearclip.runtime.ClipboardBridge
import studio.ivlis.nearclip.runtime.Nearclip
import studio.ivlis.nearclip.runtime.SendOutcome
import studio.ivlis.nearclip.ui.MainActivity

/**
 * Runs on a device against the real system clipboard and the live engine: a clip that a password manager
 * marks ClipDescription.EXTRA_IS_SENSITIVE is never sent or recorded, neither by "send on open" (window
 * focus) nor by "Send clipboard" (FAB, Quick Settings tile, notification action), while an ordinary clip
 * copied right after it goes out.
 */
@RunWith(AndroidJUnit4::class)
class SensitiveClipTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val clipboard = context.getSystemService(ClipboardManager::class.java)
    private val runtime = Nearclip.get(context)

    private fun copy(text: String, sensitive: Boolean) {
        val clip = ClipData.newPlainText("test", text)
        if (sensitive) {
            clip.description.extras = PersistableBundle().apply { putBoolean(ClipboardBridge.EXTRA_IS_SENSITIVE, true) }
        }
        instrumentation.runOnMainSync { clipboard.setPrimaryClip(clip) }
    }

    private fun inHistory(text: String) = runtime.engine.state.value.history.any { it.text == text }

    @Test
    fun sensitiveClipsAreNeverSentButOrdinaryClipsAre() {
        val secret = "nearclip-sensitive-" + System.nanoTime()
        copy(secret, sensitive = true)
        ActivityScenario.launch(MainActivity::class.java).use {
            // Gaining window focus runs "send on open", which must skip the sensitive clip.
            Thread.sleep(4_000)
            assertFalse("sensitive clip was recorded on open", inHistory(secret))

            val outcome = runBlocking { runtime.sendFromClipboard() }
            assertEquals(SendOutcome.Sensitive, outcome)
            Thread.sleep(1_000)
            assertFalse("sensitive clip was recorded on send", inHistory(secret))

            val ordinary = "nearclip-ordinary-" + System.nanoTime()
            copy(ordinary, sensitive = false)
            val sent = runBlocking { runtime.sendFromClipboard() }
            assertTrue("ordinary clip was not sent: $sent", sent is SendOutcome.Sent)
            assertTrue("ordinary clip missing from history", inHistory(ordinary))
        }
    }
}
