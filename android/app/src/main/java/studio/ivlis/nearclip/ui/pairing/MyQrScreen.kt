package studio.ivlis.nearclip.ui.pairing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.engine.EngineSnapshot
import studio.ivlis.nearclip.core.engine.TicketInfo
import studio.ivlis.nearclip.ui.Format
import studio.ivlis.nearclip.ui.components.QrCode
import studio.ivlis.nearclip.ui.components.Sym
import studio.ivlis.nearclip.ui.theme.Brand

/** "Show my QR code": a fresh ticket that refreshes itself before it expires (DESIGN §4.2). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MyQrScreen(
    snapshot: EngineSnapshot,
    createTicket: suspend () -> TicketInfo,
    onPairingMode: (Boolean) -> Unit,
    onBack: () -> Unit,
) {
    var ticket by remember { mutableStateOf<TicketInfo?>(null) }
    DisposableEffect(Unit) {
        onPairingMode(true)
        onDispose { onPairingMode(false) }
    }
    LaunchedEffect(Unit) {
        while (true) {
            val t = createTicket()
            ticket = t
            delay((t.expiresAt - System.currentTimeMillis()).coerceAtLeast(5_000))
        }
    }
    val now by produceState(System.currentTimeMillis()) {
        while (true) {
            delay(1_000)
            value = System.currentTimeMillis()
        }
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.show_my_qr)) },
                navigationIcon = { IconButton(onClick = onBack) { Sym(R.drawable.ic_arrow_back, stringResource(R.string.back)) } },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                shape = RoundedCornerShape(32.dp),
                modifier = Modifier
                    .widthIn(max = 420.dp)
                    .fillMaxWidth(),
            ) {
                Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.size(264.dp), contentAlignment = Alignment.Center) {
                        val t = ticket
                        if (t != null) {
                            QrCode(t.uri, stringResource(R.string.qr_a11y, snapshot.deviceName), Modifier.size(264.dp))
                        } else {
                            CircularProgressIndicator()
                        }
                    }
                    Spacer(Modifier.height(20.dp))
                    Text(
                        stringResource(R.string.my_qr_caption),
                        style = MaterialTheme.typography.titleMedium,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(14.dp))
                    val t = ticket
                    if (t != null) {
                        val left = (t.expiresAt - now) / 1000
                        Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = CircleShape) {
                            Row(Modifier.padding(horizontal = 14.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                                Sym(R.drawable.ic_schedule, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer)
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    stringResource(R.string.expires_in, Format.countdown(left)),
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                                )
                            }
                        }
                        Spacer(Modifier.height(12.dp))
                        val host = t.hosts.firstOrNull()
                        if (host != null) {
                            Text(
                                stringResource(R.string.address_line, host, t.port),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        } else {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Sym(R.drawable.ic_wifi_off, null, Modifier.size(16.dp), tint = Brand.Warning)
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    stringResource(R.string.no_wifi),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
            Row(
                Modifier
                    .widthIn(max = 420.dp)
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Sym(R.drawable.ic_computer, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    stringResource(R.string.my_qr_code_hint, snapshot.deviceName),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
