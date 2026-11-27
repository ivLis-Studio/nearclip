package studio.ivlis.nearclip

import android.content.ClipData
import android.content.Intent
import android.content.ClipboardManager
import android.os.Build
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
        val end = System.nanoTime() + 15_000_000_000L
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

    private fun assertHelperStopped() {
        // A status flag alone is insufficient: verify the privileged process actually exited.
        val output = instrumentation.uiAutomation.executeShellCommand("ps -A -o NAME").use {
            android.os.ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().readText()
        }
        assertFalse("privileged clipboard helper survived opt-out", output.lineSequence().any {
            it.trim() == "studio.ivlis.nearclip:clipboard"
        })
    }

    @Test
    fun backgroundCaptureRespectsSensitiveMarkersPauseAndOptOut() {
        val original = runtime.settings.value
        try {
            if (InstrumentationRegistry.getArguments().getString("prepareOnboarding") == "true") {
                // Only opt in on an explicitly selected disposable test installation.
                runtime.settings.update { it.copy(onboardingDone = true, remoteEnabled = false, forwardCodes = false) }
            }
            assertTrue("finish onboarding before running this test", runtime.settings.value.onboardingDone)
            waitUntil("start Shizuku and allow Nearclip before running this test") { runtime.capture.status.value.ready }
            ActivityScenario.launch(MainActivity::class.java).use {
                onMain {
                    runtime.settings.update { it.copy(sendOnOpen = false, copyNewestOnOpen = false) }
                    runtime.setPaused(false)
                    runtime.setInstantCapture(true)
                }
                waitUntil("listener did not start") { runtime.capture.status.value.listening }
                context.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
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
                assertHelperStopped()

                onMain { runtime.setPaused(false) }
                waitUntil("listener did not resume") { runtime.capture.status.value.listening }
                val resumed = "capture-resumed-" + System.nanoTime()
                copy(resumed)
                waitUntil("copy missing after resume") { historyContains(resumed) }

                if (Build.VERSION.SDK_INT >= 29) {
                    // Simulate helper death independently of the Shizuku server and verify a clean rebind.
                    val helper = instrumentation.uiAutomation.executeShellCommand("pidof studio.ivlis.nearclip:clipboard").use {
                        android.os.ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().readText().trim()
                    }
                    assertTrue("privileged helper not running", helper.matches(Regex("[0-9]+")))
                    instrumentation.uiAutomation.executeShellCommand("kill $helper").close()
                    waitUntil("helper death was not detected") { !runtime.capture.status.value.listening && runtime.capture.status.value.failed }
                    runtime.capture.refresh()
                    waitUntil("helper did not reconnect") { runtime.capture.status.value.listening }
                    val reconnected = "capture-reconnected-" + System.nanoTime()
                    copy(reconnected)
                    waitUntil("copy missing after helper restart") { historyContains(reconnected) }
                }

                onMain { runtime.setInstantCapture(false) }
                waitUntil("opt-out left listener running") { !runtime.capture.status.value.listening }
                val disabled = "capture-off-" + System.nanoTime()
                copy(disabled)
                Thread.sleep(800)
                assertFalse("copy recorded after opt-out", historyContains(disabled))
                assertHelperStopped()
            }
        } finally {
            onMain {
                runtime.settings.update { original }
                runtime.setPaused(original.paused)
                runtime.ensureService()
            }
        }
    }
}
