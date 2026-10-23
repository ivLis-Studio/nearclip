package studio.ivlis.nearclip.ui.devices

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.engine.EngineSnapshot
import studio.ivlis.nearclip.core.model.MemberRecord
import studio.ivlis.nearclip.runtime.DeviceInfo
import studio.ivlis.nearclip.ui.Format
import studio.ivlis.nearclip.ui.components.DeviceAvatar
import studio.ivlis.nearclip.ui.components.SectionHeader
import studio.ivlis.nearclip.ui.components.SettingsGroup
import studio.ivlis.nearclip.ui.components.SettingsRow
import studio.ivlis.nearclip.ui.components.Sym
import studio.ivlis.nearclip.ui.home.rememberNow
import studio.ivlis.nearclip.ui.theme.Brand

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(
    snapshot: EngineSnapshot,
    onBack: () -> Unit,
    onAddDevice: () -> Unit,
    onRename: (String) -> Unit,
    onRemove: (MemberRecord) -> Unit,
    onLeave: () -> Unit,
) {
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var renaming by rememberSaveable { mutableStateOf(false) }
    var removeId by rememberSaveable { mutableStateOf<String?>(null) }
    var leaving by rememberSaveable { mutableStateOf(false) }
    val now = rememberNow(15_000)
    val others = snapshot.otherMembers.sortedWith(compareBy({ it.id !in snapshot.online }, { it.name.lowercase() }))

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text(stringResource(R.string.my_devices)) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Sym(R.drawable.ic_arrow_back, stringResource(R.string.back)) }
                },
                scrollBehavior = scroll,
            )
        },
    ) { padding ->
        LazyColumn(contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 24.dp)) {
            item("me") { ThisDeviceCard(snapshot.me?.name ?: snapshot.deviceName, onRename = { renaming = true }) }
            if (others.isNotEmpty()) {
                item("others-header") { SectionHeader(stringResource(R.string.other_devices)) }
                item("others") {
                    SettingsGroup {
                        for (m in others) DeviceRow(m, m.id in snapshot.online, snapshot.lastSeen[m.id], now, onRemove = { removeId = m.id })
                    }
                }
            } else {
                item("none") {
                    Text(
                        stringResource(R.string.no_other_devices),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 24.dp, vertical = 20.dp),
                    )
                }
            }
            item("add") {
                Button(
                    onClick = onAddDevice,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 20.dp)
                        .heightIn(min = 56.dp),
                ) {
                    Sym(R.drawable.ic_add, null, Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.add_device), style = MaterialTheme.typography.titleSmall)
                }
            }
            // Leaving only means something while there is a group to leave.
            if (others.isNotEmpty()) {
                item("advanced") {
                    SectionHeader(stringResource(R.string.advanced))
                    SettingsGroup {
                        SettingsRow(
                            title = stringResource(R.string.leave_action),
                            summary = stringResource(R.string.leave_supporting),
                            icon = R.drawable.ic_logout,
                            titleColor = MaterialTheme.colorScheme.error,
                            iconTint = MaterialTheme.colorScheme.error,
                            onClick = { leaving = true },
                        )
                    }
                }
            }
        }
    }

    if (renaming) {
        RenameDialog(snapshot.me?.name ?: snapshot.deviceName, onDismiss = { renaming = false }, onSave = { onRename(it); renaming = false })
    }
    val target = removeId?.let { id -> snapshot.members.firstOrNull { it.id == id } }
    if (target != null) {
        AlertDialog(
            onDismissRequest = { removeId = null },
            icon = { Sym(R.drawable.ic_link_off, null) },
            title = { Text(stringResource(R.string.remove_title, target.name)) },
            text = { Text(stringResource(R.string.remove_body)) },
            confirmButton = {
                TextButton(onClick = { onRemove(target); removeId = null }) {
                    Text(stringResource(R.string.remove), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { removeId = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    if (leaving) {
        AlertDialog(
            onDismissRequest = { leaving = false },
            icon = { Sym(R.drawable.ic_logout, null) },
            title = { Text(stringResource(R.string.leave_title)) },
            text = { Text(stringResource(R.string.leave_body)) },
            confirmButton = {
                TextButton(onClick = { onLeave(); leaving = false }) {
                    Text(stringResource(R.string.leave_confirm), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { leaving = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun ThisDeviceCard(name: String, onRename: () -> Unit) {
    val context = LocalContext.current
    Surface(
        color = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        shape = RoundedCornerShape(28.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Row(Modifier.padding(start = 20.dp, top = 20.dp, bottom = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            DeviceAvatar(
                platform = "android",
                size = 56.dp,
                container = MaterialTheme.colorScheme.primary,
                content = MaterialTheme.colorScheme.onPrimary,
            )
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.this_device), style = MaterialTheme.typography.labelLarge)
                Text(name, style = MaterialTheme.typography.headlineSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    DeviceInfo.model + " · " + DeviceInfo.osLabel,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.8f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            IconButton(onClick = onRename) {
                Sym(R.drawable.ic_edit, stringResource(R.string.rename_device))
            }
        }
    }
    @Suppress("UNUSED_VARIABLE") val unused = context
}

@Composable
private fun DeviceRow(m: MemberRecord, online: Boolean, lastSeen: Long?, now: Long, onRemove: () -> Unit) {
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    val status = if (online) stringResource(R.string.connected) else Format.lastSeen(context, lastSeen, now)
    val model = m.model?.takeIf { it.isNotBlank() } ?: Format.platformName(context, m.platform)
    SettingsRow(
        title = m.name,
        summary = null,
        trailing = {
            Box {
                IconButton(onClick = { menu = true }) { Sym(R.drawable.ic_more_vert, stringResource(R.string.more_actions)) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.remove_device), color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Sym(R.drawable.ic_link_off, null, tint = MaterialTheme.colorScheme.error) },
                        onClick = { menu = false; onRemove() },
                    )
                }
            }
        },
        leading = {
            DeviceAvatar(m.platform, online = online, container = MaterialTheme.colorScheme.secondaryContainer)
        },
        subtitle = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "${model} · ",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Text(
                    status,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (online) Brand.OnlineText else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        },
    )
}

@Composable
private fun SettingsRow(
    title: String,
    summary: String?,
    leading: @Composable () -> Unit,
    subtitle: @Composable () -> Unit,
    trailing: @Composable () -> Unit,
) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(4.dp), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(start = 16.dp, top = 14.dp, bottom = 14.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            leading()
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(2.dp))
                if (summary != null) Text(summary) else subtitle()
            }
            trailing()
        }
    }
}

@Composable
fun RenameDialog(current: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    // Opens focused with the current name selected, so typing replaces it.
    var value by remember { mutableStateOf(TextFieldValue(current, TextRange(0, current.length))) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    val trimmed = value.text.trim()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.rename_device)) },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = { if (it.text.length <= 64) value = it },
                singleLine = true,
                label = { Text(stringResource(R.string.device_name)) },
                supportingText = { Text("${value.text.length} / 64") },
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { if (trimmed.isNotEmpty()) onSave(trimmed) }),
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(focus),
            )
        },
        confirmButton = {
            TextButton(onClick = { onSave(trimmed) }, enabled = trimmed.isNotEmpty()) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
