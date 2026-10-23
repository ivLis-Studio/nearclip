package studio.ivlis.nearclip.ui.onboarding

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.engine.DiscoveredService
import studio.ivlis.nearclip.core.engine.EngineSnapshot
import studio.ivlis.nearclip.ui.Actions
import studio.ivlis.nearclip.ui.components.LogoTile
import studio.ivlis.nearclip.ui.components.Sym
import studio.ivlis.nearclip.ui.pairing.AddDeviceContent
import studio.ivlis.nearclip.ui.theme.LocalReduceMotion

/** First launch (DESIGN §4.1): Welcome → Permissions → Add your devices; skippable after step 1. */
@Composable
fun OnboardingScreen(
    snapshot: EngineSnapshot,
    initialStep: Int = 0,
    onScan: () -> Unit,
    onShowQr: () -> Unit,
    onPairNearby: (DiscoveredService) -> Unit,
    onConnectByAddress: () -> Unit,
    onPairingMode: (Boolean) -> Unit,
    onRename: (String) -> Unit,
    onFinish: () -> Unit,
) {
    var step by rememberSaveable { mutableIntStateOf(initialStep) }
    val reduceMotion = LocalReduceMotion.current
    BackHandler(enabled = step > 0) { step-- }
    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surface)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .height(56.dp)
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            StepDots(step, 3, Modifier.padding(start = 12.dp))
            Spacer(Modifier.weight(1f))
            if (step > 0) TextButton(onClick = onFinish) { Text(stringResource(R.string.skip)) }
        }
        AnimatedContent(
            targetState = step,
            transitionSpec = {
                val dir = if (targetState > initialState) 1 else -1
                if (reduceMotion) fadeIn(tween(0)) togetherWith fadeOut(tween(0))
                else (slideInHorizontally(tween(240)) { it / 6 * dir } + fadeIn(tween(240))) togetherWith
                    (slideOutHorizontally(tween(200)) { -it / 6 * dir } + fadeOut(tween(160)))
            },
            modifier = Modifier.weight(1f),
            label = "onboarding",
        ) { s ->
            when (s) {
                0 -> WelcomeStep(onNext = { step = 1 })
                1 -> PermissionsStep(onNext = { step = 2 })
                else -> AddDevicesStep(snapshot, onScan, onShowQr, onPairNearby, onConnectByAddress, onPairingMode, onRename, onFinish)
            }
        }
    }
}

@Composable
private fun StepDots(step: Int, count: Int, modifier: Modifier = Modifier) {
    val label = stringResource(R.string.step_of, step + 1, count)
    Row(modifier.semantics { contentDescription = label }, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        repeat(count) { i ->
            Box(
                Modifier
                    .height(6.dp)
                    .width(if (i == step) 22.dp else 6.dp)
                    .clip(CircleShape)
                    .background(if (i == step) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant),
            )
        }
    }
}

@Composable
private fun WelcomeStep(onNext: () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        LogoTile(112.dp)
        Spacer(Modifier.height(36.dp))
        Text(
            stringResource(R.string.tagline_display),
            style = MaterialTheme.typography.displaySmall,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(Modifier.height(16.dp))
        Text(
            stringResource(R.string.welcome_body),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 420.dp),
        )
        Spacer(Modifier.height(28.dp))
        Pills()
        Spacer(Modifier.weight(1.2f))
        Button(
            onClick = onNext,
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 420.dp)
                .heightIn(min = 56.dp),
        ) { Text(stringResource(R.string.get_started), style = MaterialTheme.typography.titleMedium) }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun Pill(icon: Int, text: String) {
    Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = CircleShape) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(icon, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer)
            Spacer(Modifier.width(6.dp))
            Text(text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSecondaryContainer, maxLines = 1, softWrap = false)
        }
    }
}

/** The two promises side by side, wrapping as whole pills on narrow screens or large text. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Pills() {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Pill(R.drawable.ic_lock, stringResource(R.string.pill_encrypted))
        Pill(R.drawable.ic_wifi, stringResource(R.string.pill_local))
    }
}

@Composable
private fun PermissionsStep(onNext: () -> Unit) {
    val context = LocalContext.current
    var notifications by rememberSaveable { mutableStateOf(false) }
    var battery by rememberSaveable { mutableStateOf(false) }
    LifecycleResumeEffect(Unit) {
        notifications = NotificationManagerCompat.from(context).areNotificationsEnabled()
        battery = context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true
        onPauseOrDispose {}
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        notifications = NotificationManagerCompat.from(context).areNotificationsEnabled()
    }
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp),
    ) {
        Spacer(Modifier.height(24.dp))
        Text(stringResource(R.string.permissions_title), style = MaterialTheme.typography.headlineMedium, modifier = Modifier.semantics { heading() })
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.permissions_body), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(28.dp))
        PermissionCard(
            icon = R.drawable.ic_notifications,
            title = stringResource(R.string.perm_notifications),
            reason = stringResource(R.string.perm_notifications_reason),
            granted = notifications,
            onAllow = {
                if (Build.VERSION.SDK_INT >= 33) {
                    launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    runCatching {
                        context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
                    }
                }
            },
        )
        Spacer(Modifier.height(12.dp))
        PermissionCard(
            icon = R.drawable.ic_battery_charging_full,
            title = stringResource(R.string.perm_battery),
            reason = stringResource(R.string.perm_battery_reason),
            granted = battery,
            onAllow = { Actions.requestUnrestrictedBattery(context) },
        )
        Spacer(Modifier.weight(1f))
        Spacer(Modifier.height(24.dp))
        Button(
            onClick = onNext,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp),
        ) { Text(stringResource(R.string.continue_label), style = MaterialTheme.typography.titleMedium) }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun PermissionCard(icon: Int, title: String, reason: String, granted: Boolean, onAllow: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(24.dp), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(start = 20.dp, top = 18.dp, bottom = 18.dp, end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.secondaryContainer),
                contentAlignment = Alignment.Center,
            ) { Sym(icon, null, tint = MaterialTheme.colorScheme.onSecondaryContainer) }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(reason, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(12.dp))
            if (granted) {
                Sym(R.drawable.ic_check_circle_filled, stringResource(R.string.allowed), Modifier.size(28.dp), tint = MaterialTheme.colorScheme.primary)
            } else {
                FilledTonalButton(onClick = onAllow) { Text(stringResource(R.string.allow)) }
            }
        }
    }
}

@Composable
private fun AddDevicesStep(
    snapshot: EngineSnapshot,
    onScan: () -> Unit,
    onShowQr: () -> Unit,
    onPairNearby: (DiscoveredService) -> Unit,
    onConnectByAddress: () -> Unit,
    onPairingMode: (Boolean) -> Unit,
    onRename: (String) -> Unit,
    onFinish: () -> Unit,
) {
    androidx.compose.runtime.DisposableEffect(Unit) {
        onPairingMode(true)
        onDispose { onPairingMode(false) }
    }
    val paired = snapshot.otherMembers.isNotEmpty()
    Column(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState()),
        ) {
            Spacer(Modifier.height(24.dp))
            Text(
                stringResource(R.string.add_devices_title),
                style = MaterialTheme.typography.headlineMedium,
                modifier = Modifier
                    .padding(horizontal = 24.dp)
                    .semantics { heading() },
            )
            Spacer(Modifier.height(8.dp))
            Text(
                stringResource(R.string.add_devices_body),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            Spacer(Modifier.height(24.dp))
            AddDeviceContent(snapshot, onScan, onShowQr, onPairNearby, onConnectByAddress, onRename, showTitle = false)
        }
        Box(Modifier.padding(24.dp)) {
            if (paired) {
                Button(
                    onClick = onFinish,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp),
                ) { Text(stringResource(R.string.done), style = MaterialTheme.typography.titleMedium) }
            } else {
                TextButton(
                    onClick = onFinish,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp),
                ) { Text(stringResource(R.string.skip_for_now), style = MaterialTheme.typography.titleMedium) }
            }
        }
    }
}
