package studio.ivlis.nearclip.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.runtime.Nearclip
import studio.ivlis.nearclip.ui.theme.NearclipTheme

/** The single activity: history, devices, pairing and settings; handles nearclip://pair links. */
class MainActivity : ComponentActivity() {
    private val routeRequests = Channel<String>(Channel.BUFFERED)
    private var checkOnFocus = false
    private lateinit var runtime: Nearclip

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        runtime = Nearclip.get(this)
        if (savedInstanceState == null) handleIntent(intent)
        setContent {
            NearclipTheme {
                NearclipRoot(runtime, routeRequests.receiveAsFlow())
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        runtime.setUiVisible(true)
        checkOnFocus = true
        if (runtime.settings.value.onboardingDone) runtime.ensureService()
    }

    override fun onStop() {
        runtime.setUiVisible(false)
        super.onStop()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Android only lets the focused app read the clipboard: this is where "send on open" happens.
        if (hasFocus && checkOnFocus) {
            checkOnFocus = false
            runtime.onAppOpened()
        }
    }

    private fun handleIntent(intent: Intent?) {
        intent ?: return
        if (intent.action == Intent.ACTION_VIEW) {
            val uri = intent.data?.toString()?.let { PairingUri.parse(it) }
            if (uri != null) runtime.openPairingLink(uri)
        }
        intent.getStringExtra(EXTRA_ROUTE)?.let { routeRequests.trySend(it) }
    }

    companion object {
        const val EXTRA_ROUTE = "studio.ivlis.nearclip.extra.ROUTE"

        fun routeIntent(context: Context, route: String): Intent =
            Intent(context, MainActivity::class.java).putExtra(EXTRA_ROUTE, route).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}
