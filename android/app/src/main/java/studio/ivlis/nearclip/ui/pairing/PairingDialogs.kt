package studio.ivlis.nearclip.ui.pairing

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.engine.PairPromptInfo
import studio.ivlis.nearclip.core.engine.Sas
import studio.ivlis.nearclip.runtime.PairingUi
import studio.ivlis.nearclip.ui.components.DeviceAvatar
import studio.ivlis.nearclip.ui.components.Sym
import studio.ivlis.nearclip.ui.theme.LocalReduceMotion

/** The six-digit pairing code in large monospaced digits, grouped "123 456". */
@Composable
fun PairingCode(sas: String) {
    val spoken = sas.toList().joinToString(" ")
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = spoken },
    ) {
        Text(
            Sas.display(sas),
            style = MaterialTheme.typography.displaySmall.copy(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Medium,
                letterSpacing = 2.sp,
                fontFeatureSettings = "tnum",
            ),
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(vertical = 18.dp),
        )
    }
}

/** Inviter: "Add ‘Pixel 9’?" with the code, Decline / Add (DESIGN §4.2). */
@Composable
fun InviterPromptDialog(prompt: PairPromptInfo, onDecline: () -> Unit, onAdd: () -> Unit) {
    AlertDialog(
        onDismissRequest = {},
        icon = { DeviceAvatar(prompt.platform, size = 48.dp) },
        title = { Text(stringResource(R.string.pair_inviter_title, prompt.name), textAlign = TextAlign.Center) },
        text = {
            Column {
                Text(stringResource(R.string.pair_inviter_body, prompt.name), style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(16.dp))
                PairingCode(prompt.sas)
            }
        },
        confirmButton = { TextButton(onClick = onAdd) { Text(stringResource(R.string.add)) } },
        dismissButton = { TextButton(onClick = onDecline) { Text(stringResource(R.string.decline)) } },
    )
}

@Composable
fun PairingFlowDialogs(state: PairingUi, onJoinLink: () -> Unit, onCancel: () -> Unit, onDismiss: () -> Unit) {
    val fallback = stringResource(R.string.the_other_device)
    when (state) {
        PairingUi.Idle -> Unit
        is PairingUi.ConfirmLink -> {
            val name = state.uri.name.ifBlank { fallback }
            AlertDialog(
                onDismissRequest = onDismiss,
                icon = { DeviceAvatar(state.uri.platform, size = 48.dp) },
                title = { Text(stringResource(R.string.pair_link_title, name), textAlign = TextAlign.Center) },
                text = { Text(stringResource(R.string.pair_link_body, name)) },
                confirmButton = { TextButton(onClick = onJoinLink) { Text(stringResource(R.string.pair)) } },
                dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
            )
        }
        is PairingUi.Joining -> {
            val name = state.peerName.ifBlank { fallback }
            AlertDialog(
                onDismissRequest = {},
                title = { Text(stringResource(R.string.pair_connecting, name), textAlign = TextAlign.Center) },
                text = {
                    Column {
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                        Spacer(Modifier.height(16.dp))
                        Text(stringResource(R.string.pair_connecting_body), style = MaterialTheme.typography.bodyMedium)
                    }
                },
                confirmButton = {},
                dismissButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) } },
            )
        }
        is PairingUi.CodeConfirm -> {
            val name = state.peerName.ifBlank { fallback }
            AlertDialog(
                onDismissRequest = {},
                title = { Text(stringResource(R.string.pair_joiner_title, name), textAlign = TextAlign.Center) },
                text = {
                    Column {
                        Text(stringResource(R.string.pair_joiner_body, name), style = MaterialTheme.typography.bodyMedium)
                        Spacer(Modifier.height(16.dp))
                        PairingCode(state.sas)
                        Spacer(Modifier.height(16.dp))
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                    }
                },
                confirmButton = {},
                dismissButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) } },
            )
        }
        is PairingUi.Success -> {
            val haptic = LocalHapticFeedback.current
            LaunchedEffect(state) { haptic.performHapticFeedback(HapticFeedbackType.Confirm) }
            AlertDialog(
                onDismissRequest = onDismiss,
                icon = { SuccessCheck() },
                title = { Text(stringResource(R.string.pair_success_title), textAlign = TextAlign.Center) },
                text = {
                    Text(
                        stringResource(R.string.pair_success, state.peerName.ifBlank { fallback }),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                },
                confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.done)) } },
            )
        }
        is PairingUi.Failed -> {
            val name = state.peerName.ifBlank { fallback }
            val message = when (state.reason) {
                "no_ticket" -> stringResource(R.string.pair_error_no_ticket, name)
                "declined" -> stringResource(R.string.pair_error_declined, name)
                "unreachable", "io" -> stringResource(R.string.pair_error_unreachable, name)
                "busy" -> stringResource(R.string.pair_error_busy, name)
                "commit" -> stringResource(R.string.pair_error_commit)
                "timeout" -> stringResource(R.string.pair_error_timeout, name)
                "wrong_device" -> stringResource(R.string.pair_error_wrong_device)
                "version" -> stringResource(R.string.pair_error_version, name)
                else -> stringResource(R.string.pair_error_generic, name)
            }
            AlertDialog(
                onDismissRequest = onDismiss,
                icon = { Sym(R.drawable.ic_error, null, tint = MaterialTheme.colorScheme.error) },
                title = { Text(stringResource(R.string.pair_failed_title), textAlign = TextAlign.Center) },
                text = { Text(message) },
                confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.ok)) } },
            )
        }
    }
}

/** Check-mark that draws itself (DESIGN §4.2 success); static when animations are off. */
@Composable
fun SuccessCheck(size: androidx.compose.ui.unit.Dp = 56.dp) {
    val reduceMotion = LocalReduceMotion.current
    val circle = remember { Animatable(if (reduceMotion) 1f else 0f) }
    val tick = remember { Animatable(if (reduceMotion) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (!reduceMotion) {
            circle.animateTo(1f, tween(220, easing = FastOutSlowInEasing))
            tick.animateTo(1f, tween(240, easing = FastOutSlowInEasing))
        }
    }
    val container = MaterialTheme.colorScheme.primaryContainer
    val color = MaterialTheme.colorScheme.primary
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size)) {
            drawCircle(container, radius = this.size.minDimension / 2 * circle.value)
            val p = Path().apply {
                moveTo(this@Canvas.size.width * 0.28f, this@Canvas.size.height * 0.52f)
                lineTo(this@Canvas.size.width * 0.44f, this@Canvas.size.height * 0.67f)
                lineTo(this@Canvas.size.width * 0.73f, this@Canvas.size.height * 0.36f)
            }
            val measure = PathMeasure()
            measure.setPath(p, false)
            val seg = Path()
            measure.getSegment(0f, measure.length * tick.value, seg, true)
            drawPath(seg, color, style = Stroke(width = this.size.minDimension * 0.08f, cap = StrokeCap.Round, join = StrokeJoin.Round))
            @Suppress("UNUSED_VARIABLE") val o = Offset.Zero
        }
    }
}
