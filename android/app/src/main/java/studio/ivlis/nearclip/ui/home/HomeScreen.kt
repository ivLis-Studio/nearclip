package studio.ivlis.nearclip.ui.home

import androidx.annotation.StringRes
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.engine.EngineSnapshot
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.runtime.AppSettings
import studio.ivlis.nearclip.ui.ClipLook
import studio.ivlis.nearclip.ui.Format
import studio.ivlis.nearclip.ui.components.AvatarStack
import studio.ivlis.nearclip.ui.components.EmptyState
import studio.ivlis.nearclip.ui.components.LogoTile
import studio.ivlis.nearclip.ui.components.SectionHeader
import studio.ivlis.nearclip.ui.components.StatusDot
import studio.ivlis.nearclip.ui.components.Sym
import java.io.File

enum class HistoryFilter(@StringRes val label: Int) {
    All(R.string.filter_all),
    Text(R.string.filter_text),
    Links(R.string.filter_links),
    Images(R.string.filter_images),
    Pinned(R.string.filter_pinned),
}

private class HistorySection(val key: String, val title: String, val clips: List<Clip>)

@Composable
fun rememberNow(periodMs: Long = 30_000): Long {
    val now by produceState(System.currentTimeMillis()) {
        while (true) {
            delay(periodMs)
            value = System.currentTimeMillis()
        }
    }
    return now
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    snapshot: EngineSnapshot,
    settings: AppSettings,
    pendingDeletes: Set<String>,
    snackbarHost: SnackbarHostState,
    nameOf: (Clip) -> String,
    platformOf: (Clip) -> String,
    blobFile: (Clip) -> File,
    onOpenDevices: () -> Unit,
    onOpenSettings: () -> Unit,
    onAddDevice: () -> Unit,
    onSendClipboard: () -> Unit,
    onResume: () -> Unit,
    onCopy: (Clip) -> Boolean,
    onTogglePin: (Clip) -> Unit,
    onDelete: (Clip) -> Unit,
    onShare: (Clip) -> Unit,
    onOpenLink: (String) -> Unit,
    onSaveImage: (Clip) -> Unit,
) {
    val context = LocalContext.current
    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf(HistoryFilter.All) }
    val listState = rememberLazyListState()
    val now = rememberNow()

    val visible = remember(snapshot.history, snapshot.members, pendingDeletes, query, filter) {
        val q = query.trim()
        snapshot.history.filter { c ->
            c.id !in pendingDeletes &&
                when (filter) {
                    HistoryFilter.All -> true
                    HistoryFilter.Text -> c.isText && ClipLook.of(c) !is ClipLook.Link
                    HistoryFilter.Links -> c.isText && ClipLook.of(c) is ClipLook.Link
                    HistoryFilter.Images -> c.isImage
                    HistoryFilter.Pinned -> c.pinned
                } &&
                (q.isEmpty() || c.text?.contains(q, ignoreCase = true) == true || nameOf(c).contains(q, ignoreCase = true))
        }
    }
    val day = Format.dayKey(now)
    // Section titles depend on the language: key on the resolved strings / locale so they follow a change.
    val pinnedTitle = stringResource(R.string.section_pinned)
    val locale = LocalConfiguration.current.locales[0]
    val sections = remember(visible, filter, query, day, pinnedTitle, locale) {
        val out = ArrayList<HistorySection>()
        val pinnedOnTop = filter == HistoryFilter.All && query.isBlank()
        if (pinnedOnTop) {
            val pinned = visible.filter { it.pinned }
            if (pinned.isNotEmpty()) out.add(HistorySection("pinned", pinnedTitle, pinned))
        }
        val rest = if (pinnedOnTop) visible.filter { !it.pinned } else visible
        val byDay = LinkedHashMap<java.time.LocalDate, MutableList<Clip>>()
        for (c in rest) byDay.getOrPut(Format.dayKey(c.ts)) { ArrayList() }.add(c)
        for ((d, clips) in byDay) out.add(HistorySection(d.toString(), Format.dayTitle(context, clips.first().ts, now), clips))
        out
    }
    val scrolled by remember { derivedStateOf { listState.canScrollBackward } }
    val barColor by animateColorAsState(
        if (scrolled) MaterialTheme.colorScheme.surfaceContainer else MaterialTheme.colorScheme.surface,
        label = "bar",
    )
    val fabExpanded by remember { derivedStateOf { listState.firstVisibleItemIndex == 0 } }
    val sendLabel = stringResource(R.string.send_clipboard)

    Scaffold(
        topBar = {
            Column(Modifier.background(barColor)) {
                TopAppBar(
                    title = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            LogoTile(30.dp)
                            Spacer(Modifier.width(12.dp))
                            Text(stringResource(R.string.app_name))
                        }
                    },
                    actions = {
                        DeviceStatusChip(snapshot, settings.paused, onOpenDevices, onAddDevice)
                        IconButton(onClick = onOpenSettings) {
                            Sym(R.drawable.ic_settings, stringResource(R.string.settings))
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, scrolledContainerColor = Color.Transparent),
                )
                SearchField(query, { query = it })
                Spacer(Modifier.height(8.dp))
                LazyRow(
                    contentPadding = PaddingValues(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(HistoryFilter.entries) { f ->
                        FilterChip(
                            selected = f == filter,
                            onClick = { filter = f },
                            label = { Text(stringResource(f.label)) },
                            leadingIcon = if (f == filter) {
                                { Sym(R.drawable.ic_check, null, Modifier.size(18.dp)) }
                            } else {
                                null
                            },
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
            }
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = onSendClipboard,
                expanded = fabExpanded,
                icon = { Sym(R.drawable.ic_content_paste_go, null) },
                text = { Text(sendLabel) },
                // The collapsible FAB hides its label from accessibility; give the button its name explicitly.
                modifier = Modifier.semantics { contentDescription = sendLabel },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHost) },
    ) { padding ->
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(top = padding.calculateTopPadding() + 4.dp, bottom = padding.calculateBottomPadding() + 96.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            if (settings.paused) item("paused") { PausedBanner(onResume, Modifier.animateItem()) }
            if (snapshot.otherMembers.isEmpty()) item("no-devices") { NoDevicesCard(onAddDevice, Modifier.animateItem()) }
            if (sections.isEmpty()) {
                item("empty") {
                    when {
                        query.isNotBlank() -> EmptyState(R.drawable.ic_search, stringResource(R.string.empty_search_title), stringResource(R.string.empty_search_body))
                        filter == HistoryFilter.Pinned -> EmptyState(R.drawable.ic_push_pin, stringResource(R.string.empty_pinned_title), stringResource(R.string.empty_pinned_body))
                        filter != HistoryFilter.All -> EmptyState(R.drawable.ic_history, stringResource(R.string.empty_filter_title), stringResource(R.string.empty_body))
                        else -> EmptyState(R.drawable.ic_content_paste, stringResource(R.string.empty_title), stringResource(R.string.empty_body))
                    }
                }
            }
            for (section in sections) {
                item(key = "h-" + section.key) {
                    SectionHeader(section.title, Modifier.animateItem(), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                items(section.clips, key = { it.id }) { clip ->
                    ClipRow(
                        clip = clip,
                        sourceName = nameOf(clip),
                        sourcePlatform = platformOf(clip),
                        now = now,
                        imageFile = if (clip.isImage) blobFile(clip) else null,
                        onCopy = { onCopy(clip) },
                        onTogglePin = { onTogglePin(clip) },
                        onDelete = { onDelete(clip) },
                        onShare = { onShare(clip) },
                        onOpenLink = onOpenLink,
                        onSaveImage = { onSaveImage(clip) },
                        modifier = Modifier
                            .animateItem()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit) {
    val focus = LocalFocusManager.current
    val label = stringResource(R.string.search_history)
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .height(52.dp),
    ) {
        Row(Modifier.padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(R.drawable.ic_search, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(12.dp))
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                if (query.isEmpty()) {
                    Text(label, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
                BasicTextField(
                    value = query,
                    onValueChange = onChange,
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = label },
                )
            }
            if (query.isNotEmpty()) {
                IconButton(onClick = { onChange("") }) {
                    Sym(R.drawable.ic_close, stringResource(R.string.clear_search))
                }
            } else {
                Spacer(Modifier.width(12.dp))
            }
        }
    }
}

@Composable
private fun DeviceStatusChip(snapshot: EngineSnapshot, paused: Boolean, onOpenDevices: () -> Unit, onAddDevice: () -> Unit) {
    val others = snapshot.otherMembers
    val online = others.filter { it.id in snapshot.online }
    val text = when {
        paused -> stringResource(R.string.status_paused)
        others.isEmpty() -> stringResource(R.string.add_device)
        online.isEmpty() -> stringResource(R.string.status_not_connected)
        else -> pluralStringResource(R.plurals.devices_connected_short, online.size, online.size)
    }
    Surface(
        onClick = if (others.isEmpty() && !paused) onAddDevice else onOpenDevices,
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.padding(end = 4.dp),
    ) {
        Row(Modifier.padding(start = 8.dp, end = 12.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            when {
                paused -> Sym(R.drawable.ic_pause, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                others.isEmpty() -> Sym(R.drawable.ic_add, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary)
                else -> {
                    AvatarStack((online.ifEmpty { others }).map { it.platform })
                }
            }
            Spacer(Modifier.width(8.dp))
            if (!paused && online.isNotEmpty()) {
                StatusDot(true, size = 8.dp, ring = MaterialTheme.colorScheme.surfaceContainerHigh)
                Spacer(Modifier.width(6.dp))
            }
            Text(text, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun PausedBanner(onResume: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        color = MaterialTheme.colorScheme.tertiaryContainer,
        contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
        shape = RoundedCornerShape(24.dp),
        modifier = modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Row(Modifier.padding(start = 20.dp, top = 12.dp, bottom = 12.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(R.drawable.ic_pause, null)
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.syncing_paused), style = MaterialTheme.typography.titleSmall)
                Text(stringResource(R.string.paused_banner_body), style = MaterialTheme.typography.bodySmall)
            }
            TextButton(onClick = onResume) { Text(stringResource(R.string.resume)) }
        }
    }
}

@Composable
private fun NoDevicesCard(onAddDevice: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        color = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        shape = RoundedCornerShape(28.dp),
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Column(Modifier.padding(24.dp)) {
            Sym(R.drawable.ic_devices, null, Modifier.size(28.dp))
            Spacer(Modifier.height(14.dp))
            Text(stringResource(R.string.no_devices_title), style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(6.dp))
            Text(stringResource(R.string.no_devices_body), style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(18.dp))
            Button(onClick = onAddDevice) {
                Sym(R.drawable.ic_add, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.add_device))
            }
        }
    }
}
