package studio.ivlis.nearclip.ui.pairing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.engine.DiscoveredService
import studio.ivlis.nearclip.core.engine.EngineConfig
import studio.ivlis.nearclip.core.engine.EngineSnapshot
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.ui.Format
import studio.ivlis.nearclip.ui.components.DeviceAvatar
import studio.ivlis.nearclip.ui.components.Sym
import studio.ivlis.nearclip.ui.devices.RenameDialog

/**
 * The phone Add-device UI (DESIGN §4.2): Scan QR code, Show my QR code, Nearby, Connect by address. It ends
 * with the name the other device will show in its Nearby list and pairing prompt, renameable before pairing.
 */
@Composable
fun AddDeviceContent(
    snapshot: EngineSnapshot,
    onScan: () -> Unit,
    onShowQr: () -> Unit,
    onPairNearby: (DiscoveredService) -> Unit,
    onConnectByAddress: () -> Unit,
    onRename: (String) -> Unit,
    modifier: Modifier = Modifier,
    showTitle: Boolean = true,
) {
    val myName = snapshot.me?.name ?: snapshot.deviceName
    var renaming by rememberSaveable { mutableStateOf(false) }
    Column(modifier.padding(horizontal = 24.dp)) {
        if (showTitle) {
            Text(stringResource(R.string.add_device), style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(R.string.add_device_subtitle),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(20.dp))
        }
        Button(
            onClick = onScan,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp),
        ) {
            Sym(R.drawable.ic_qr_code_scanner, null, Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Text(stringResource(R.string.scan_qr), style = MaterialTheme.typography.titleSmall)
        }
        Spacer(Modifier.height(10.dp))
        OutlinedButton(
            onClick = onShowQr,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp),
        ) {
            Sym(R.drawable.ic_qr_code_2, null, Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Text(stringResource(R.string.show_my_qr), style = MaterialTheme.typography.titleSmall)
        }
        Spacer(Modifier.height(28.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.nearby), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(10.dp))
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
        }
        Spacer(Modifier.height(10.dp))
        if (snapshot.nearby.isEmpty()) {
            Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                    Sym(R.drawable.ic_wifi_tethering, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(16.dp))
                    Text(
                        stringResource(R.string.nearby_empty),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.fillMaxWidth()) {
                for ((i, d) in snapshot.nearby.withIndex()) {
                    NearbyRow(d, first = i == 0, last = i == snapshot.nearby.lastIndex, onPair = { onPairNearby(d) })
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        TextButton(onClick = onConnectByAddress, modifier = Modifier.align(Alignment.CenterHorizontally)) {
            Text(stringResource(R.string.connect_by_address))
        }
        Spacer(Modifier.height(12.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Sym(R.drawable.ic_smartphone, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.shown_as_label),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(myName, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            TextButton(onClick = { renaming = true }) { Text(stringResource(R.string.rename)) }
        }
    }
    if (renaming) {
        RenameDialog(myName, onDismiss = { renaming = false }, onSave = { onRename(it); renaming = false })
    }
}

@Composable
private fun NearbyRow(d: DiscoveredService, first: Boolean, last: Boolean, onPair: () -> Unit) {
    val context = LocalContext.current
    val big = 20.dp
    val small = 4.dp
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(if (first) big else small, if (first) big else small, if (last) big else small, if (last) big else small),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            DeviceAvatar(d.platform)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(d.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    Format.platformName(context, d.platform) + if (d.pairingMode) " · " + stringResource(R.string.ready_to_pair) else "",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
            FilledTonalButton(onClick = onPair) { Text(stringResource(R.string.pair)) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddDeviceSheet(
    snapshot: EngineSnapshot,
    onDismiss: () -> Unit,
    onPairingMode: (Boolean) -> Unit,
    onScan: () -> Unit,
    onShowQr: () -> Unit,
    onPairNearby: (DiscoveredService) -> Unit,
    onConnectByAddress: () -> Unit,
    onRename: (String) -> Unit,
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    DisposableEffect(Unit) {
        onPairingMode(true)
        onDispose { onPairingMode(false) }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = state) {
        AddDeviceContent(
            snapshot = snapshot,
            onScan = onScan,
            onShowQr = onShowQr,
            onPairNearby = onPairNearby,
            onConnectByAddress = onConnectByAddress,
            onRename = onRename,
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
        )
    }
}

@Composable
fun ConnectByAddressDialog(onDismiss: () -> Unit, onConnect: (Endpoint) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    var error by rememberSaveable { mutableStateOf(false) }
    fun submit() {
        val ep = Endpoint.parse(text, EngineConfig.DEFAULT_PORT)
        if (ep == null) error = true else onConnect(ep)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Sym(R.drawable.ic_lan, null) },
        title = { Text(stringResource(R.string.address_title)) },
        text = {
            Column {
                Text(stringResource(R.string.address_body), style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(16.dp))
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it.trim(); error = false },
                    singleLine = true,
                    isError = error,
                    placeholder = { Text("192.168.0.12:45821") },
                    supportingText = if (error) {
                        { Text(stringResource(R.string.address_invalid)) }
                    } else {
                        null
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(onGo = { submit() }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = { TextButton(onClick = { submit() }, enabled = text.isNotBlank()) { Text(stringResource(R.string.connect)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
