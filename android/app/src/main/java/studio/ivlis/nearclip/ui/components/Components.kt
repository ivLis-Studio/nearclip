package studio.ivlis.nearclip.ui.components

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.model.Platform
import studio.ivlis.nearclip.ui.theme.Brand

@DrawableRes
fun platformIcon(platform: String): Int = when (platform) {
    Platform.MAC -> R.drawable.ic_laptop_mac
    Platform.WINDOWS -> R.drawable.ic_desktop_windows
    Platform.ANDROID -> R.drawable.ic_smartphone
    Platform.IOS -> R.drawable.ic_phone_iphone
    Platform.CLI -> R.drawable.ic_terminal
    else -> R.drawable.ic_devices
}

@Composable
fun Sym(@DrawableRes id: Int, contentDescription: String?, modifier: Modifier = Modifier, tint: Color = androidx.compose.material3.LocalContentColor.current) {
    Icon(painterResource(id), contentDescription, modifier, tint)
}

/** The app icon as a tile: Iris plate with the white glyph (design/). */
@Composable
fun LogoTile(size: Dp, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(Brand.Iris),
        contentAlignment = Alignment.Center,
    ) {
        Image(painterResource(R.drawable.ic_nearclip_glyph), null, Modifier.size(size))
    }
}

@Composable
fun StatusDot(online: Boolean, modifier: Modifier = Modifier, size: Dp = 10.dp, ring: Color = MaterialTheme.colorScheme.surface) {
    Box(
        modifier
            .size(size)
            .border(2.dp, ring, CircleShape)
            .padding(2.dp)
            .clip(CircleShape)
            .background(if (online) Brand.Online else MaterialTheme.colorScheme.outline),
    )
}

/** Platform glyph in a tonal circle, optionally with a status dot. */
@Composable
fun DeviceAvatar(
    platform: String,
    modifier: Modifier = Modifier,
    size: Dp = 40.dp,
    online: Boolean? = null,
    container: Color = MaterialTheme.colorScheme.secondaryContainer,
    content: Color = MaterialTheme.colorScheme.onSecondaryContainer,
) {
    Box(modifier.size(size)) {
        Box(
            Modifier
                .size(size)
                .clip(CircleShape)
                .background(container),
            contentAlignment = Alignment.Center,
        ) {
            Sym(platformIcon(platform), null, Modifier.size(size * 0.5f), tint = content)
        }
        if (online != null) {
            StatusDot(online, Modifier.align(Alignment.BottomEnd).offset(x = 1.dp, y = 1.dp), size = size * 0.32f)
        }
    }
}

/** Overlapping avatars of connected devices (status chip). */
@Composable
fun AvatarStack(platforms: List<String>, modifier: Modifier = Modifier, size: Dp = 22.dp) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(-(size * 0.32f))) {
        for (p in platforms.take(3)) {
            Box(
                Modifier
                    .size(size)
                    .border(1.5.dp, MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape)
                    .padding(1.5.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center,
            ) {
                Sym(platformIcon(p), null, Modifier.size(size * 0.55f), tint = MaterialTheme.colorScheme.onPrimaryContainer)
            }
        }
    }
}

@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.primary) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = color,
        modifier = modifier
            .padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 8.dp)
            .semantics { heading() },
    )
}

@Composable
fun EmptyState(
    @DrawableRes icon: Int,
    title: String,
    body: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    Column(
        modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .size(88.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceContainerHigh),
            contentAlignment = Alignment.Center,
        ) {
            Sym(icon, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.primary)
        }
        Spacer(Modifier.height(20.dp))
        Text(title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(
            body,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        if (action != null) {
            Spacer(Modifier.height(20.dp))
            action()
        }
    }
}

/** Android 16-style settings group: rounded container, rows separated by 2 dp gaps. */
@Composable
fun SettingsGroup(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier
            .padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(24.dp)),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        content = content,
    )
}

@Composable
fun SettingsRow(
    title: String,
    modifier: Modifier = Modifier,
    summary: String? = null,
    @DrawableRes icon: Int? = null,
    titleColor: Color = MaterialTheme.colorScheme.onSurface,
    iconTint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    onClick: (() -> Unit)? = null,
    role: Role? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(4.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier
                .then(if (onClick != null) Modifier.clickable(role = role, onClick = onClick) else Modifier)
                .heightIn(min = 64.dp)
                .padding(PaddingValues(horizontal = 20.dp, vertical = 14.dp)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (icon != null) {
                Sym(icon, null, Modifier.size(24.dp), tint = iconTint)
                Spacer(Modifier.width(18.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium, color = titleColor)
                if (summary != null) {
                    Spacer(Modifier.height(2.dp))
                    Text(summary, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (trailing != null) {
                Spacer(Modifier.width(16.dp))
                trailing()
            }
        }
    }
}
