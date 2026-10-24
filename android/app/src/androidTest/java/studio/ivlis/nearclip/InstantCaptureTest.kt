package studio.ivlis.nearclip

import android.content.ClipData
import android.content.ClipboardManager
import android.os.PersistableBundle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import studio.ivlis.nearclip.runtime.ClipboardBridge
import studio.ivlis.nearclip.runtime.Nearclip
import studio.ivlis.nearclip.ui.MainActivity

/** Real background clipboard + live engine checks. Shizuku must be started and Nearclip allowed beforehand. */
@RunWith(AndroidJUnit4::class)
class InstantCaptureTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val runtime = Nearclip.get(context)
    private val clipboard = context.getSystemService(ClipboardManager::class.java)

    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)
    private fun historyContains(text: String) = runtime.engine.state.value.history.any { it.text == text }
    private fun waitUntil(message: String, condition: () -> Boolean) {
        val end = System.nanoTime() + 8_000_000_000L
        while (!condition() && System.nanoTime() < end) Thread.sleep(50)
        assertTrue(message, condition())
    }
    private fun copy(text: String, sensitive: Boolean = false, ours: Boolean = false) {
        val clip = ClipData.newPlainText("capture-test", text)
        clip.description.extras = PersistableBundle().apply {
            if (sensitive) putBoolean(ClipboardBridge.EXTRA_IS_SENSITIVE, true)
            if (ours) putString(ClipboardBridge.EXTRA_ORIGIN, "test-incoming-clip")
        }
        onMain { clipboard.setPrimaryClip(clip) }
    }

    @Test
    fun backgroundCaptureRespectsSensitiveMarkersPauseAndOptOut() {
        val original = runtime.settings.value
        assertTrue("finish onboarding before running this test", original.onboardingDone)
        waitUntil("start Shizuku and allow Nearclip before running this test") { runtime.capture.status.value.ready }
        ActivityScenario.launch(MainActivity::class.java).use {
            try {
                onMain {
                    runtime.settings.update { it.copy(sendOnOpen = false, copyNewestOnOpen = false) }
                    runtime.setPaused(false)
                    runtime.setInstantCapture(true)
                }
                waitUntil("listener did not start") { runtime.capture.status.value.listening }
                instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_HOME").close()
                waitUntil("Nearclip stayed in foreground") { !runtime.uiVisible }

                val ordinary = "capture-test-" + System.nanoTime()
                copy(ordinary)
                waitUntil("background copy missing from history") { historyContains(ordinary) }

                val secret = "capture-sensitive-" + System.nanoTime()
                copy(secret, sensitive = true)
                Thread.sleep(800)
                assertFalse("sensitive copy recorded", historyContains(secret))

                val incoming = "capture-ours-" + System.nanoTime()
                copy(incoming, ours = true)
                Thread.sleep(800)
                assertFalse("Nearclip's clipboard write was captured again", historyContains(incoming))

                onMain { runtime.setPaused(true) }
                waitUntil("pause left listener running") { !runtime.capture.status.value.listening }
                val paused = "capture-paused-" + System.nanoTime()
                copy(paused)
                Thread.sleep(800)
                assertFalse("copy recorded while paused", historyContains(paused))

                onMain { runtime.setPaused(false) }
                waitUntil("listener did not resume") { runtime.capture.status.value.listening }
                val resumed = "capture-resumed-" + System.nanoTime()
                copy(resumed)
                waitUntil("copy missing after resume") { historyContains(resumed) }

                onMain { runtime.setInstantCapture(false) }
                waitUntil("opt-out left listener running") { !runtime.capture.status.value.listening }
                val disabled = "capture-off-" + System.nanoTime()
                copy(disabled)
                Thread.sleep(800)
                assertFalse("copy recorded after opt-out", historyContains(disabled))
            } finally {
                onMain {
                    runtime.settings.update { original }
                    runtime.setPaused(original.paused)
                    runtime.ensureService()
                }
            }
        }
    }
}
