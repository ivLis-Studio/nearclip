package studio.ivlis.nearclip.ui.settings

import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import studio.ivlis.nearclip.BuildConfig
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.runtime.AppSettings
import studio.ivlis.nearclip.ui.Actions
import studio.ivlis.nearclip.ui.components.SectionHeader
import studio.ivlis.nearclip.ui.components.SettingsGroup
import studio.ivlis.nearclip.ui.components.SettingsRow
import studio.ivlis.nearclip.ui.components.Sym

class SettingsActions(
    val setPaused: (Boolean) -> Unit,
    val update: ((AppSettings) -> AppSettings) -> Unit,
    val setStayConnected: (Boolean) -> Unit,
    val clearHistory: () -> Unit,
    val openLicenses: () -> Unit,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(settings: AppSettings, actions: SettingsActions, onBack: () -> Unit) {
    val context = LocalContext.current
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var retentionOpen by rememberSaveable { mutableStateOf(false) }
    var clearOpen by rememberSaveable { mutableStateOf(false) }
    var batteryOk by rememberSaveable { mutableStateOf(true) }
    var notificationsOk by rememberSaveable { mutableStateOf(true) }
    LifecycleResumeEffect(Unit) {
        val pm = context.getSystemService(PowerManager::class.java)
        batteryOk = pm?.isIgnoringBatteryOptimizations(context.packageName) == true
        notificationsOk = NotificationManagerCompat.from(context).areNotificationsEnabled()
        onPauseOrDispose {}
    }

    @Composable
    fun toggle(title: Int, summary: Int?, icon: Int, checked: Boolean, onChange: (Boolean) -> Unit) {
        SettingsRow(
            title = stringResource(title),
            summary = summary?.let { stringResource(it) },
            icon = icon,
            onClick = { onChange(!checked) },
            role = Role.Switch,
            trailing = { Switch(checked = checked, onCheckedChange = null) },
        )
    }

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text(stringResource(R.string.settings)) },
                navigationIcon = { IconButton(onClick = onBack) { Sym(R.drawable.ic_arrow_back, stringResource(R.string.back)) } },
                scrollBehavior = scroll,
            )
        },
    ) { padding ->
        LazyColumn(contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 32.dp)) {
            item("sync") {
                SectionHeader(stringResource(R.string.section_sync))
                SettingsGroup {
                    toggle(R.string.pause_syncing, R.string.pause_syncing_summary, R.drawable.ic_pause, settings.paused) { actions.setPaused(it) }
                    toggle(R.string.auto_apply, R.string.auto_apply_summary, R.drawable.ic_content_paste, settings.autoApply) { v -> actions.update { it.copy(autoApply = v) } }
                    toggle(R.string.sync_images, R.string.sync_images_summary, R.drawable.ic_image, settings.syncImages) { v -> actions.update { it.copy(syncImages = v) } }
                }
            }
            item("open") {
                SectionHeader(stringResource(R.string.section_on_open))
                SettingsGroup {
                    toggle(R.string.send_on_open, R.string.send_on_open_summary, R.drawable.ic_send, settings.sendOnOpen) { v -> actions.update { it.copy(sendOnOpen = v) } }
                    toggle(R.string.copy_newest_on_open, R.string.copy_newest_on_open_summary, R.drawable.ic_content_copy, settings.copyNewestOnOpen) { v -> actions.update { it.copy(copyNewestOnOpen = v) } }
                }
            }
            item("background") {
                SectionHeader(stringResource(R.string.section_background))
                SettingsGroup {
                    toggle(R.string.stay_connected, R.string.stay_connected_summary, R.drawable.ic_sync, settings.stayConnected) { actions.setStayConnected(it) }
                    SettingsRow(
                        title = stringResource(R.string.battery_title),
                        summary = stringResource(if (batteryOk) R.string.battery_unrestricted else R.string.battery_optimized),
                        icon = R.drawable.ic_battery_charging_full,
                        onClick = {
                            if (!batteryOk) {
                                Actions.requestUnrestrictedBattery(context)
                            } else {
                                runCatching { context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) }
                            }
                        },
                    )
                    SettingsRow(
                        title = stringResource(R.string.notifications_title),
                        summary = stringResource(if (notificationsOk) R.string.notifications_on else R.string.notifications_off),
                        icon = R.drawable.ic_notifications,
                        onClick = {
                            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            runCatching { context.startActivity(intent) }
                        },
                    )
                }
            }
            item("privacy") {
                SectionHeader(stringResource(R.string.section_privacy))
                SettingsGroup {
                    SettingsRow(
                        title = stringResource(R.string.skip_password_managers),
                        summary = stringResource(R.string.skip_password_managers_summary),
                        icon = R.drawable.ic_password,
                        trailing = { Sym(R.drawable.ic_check_circle_filled, stringResource(R.string.always_on), tint = MaterialTheme.colorScheme.primary) },
                    )
                    SettingsRow(
                        title = stringResource(R.string.no_server),
                        summary = stringResource(R.string.local_only_summary),
                        icon = R.drawable.ic_lock,
                    )
                }
            }
            item("history") {
                SectionHeader(stringResource(R.string.section_history))
                SettingsGroup {
                    SettingsRow(
                        title = stringResource(R.string.keep_history),
                        summary = stringResource(retentionLabel(settings.retentionDays)),
                        icon = R.drawable.ic_history,
                        onClick = { retentionOpen = true },
                    )
                    SettingsRow(
                        title = stringResource(R.string.clear_history),
                        summary = stringResource(R.string.clear_history_summary),
                        icon = R.drawable.ic_delete_sweep,
                        titleColor = MaterialTheme.colorScheme.error,
                        iconTint = MaterialTheme.colorScheme.error,
                        onClick = { clearOpen = true },
                    )
                }
            }
            item("about") {
                SectionHeader(stringResource(R.string.section_about))
                SettingsGroup {
                    SettingsRow(
                        title = stringResource(R.string.app_name),
                        summary = stringResource(R.string.version_line, BuildConfig.VERSION_NAME) + "\n" + stringResource(R.string.local_only),
                        icon = R.drawable.ic_info,
                    )
                    SettingsRow(
                        title = stringResource(R.string.licenses),
                        icon = R.drawable.ic_description,
                        onClick = actions.openLicenses,
                        trailing = { Sym(R.drawable.ic_chevron_right, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) },
                    )
                }
            }
        }
    }

    if (retentionOpen) {
        var choice by rememberSaveable { mutableIntStateOf(settings.retentionDays) }
        AlertDialog(
            onDismissRequest = { retentionOpen = false },
            title = { Text(stringResource(R.string.keep_history)) },
            text = {
                Column {
                    for (days in listOf(1, 7, 30, 0)) {
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .selectable(selected = choice == days, onClick = { choice = days }, role = Role.RadioButton)
                                .padding(vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            RadioButton(selected = choice == days, onClick = null)
                            Spacer(Modifier.padding(start = 12.dp))
                            Text(stringResource(retentionLabel(days)), style = MaterialTheme.typography.bodyLarge)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    actions.update { it.copy(retentionDays = choice) }
                    retentionOpen = false
                }) { Text(stringResource(R.string.ok)) }
            },
            dismissButton = { TextButton(onClick = { retentionOpen = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    if (clearOpen) {
        AlertDialog(
            onDismissRequest = { clearOpen = false },
            icon = { Sym(R.drawable.ic_delete_sweep, null) },
            title = { Text(stringResource(R.string.clear_history_title)) },
            text = { Text(stringResource(R.string.clear_history_body)) },
            confirmButton = {
                TextButton(onClick = { actions.clearHistory(); clearOpen = false }) {
                    Text(stringResource(R.string.clear), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { clearOpen = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    @Suppress("UNUSED_VARIABLE") val sdk = Build.VERSION.SDK_INT
    Spacer(Modifier.height(0.dp))
}

fun retentionLabel(days: Int): Int = when (days) {
    1 -> R.string.retention_1
    7 -> R.string.retention_7
    30 -> R.string.retention_30
    else -> R.string.retention_forever
}
