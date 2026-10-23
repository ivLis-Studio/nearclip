package studio.ivlis.nearclip.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.runtime.Nearclip
import studio.ivlis.nearclip.runtime.PairingUi
import studio.ivlis.nearclip.runtime.UiMessage
import studio.ivlis.nearclip.ui.devices.DevicesScreen
import studio.ivlis.nearclip.ui.home.HomeScreen
import studio.ivlis.nearclip.ui.onboarding.OnboardingScreen
import studio.ivlis.nearclip.ui.pairing.AddDeviceSheet
import studio.ivlis.nearclip.ui.pairing.ConnectByAddressDialog
import studio.ivlis.nearclip.ui.pairing.InviterPromptDialog
import studio.ivlis.nearclip.ui.pairing.MyQrScreen
import studio.ivlis.nearclip.ui.pairing.PairingFlowDialogs
import studio.ivlis.nearclip.ui.pairing.ScanScreen
import studio.ivlis.nearclip.ui.settings.LicensesScreen
import studio.ivlis.nearclip.ui.settings.SettingsActions
import studio.ivlis.nearclip.ui.settings.SettingsScreen

object Routes {
    const val ONBOARDING = "onboarding"
    const val HOME = "home"
    const val DEVICES = "devices"
    const val SETTINGS = "settings"
    const val LICENSES = "licenses"
    const val SCAN = "scan"
    const val MY_QR = "my_qr"
    /** Not a destination: opens the Add-device sheet. */
    const val ADD_DEVICE = "add_device"
}

@Composable
fun NearclipRoot(runtime: Nearclip, routeRequests: Flow<String>) {
    val context = LocalContext.current
    // Resolved when a message arrives, so a language change while the app is open is reflected.
    val resources by rememberUpdatedState(LocalResources.current)
    val snapshot by runtime.engine.state.collectAsStateWithLifecycle()
    val settings by runtime.settings.state.collectAsStateWithLifecycle()
    val pending by runtime.pendingDeletes.collectAsStateWithLifecycle()
    val pairing by runtime.pairing.collectAsStateWithLifecycle()
    val nav = rememberNavController()
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    var addDeviceOpen by rememberSaveable { mutableStateOf(false) }
    var addressOpen by rememberSaveable { mutableStateOf(false) }
    var pendingSave by remember { mutableStateOf<Clip?>(null) }
    val start = remember { if (runtime.settings.value.onboardingDone) Routes.HOME else Routes.ONBOARDING }

    fun show(message: String, action: String? = null, onAction: () -> Unit = {}) {
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            val r = snackbar.showSnackbar(message, actionLabel = action, duration = SnackbarDuration.Short)
            if (r == SnackbarResult.ActionPerformed) onAction()
        }
    }

    val storagePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        val clip = pendingSave
        pendingSave = null
        if (ok && clip != null) runtime.saveImage(clip)
    }

    fun saveImage(clip: Clip) {
        if (Build.VERSION.SDK_INT < 29 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingSave = clip
            storagePermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        } else {
            runtime.saveImage(clip)
        }
    }

    LaunchedEffect(Unit) {
        routeRequests.collect { route ->
            if (route == Routes.ADD_DEVICE) {
                addDeviceOpen = true
            } else if (nav.currentDestination?.route != route) {
                nav.navigate(route) { launchSingleTop = true }
            }
        }
    }

    LaunchedEffect(Unit) {
        runtime.messages.collect { m ->
            when (m) {
                is UiMessage.CopiedFrom -> show(resources.getString(R.string.copied_from, m.name))
                is UiMessage.Send -> show(Actions.sendMessage(context, m.outcome))
                is UiMessage.Deleted -> show(
                    resources.getQuantityString(R.plurals.deleted_clips, m.ids.size, m.ids.size),
                    resources.getString(R.string.undo),
                ) { runtime.undoDelete(m.ids) }
                UiMessage.Removed -> show(resources.getString(R.string.removed_message))
                is UiMessage.ImageSaved -> show(resources.getString(if (m.ok) R.string.image_saved else R.string.image_save_failed))
            }
        }
    }

    // Leave the QR screens once pairing went through; the success dialog takes over.
    LaunchedEffect(pairing) {
        val route = nav.currentDestination?.route
        if (pairing is PairingUi.Success && (route == Routes.MY_QR || route == Routes.SCAN)) nav.popBackStack()
    }

    NavHost(
        navController = nav,
        startDestination = start,
        enterTransition = { slideInHorizontally(tween(240)) { it / 8 } + fadeIn(tween(240)) },
        exitTransition = { fadeOut(tween(160)) },
        popEnterTransition = { fadeIn(tween(220)) },
        popExitTransition = { slideOutHorizontally(tween(220)) { it / 8 } + fadeOut(tween(200)) },
    ) {
        composable(Routes.ONBOARDING) {
            OnboardingScreen(
                snapshot = snapshot,
                onScan = { nav.navigate(Routes.SCAN) },
                onShowQr = { nav.navigate(Routes.MY_QR) },
                onPairNearby = { runtime.pairWithNearby(it) },
                onConnectByAddress = { addressOpen = true },
                onPairingMode = { runtime.engine.setPairingMode(it) },
                onRename = { runtime.engine.rename(it) },
                onFinish = {
                    runtime.completeOnboarding()
                    nav.navigate(Routes.HOME) { popUpTo(Routes.ONBOARDING) { inclusive = true } }
                },
            )
        }
        composable(Routes.HOME) {
            HomeScreen(
                snapshot = snapshot,
                settings = settings,
                pendingDeletes = pending,
                snackbarHost = snackbar,
                nameOf = { runtime.sourceName(it, snapshot) },
                platformOf = { c ->
                    if (c.src == snapshot.deviceId) "android"
                    else snapshot.members.firstOrNull { it.id == c.src }?.platform ?: c.sourcePlatform ?: ""
                },
                blobFile = { runtime.engine.blobFile(it) },
                onOpenDevices = { nav.navigate(Routes.DEVICES) { launchSingleTop = true } },
                onOpenSettings = { nav.navigate(Routes.SETTINGS) { launchSingleTop = true } },
                onAddDevice = { addDeviceOpen = true },
                onSendClipboard = {
                    scope.launch { show(Actions.sendMessage(context, runtime.sendFromClipboard())) }
                },
                onResume = { runtime.setPaused(false) },
                onCopy = { runtime.applyToClipboard(it, announce = false) },
                onTogglePin = { runtime.togglePin(it) },
                onDelete = { runtime.deleteWithUndo(setOf(it.id)) },
                onShare = { Actions.share(context, it, if (it.isImage) runtime.engine.blobFile(it) else null) },
                onOpenLink = { Actions.openLink(context, it) },
                onSaveImage = { saveImage(it) },
            )
        }
        composable(Routes.DEVICES) {
            DevicesScreen(
                snapshot = snapshot,
                onBack = { nav.popBackStack() },
                onAddDevice = { addDeviceOpen = true },
                onRename = { runtime.engine.rename(it) },
                onRemove = { runtime.engine.removeMember(it.id) },
                onLeave = { runtime.engine.leaveGroup() },
            )
        }
        composable(Routes.SETTINGS) {
            SettingsScreen(
                settings = settings,
                actions = SettingsActions(
                    setPaused = { runtime.setPaused(it) },
                    update = { runtime.settings.update(it) },
                    setStayConnected = { runtime.setStayConnected(it) },
                    clearHistory = { runtime.engine.clearHistory() },
                    openLicenses = { nav.navigate(Routes.LICENSES) { launchSingleTop = true } },
                ),
                onBack = { nav.popBackStack() },
            )
        }
        composable(Routes.LICENSES) { LicensesScreen(onBack = { nav.popBackStack() }) }
        composable(Routes.SCAN) {
            ScanScreen(
                onBack = { nav.popBackStack() },
                onScanned = { uri ->
                    nav.popBackStack()
                    runtime.joinWithUri(uri)
                },
            )
        }
        composable(Routes.MY_QR) {
            MyQrScreen(
                snapshot = snapshot,
                createTicket = { runtime.createTicket() },
                onPairingMode = { runtime.engine.setPairingMode(it) },
                onBack = { nav.popBackStack() },
            )
        }
    }

    if (addDeviceOpen) {
        AddDeviceSheet(
            snapshot = snapshot,
            onDismiss = { addDeviceOpen = false },
            onPairingMode = { runtime.engine.setPairingMode(it) },
            onScan = { addDeviceOpen = false; nav.navigate(Routes.SCAN) },
            onShowQr = { addDeviceOpen = false; nav.navigate(Routes.MY_QR) },
            onPairNearby = { addDeviceOpen = false; runtime.pairWithNearby(it) },
            onConnectByAddress = { addressOpen = true },
            onRename = { runtime.engine.rename(it) },
        )
    }
    if (addressOpen) {
        ConnectByAddressDialog(
            onDismiss = { addressOpen = false },
            onConnect = {
                addressOpen = false
                addDeviceOpen = false
                runtime.pairWithAddress(it)
            },
        )
    }
    snapshot.prompt?.let { prompt ->
        InviterPromptDialog(
            prompt,
            onDecline = { runtime.engine.answerPairPrompt(false) },
            onAdd = { runtime.engine.answerPairPrompt(true) },
        )
    }
    PairingFlowDialogs(
        state = pairing,
        onJoinLink = { (pairing as? PairingUi.ConfirmLink)?.let { runtime.joinWithUri(it.uri) } },
        onCancel = { runtime.cancelPairing() },
        onDismiss = { runtime.dismissPairing() },
    )
}
