package studio.ivlis.nearclip.ui.home

import android.graphics.Bitmap
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.runtime.ImageTools
import studio.ivlis.nearclip.ui.ClipLook
import studio.ivlis.nearclip.ui.Format
import studio.ivlis.nearclip.ui.components.Sym
import studio.ivlis.nearclip.ui.components.platformIcon
import studio.ivlis.nearclip.ui.theme.Brand
import studio.ivlis.nearclip.ui.theme.LocalReduceMotion
import java.io.File

@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
fun ClipRow(
    clip: Clip,
    sourceName: String,
    sourcePlatform: String,
    now: Long,
    imageFile: File?,
    onCopy: () -> Boolean,
    onTogglePin: () -> Unit,
    onDelete: () -> Unit,
    onShare: () -> Unit,
    onOpenLink: (String) -> Unit,
    onSaveImage: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val look = remember(clip.id, clip.text) { ClipLook.of(clip) }
    var copied by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    val haptic = LocalHapticFeedback.current
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_600)
            copied = false
        }
    }
    val dismissState = rememberSwipeToDismissBoxState()
    val relative = Format.relative(context, clip.ts, now)
    val copyLabel = stringResource(R.string.action_copy)
    val pinLabel = stringResource(if (clip.pinned) R.string.action_unpin else R.string.action_pin)
    val deleteLabel = stringResource(R.string.action_delete)
    val shareLabel = stringResource(R.string.action_share)
    val openLabel = stringResource(R.string.action_open_link)
    val saveLabel = stringResource(R.string.action_save_image)
    val moreLabel = stringResource(R.string.more_actions)
    val description = when (look) {
        is ClipLook.Image -> stringResource(R.string.a11y_image_clip, sourceName, relative)
        is ClipLook.Link -> stringResource(R.string.a11y_clip, look.host + look.rest, sourceName, relative)
        is ClipLook.ColorCode -> stringResource(R.string.a11y_clip, look.code, sourceName, relative)
        is ClipLook.Text -> stringResource(R.string.a11y_clip, look.preview.take(120), sourceName, relative)
    } + (if (clip.pinned) ", " + stringResource(R.string.a11y_pinned) else "")

    fun copy() {
        if (onCopy()) {
            haptic.performHapticFeedback(HapticFeedbackType.Confirm)
            copied = true
        }
    }

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        onDismiss = { value -> if (value == SwipeToDismissBoxValue.EndToStart) onDelete() },
        backgroundContent = {
            val active = dismissState.targetValue == SwipeToDismissBoxValue.EndToStart
            val bg by animateColorAsState(
                if (active) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceContainerHighest,
                label = "swipe",
            )
            Box(
                Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(20.dp))
                    .background(bg)
                    .padding(horizontal = 24.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Sym(R.drawable.ic_delete, null, tint = MaterialTheme.colorScheme.onErrorContainer)
            }
        },
        modifier = modifier,
    ) {
        Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
            Box {
                Row(
                    Modifier
                        .combinedClickable(
                            onClickLabel = copyLabel,
                            onLongClickLabel = moreLabel,
                            onClick = { copy() },
                            onLongClick = {
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                menuOpen = true
                            },
                        )
                        .semantics(mergeDescendants = true) {
                            contentDescription = description
                            onClick(copyLabel) { copy(); true }
                            customActions = buildList {
                                add(CustomAccessibilityAction(pinLabel) { onTogglePin(); true })
                                if (look is ClipLook.Link) add(CustomAccessibilityAction(openLabel) { onOpenLink(look.url); true })
                                add(CustomAccessibilityAction(shareLabel) { onShare(); true })
                                if (look is ClipLook.Image) add(CustomAccessibilityAction(saveLabel) { onSaveImage(); true })
                                add(CustomAccessibilityAction(deleteLabel) { onDelete(); true })
                            }
                        }
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Leading(look, copied, imageFile)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Title(look, clip, imageFile)
                        Spacer(Modifier.height(4.dp))
                        Caption(clip, copied, sourceName, sourcePlatform, relative)
                    }
                    if (clip.pinned) {
                        Spacer(Modifier.width(8.dp))
                        Sym(R.drawable.ic_push_pin_filled, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary)
                    }
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(copyLabel) },
                        leadingIcon = { Sym(R.drawable.ic_content_copy, null) },
                        onClick = { menuOpen = false; copy() },
                    )
                    DropdownMenuItem(
                        text = { Text(pinLabel) },
                        leadingIcon = { Sym(if (clip.pinned) R.drawable.ic_push_pin_filled else R.drawable.ic_push_pin, null) },
                        onClick = { menuOpen = false; onTogglePin() },
                    )
                    if (look is ClipLook.Link) {
                        DropdownMenuItem(
                            text = { Text(openLabel) },
                            leadingIcon = { Sym(R.drawable.ic_open_in_new, null) },
                            onClick = { menuOpen = false; onOpenLink(look.url) },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(shareLabel) },
                        leadingIcon = { Sym(R.drawable.ic_share, null) },
                        onClick = { menuOpen = false; onShare() },
                    )
                    if (look is ClipLook.Image) {
                        DropdownMenuItem(
                            text = { Text(saveLabel) },
                            leadingIcon = { Sym(R.drawable.ic_download, null) },
                            onClick = { menuOpen = false; onSaveImage() },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(deleteLabel, color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Sym(R.drawable.ic_delete, null, tint = MaterialTheme.colorScheme.error) },
                        onClick = { menuOpen = false; onDelete() },
                    )
                }
            }
        }
    }
}

@Composable
private fun Leading(look: ClipLook, copied: Boolean, imageFile: File?) {
    val shape = RoundedCornerShape(12.dp)
    val reduceMotion = LocalReduceMotion.current
    AnimatedContent(
        targetState = copied,
        transitionSpec = {
            if (reduceMotion) fadeIn(tween(0)) togetherWith fadeOut(tween(0))
            else (fadeIn(tween(180)) + scaleIn(tween(220), initialScale = 0.7f)) togetherWith fadeOut(tween(120))
        },
        label = "copied",
    ) { isCopied ->
        if (isCopied) {
            Box(
                Modifier
                    .size(48.dp)
                    .clip(shape)
                    .background(MaterialTheme.colorScheme.primary),
                contentAlignment = Alignment.Center,
            ) {
                Sym(R.drawable.ic_check, null, tint = MaterialTheme.colorScheme.onPrimary)
            }
        } else {
            when (look) {
                is ClipLook.Image -> Thumbnail(imageFile, 48.dp, shape)
                is ClipLook.ColorCode -> Box(
                    Modifier
                        .size(48.dp)
                        .clip(shape)
                        .background(MaterialTheme.colorScheme.surfaceContainerHighest),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        Modifier
                            .size(26.dp)
                            .clip(CircleShape)
                            .background(look.color)
                            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape),
                    )
                }
                is ClipLook.Link -> GlyphTile(R.drawable.ic_link)
                is ClipLook.Text -> GlyphTile(R.drawable.ic_notes)
            }
        }
    }
}

@Composable
private fun GlyphTile(icon: Int) {
    Box(
        Modifier
            .size(48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.secondaryContainer),
        contentAlignment = Alignment.Center,
    ) {
        Sym(icon, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer)
    }
}

@Composable
fun Thumbnail(file: File?, size: Dp, shape: Shape, modifier: Modifier = Modifier) {
    val px = with(LocalDensity.current) { size.roundToPx() } * 2
    val bitmap by produceState<Bitmap?>(null, file, px) {
        value = withContext(Dispatchers.IO) { file?.let { ImageTools.thumbnail(it, px) } }
    }
    Box(
        modifier
            .size(size)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainerHighest),
        contentAlignment = Alignment.Center,
    ) {
        val b = bitmap
        if (b != null) {
            Image(b.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        } else {
            Sym(R.drawable.ic_image, null, Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun Title(look: ClipLook, clip: Clip, imageFile: File?) {
    val style = MaterialTheme.typography.bodyLarge
    when (look) {
        is ClipLook.Text -> Text(look.preview, style = style, maxLines = 2, overflow = TextOverflow.Ellipsis)
        is ClipLook.Link -> Text(
            buildAnnotatedString {
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(look.host) }
                withStyle(SpanStyle(color = MaterialTheme.colorScheme.onSurfaceVariant)) { append(look.rest) }
            },
            style = style,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        is ClipLook.ColorCode -> Text(look.code, style = style.copy(fontFamily = FontFamily.Monospace), maxLines = 1)
        is ClipLook.Image -> {
            // Senders may omit w/h; read them from the file instead.
            val known = clip.w?.let { w -> clip.h?.let { h -> w to h } }
            val dims by produceState(known, imageFile) {
                if (value == null && imageFile != null) value = withContext(Dispatchers.IO) { ImageTools.bounds(imageFile) }
            }
            val d = dims
            Text(
                if (d != null) stringResource(R.string.image_title_size, d.first, d.second) else stringResource(R.string.image_title),
                style = style,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun Caption(clip: Clip, copied: Boolean, sourceName: String, sourcePlatform: String, relative: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        val muted = MaterialTheme.colorScheme.onSurfaceVariant
        when {
            copied -> {
                Text(
                    stringResource(R.string.copied),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            clip.localOnly -> {
                Sym(R.drawable.ic_error, null, Modifier.size(14.dp), tint = Brand.Warning)
                Spacer(Modifier.width(6.dp))
                Text(
                    stringResource(R.string.too_large_to_sync),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
            else -> {
                Sym(platformIcon(sourcePlatform), null, Modifier.size(14.dp), tint = muted)
                Spacer(Modifier.width(6.dp))
                Text(
                    "${sourceName} · ${relative}",
                    style = MaterialTheme.typography.labelLarge,
                    color = muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
