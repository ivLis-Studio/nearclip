package studio.ivlis.nearclip.ui.theme

import android.content.Context
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.LineBreak

object Brand {
    val Iris = Color(0xFF4C5BF5)
    val IrisDark = Color(0xFF8B96FF)
    val Online = Color(0xFF2FBF71)
    val Warning = Color(0xFFF5A524)

    /** Online green for text: the brand green is too light for 4.5:1 on light surfaces (DESIGN §6). */
    val OnlineText: Color
        @Composable get() = if (MaterialTheme.colorScheme.surface.luminance() > 0.5f) Color(0xFF16774A) else Online
}

/** The Iris scheme used below Android 12 (no dynamic color). Accent #4C5BF5 / dark #8B96FF (DESIGN §2). */
private val IrisLight = lightColorScheme(
    primary = Color(0xFF4C5BF5), onPrimary = Color.White,
    primaryContainer = Color(0xFFE0E0FF), onPrimaryContainer = Color(0xFF0B1270),
    secondary = Color(0xFF5B5D72), onSecondary = Color.White,
    secondaryContainer = Color(0xFFE0E1F9), onSecondaryContainer = Color(0xFF181A2C),
    tertiary = Color(0xFF77536D), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFD7F1), onTertiaryContainer = Color(0xFF2D1228),
    error = Color(0xFFBA1A1A), onError = Color.White,
    errorContainer = Color(0xFFFFDAD6), onErrorContainer = Color(0xFF410002),
    background = Color(0xFFFBF8FF), onBackground = Color(0xFF1B1B21),
    surface = Color(0xFFFBF8FF), onSurface = Color(0xFF1B1B21),
    surfaceVariant = Color(0xFFE3E1EC), onSurfaceVariant = Color(0xFF46464F),
    outline = Color(0xFF777680), outlineVariant = Color(0xFFC7C5D0),
    inverseSurface = Color(0xFF303036), inverseOnSurface = Color(0xFFF2EFF7), inversePrimary = Color(0xFFBDC2FF),
    surfaceDim = Color(0xFFDBD9E0), surfaceBright = Color(0xFFFBF8FF),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF5F2FA),
    surfaceContainer = Color(0xFFEFEDF4), surfaceContainerHigh = Color(0xFFE9E7EF),
    surfaceContainerHighest = Color(0xFFE4E1E9),
)

private val IrisDarkScheme = darkColorScheme(
    primary = Color(0xFF8B96FF), onPrimary = Color(0xFF0E1675),
    primaryContainer = Color(0xFF2E3BB8), onPrimaryContainer = Color(0xFFE0E0FF),
    secondary = Color(0xFFC4C5DD), onSecondary = Color(0xFF2D2F42),
    secondaryContainer = Color(0xFF434659), onSecondaryContainer = Color(0xFFE0E1F9),
    tertiary = Color(0xFFE6BAD7), onTertiary = Color(0xFF45263E),
    tertiaryContainer = Color(0xFF5D3C55), onTertiaryContainer = Color(0xFFFFD7F1),
    error = Color(0xFFFFB4AB), onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A), onErrorContainer = Color(0xFFFFDAD6),
    background = Color(0xFF131318), onBackground = Color(0xFFE4E1E9),
    surface = Color(0xFF131318), onSurface = Color(0xFFE4E1E9),
    surfaceVariant = Color(0xFF46464F), onSurfaceVariant = Color(0xFFC7C5D0),
    outline = Color(0xFF918F9A), outlineVariant = Color(0xFF46464F),
    inverseSurface = Color(0xFFE4E1E9), inverseOnSurface = Color(0xFF303036), inversePrimary = Color(0xFF4C5BF5),
    surfaceDim = Color(0xFF131318), surfaceBright = Color(0xFF39383F),
    surfaceContainerLowest = Color(0xFF0E0E13), surfaceContainerLow = Color(0xFF1B1B21),
    surfaceContainer = Color(0xFF1F1F25), surfaceContainerHigh = Color(0xFF2A292F),
    surfaceContainerHighest = Color(0xFF35343A),
)

/** True when the user turned animations off (Settings › Accessibility › Remove animations). */
val LocalReduceMotion = staticCompositionLocalOf { false }

/*
 * Line breaking. Korean separates words with spaces, and good Korean typesetting never breaks inside a word
 * (CSS "keep-all"); the default break iterator treats every Hangul syllable as a break opportunity, which
 * strands single syllables ("…확인하세 / 요") and splits words ("클 / 립보드"). WordBreak.Phrase maps to
 * LineBreakConfig.LINE_BREAK_WORD_STYLE_PHRASE (API 33+), which breaks Korean at spaces and Japanese at
 * phrase boundaries, and leaves Latin text unchanged. Titles also use the balanced strategy, so that a
 * two-line dialog title splits evenly; body styles stay greedy so that truncated clip previews keep as much
 * text as fits.
 */
private val TitleBreak = LineBreak(LineBreak.Strategy.Balanced, LineBreak.Strictness.Normal, LineBreak.WordBreak.Phrase)
private val BodyBreak = LineBreak(LineBreak.Strategy.HighQuality, LineBreak.Strictness.Normal, LineBreak.WordBreak.Phrase)

private fun TextStyle.title() = copy(lineBreak = TitleBreak)
private fun TextStyle.body() = copy(lineBreak = BodyBreak)

private val NearclipTypography: Typography = Typography().run {
    copy(
        displayLarge = displayLarge.title(), displayMedium = displayMedium.title(), displaySmall = displaySmall.title(),
        headlineLarge = headlineLarge.title(), headlineMedium = headlineMedium.title(), headlineSmall = headlineSmall.title(),
        titleLarge = titleLarge.title(), titleMedium = titleMedium.title(), titleSmall = titleSmall.title(),
        bodyLarge = bodyLarge.body(), bodyMedium = bodyMedium.body(), bodySmall = bodySmall.body(),
        labelLarge = labelLarge.body(), labelMedium = labelMedium.body(), labelSmall = labelSmall.body(),
    )
}

fun animationsDisabled(context: Context): Boolean = try {
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
} catch (_: Exception) {
    false
}

@Composable
fun NearclipTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> IrisDarkScheme
        else -> IrisLight
    }
    val reduceMotion = remember { animationsDisabled(context) }
    CompositionLocalProvider(LocalReduceMotion provides reduceMotion) {
        MaterialTheme(colorScheme = scheme, typography = NearclipTypography) {
            // MaterialTheme leaves LocalContentColor at black; screens drawn outside a Scaffold/Surface
            // (onboarding) would otherwise render untinted text black on the dark scheme.
            CompositionLocalProvider(LocalContentColor provides scheme.onSurface, content = content)
        }
    }
}
