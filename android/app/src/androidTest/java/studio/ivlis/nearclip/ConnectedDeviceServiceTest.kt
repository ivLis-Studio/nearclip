package studio.ivlis.nearclip

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.runtime.Nearclip
import studio.ivlis.nearclip.service.SyncService
import studio.ivlis.nearclip.ui.MainActivity

/**
 * Opt-in integration test against a separate real protocol peer. Run only on a disposable emulator with
 * POST_NOTIFICATIONS granted. Supply pairingUri, expectedText and (optionally) reviewCapture=true.
 * The capture mode holds each real app state on screen for the foreground-service review video.
 * Setup uses app APIs; clipboard payloads still travel through the normal encrypted network protocol.
 */
@RunWith(AndroidJUnit4::class)
class ConnectedDeviceServiceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val runtime = Nearclip.get(context)

    private fun awaitState(message: String, timeout: Long = 30_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeout
        while (!condition() && System.currentTimeMillis() < deadline) Thread.sleep(100)
        assertTrue(message, condition())
    }

    @Suppress("DEPRECATION")
    private fun service() = context.getSystemService(ActivityManager::class.java)
        .getRunningServices(Int.MAX_VALUE).firstOrNull { it.service.className == SyncService::class.java.name }

    @Test
    fun receivesPeerDataInBackgroundAndStopsWhenDisabled() {
        val args = InstrumentationRegistry.getArguments()
        val link = args.getString("pairingUri")
        val text = args.getString("expectedText")
        assumeTrue("requires a dedicated peer and disposable emulator", link != null && text != null)
        val invite = requireNotNull(PairingUri.parse(requireNotNull(link)))
        val capture = args.getString("reviewCapture") == "true"
        val original = runtime.settings.value
        try {
            // This test owns its disposable installation; no notification access, Shizuku or remote login.
            runtime.settings.update { it.copy(onboardingDone = true, paused = false, stayConnected = true,
                remoteEnabled = false, instantCapture = false, forwardCodes = false,
                sendOnOpen = false, copyNewestOnOpen = false) }
            ActivityScenario.launch<MainActivity>(MainActivity.routeIntent(context, "settings")).use {
                instrumentation.runOnMainSync { runtime.ensureService(); runtime.joinWithUri(invite) }
                awaitState("connected-device foreground service did not start") { service()?.foreground == true }
                if (Build.VERSION.SDK_INT >= 29) {
                    val info = context.packageManager.getServiceInfo(ComponentName(context, SyncService::class.java), 0)
                    assertTrue(info.foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE != 0)
                }
                awaitState("external peer did not pair") { runtime.engine.state.value.otherMembers.any { it.id == invite.inviterId } }
                instrumentation.runOnMainSync { runtime.dismissPairing() }
                awaitState("external peer is not connected") { invite.inviterId in runtime.engine.state.value.online }
                val existingImages = runtime.engine.state.value.history.filter { it.kind == "image" }.map { it.id }.toSet()
                if (capture) Thread.sleep(8_000)

                // Launching HOME moves the actual Activity out of the foreground; it does not fabricate a UI.
                context.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                awaitState("Nearclip activity did not leave the foreground") { !runtime.uiVisible }
                assertTrue("service stopped with the activity", service()?.foreground == true)
                awaitState("encrypted peer text was not received in the background", 60_000) {
                    runtime.engine.state.value.history.any { it.text == text }
                }
                if (capture) {
                    awaitState("peer image was not received in the background", 60_000) {
                        runtime.engine.state.value.history.any { it.kind == "image" && it.id !in existingImages }
                    }
                    Thread.sleep(4_000)
                    context.startActivity(MainActivity.routeIntent(context, "home").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    Thread.sleep(8_000)
                    context.startActivity(MainActivity.routeIntent(context, "settings").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    Thread.sleep(4_000)
                }
                instrumentation.runOnMainSync { runtime.setStayConnected(false) }
                awaitState("foreground service did not stop after opting out") { service() == null }
                if (capture) Thread.sleep(5_000)
            }
        } finally {
            runtime.settings.update { original }
            instrumentation.runOnMainSync { runtime.ensureService() }
        }
    }
}
