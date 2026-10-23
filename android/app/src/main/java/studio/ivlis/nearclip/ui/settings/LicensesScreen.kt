package studio.ivlis.nearclip.ui.settings

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.ui.components.SectionHeader
import studio.ivlis.nearclip.ui.components.SettingsGroup
import studio.ivlis.nearclip.ui.components.SettingsRow
import studio.ivlis.nearclip.ui.components.Sym

private class Library(val name: String, val owner: String)

/**
 * The license file is hard-wrapped at 76 columns with indentation, which wraps raggedly on a phone. Paragraphs
 * (separated by blank lines) are re-joined so they wrap to the screen; the title block keeps its three lines.
 */
private fun reflow(text: String): List<String> =
    text.trim('\n').split(Regex("\\n\\s*\\n")).mapIndexedNotNull { i, para ->
        val lines = para.lines().map { it.trim() }.filter { it.isNotEmpty() }
        if (lines.isEmpty()) null else lines.joinToString(if (i == 0) "\n" else " ")
    }

private fun isHeading(p: String) = p.length < 80 && (p == p.uppercase() || Regex("^\\d+\\. ").containsMatchIn(p) && p.length < 40)

private val libraries = listOf(
    Library("Jetpack Compose, Material 3", "The Android Open Source Project"),
    Library("AndroidX Core, Activity, Lifecycle, Navigation", "The Android Open Source Project"),
    Library("CameraX", "The Android Open Source Project"),
    Library("Kotlin, kotlinx.coroutines, kotlinx.serialization", "JetBrains s.r.o."),
    Library("ZXing", "ZXing authors"),
    Library("Material Symbols", "Google"),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LicensesScreen(onBack: () -> Unit) {
    val resources = LocalResources.current
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var showText by rememberSaveable { mutableStateOf(false) }
    val license = remember(resources) {
        reflow(resources.openRawResource(R.raw.apache_license_2_0).bufferedReader().use { it.readText() })
    }
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text(stringResource(R.string.licenses)) },
                navigationIcon = { IconButton(onClick = onBack) { Sym(R.drawable.ic_arrow_back, stringResource(R.string.back)) } },
                scrollBehavior = scroll,
            )
        },
    ) { padding ->
        LazyColumn(contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 32.dp)) {
            item {
                Text(
                    stringResource(R.string.licenses_intro),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
                )
                SectionHeader(stringResource(R.string.license_apache))
                SettingsGroup {
                    for (lib in libraries) SettingsRow(title = lib.name, summary = lib.owner)
                }
                TextButton(onClick = { showText = !showText }, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text(stringResource(if (showText) R.string.hide_license_text else R.string.show_license_text))
                }
            }
            item {
                AnimatedVisibility(showText) {
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainer,
                        shape = MaterialTheme.shapes.large,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    ) {
                        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            license.forEachIndexed { i, p ->
                                when {
                                    i == 0 -> Text(
                                        p,
                                        style = MaterialTheme.typography.titleMedium,
                                        textAlign = TextAlign.Center,
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                    isHeading(p) -> Text(p, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 4.dp))
                                    else -> Text(p, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
