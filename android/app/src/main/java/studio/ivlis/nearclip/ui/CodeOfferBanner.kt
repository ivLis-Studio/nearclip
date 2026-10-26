package studio.ivlis.nearclip.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.LaunchedEffect
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.runtime.UiMessage
import studio.ivlis.nearclip.ui.components.Sym

/**
 * "A verification code arrived from Junseo's iPhone. Copy it?" with the code in large digits, Copy and Not now
 * (PROTOCOL §6.7). Shown over whatever screen of Nearclip is open; codes are never copied on their own.
 */
@Composable
fun CodeOfferBanner(offer: UiMessage.CodeArrived?, onCopy: (UiMessage.CodeArrived) -> Unit, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    // Keeps the last offer on screen while the banner slides away.
    var shown by remember { mutableStateOf(offer) }
    if (offer != null) shown = offer
    val haptics = LocalHapticFeedback.current
    LaunchedEffect(offer?.id) { if (offer != null) haptics.performHapticFeedback(HapticFeedbackType.LongPress) }
    AnimatedVisibility(
        visible = offer != null,
        enter = slideInVertically { it / 2 } + fadeIn(),
        exit = slideOutVertically { it / 2 } + fadeOut(),
        modifier = modifier,
    ) {
        val o = shown ?: return@AnimatedVisibility
        val title = stringResource(R.string.code_arrived, o.name)
        Surface(
            shape = RoundedCornerShape(28.dp),
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            tonalElevation = 6.dp,
            shadowElevation = 10.dp,
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 520.dp)
                .semantics { liveRegion = LiveRegionMode.Polite },
        ) {
            Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 16.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Box(
                        Modifier
                            .size(40.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primary),
                        contentAlignment = Alignment.Center,
                    ) {
                        Sym(R.drawable.ic_pin, null, Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onPrimary)
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(title, style = MaterialTheme.typography.titleSmall)
                        Spacer(Modifier.height(2.dp))
                        Text(
                            o.code,
                            style = MaterialTheme.typography.headlineLarge.copy(fontWeight = FontWeight.Bold, letterSpacing = 4.sp),
                            modifier = Modifier.semantics { contentDescription = o.code.toCharArray().joinToString(" ") },
                        )
                    }
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    Button(onClick = { onCopy(o) }, modifier = Modifier.weight(1f)) {
                        Sym(R.drawable.ic_content_copy, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.copy))
                    }
                    FilledTonalButton(onClick = onDismiss) { Text(stringResource(R.string.not_now)) }
                }
            }
        }
    }
}

