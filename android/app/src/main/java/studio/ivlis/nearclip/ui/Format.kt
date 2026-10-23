package studio.ivlis.nearclip.ui

import android.content.Context
import androidx.compose.ui.graphics.Color
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.Platform
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.util.Locale

object Format {
    private const val MINUTE = 60_000L
    private const val HOUR = 60 * MINUTE
    private const val DAY = 24 * HOUR

    private fun locale(context: Context): Locale = context.resources.configuration.locales[0] ?: Locale.getDefault()

    /** "just now", "5 min ago", "3 h ago", "2 d ago", then a date. */
    fun relative(context: Context, ts: Long, now: Long): String {
        val d = (now - ts).coerceAtLeast(0)
        val r = context.resources
        return when {
            d < MINUTE -> context.getString(R.string.just_now)
            d < HOUR -> (d / MINUTE).toInt().let { r.getQuantityString(R.plurals.minutes_ago, it, it) }
            d < DAY -> (d / HOUR).toInt().let { r.getQuantityString(R.plurals.hours_ago, it, it) }
            d < 7 * DAY -> (d / DAY).toInt().let { r.getQuantityString(R.plurals.days_ago, it, it) }
            else -> shortDate(context, ts, now)
        }
    }

    fun shortDate(context: Context, ts: Long, now: Long): String {
        val zone = ZoneId.systemDefault()
        val date = Instant.ofEpochMilli(ts).atZone(zone).toLocalDate()
        val sameYear = date.year == Instant.ofEpochMilli(now).atZone(zone).year
        val loc = locale(context)
        val pattern = if (sameYear) {
            if (loc.language == "ko") "M월 d일" else "MMM d"
        } else {
            if (loc.language == "ko") "yyyy년 M월 d일" else "MMM d, yyyy"
        }
        return DateTimeFormatter.ofPattern(pattern, loc).format(date)
    }

    /** History section titles: Today / Yesterday / weekday / date (DESIGN §4.4). */
    fun dayTitle(context: Context, ts: Long, now: Long): String {
        val zone = ZoneId.systemDefault()
        val day = Instant.ofEpochMilli(ts).atZone(zone).toLocalDate()
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        return when {
            day == today -> context.getString(R.string.today)
            day == today.minusDays(1) -> context.getString(R.string.yesterday)
            day.isAfter(today.minusDays(7)) -> day.dayOfWeek.getDisplayName(TextStyle.FULL, locale(context))
            else -> shortDate(context, ts, now)
        }
    }

    fun dayKey(ts: Long): LocalDate = Instant.ofEpochMilli(ts).atZone(ZoneId.systemDefault()).toLocalDate()

    fun lastSeen(context: Context, ts: Long?, now: Long): String =
        if (ts == null || ts <= 0) context.getString(R.string.not_nearby)
        else if (now - ts < MINUTE) context.getString(R.string.last_seen_just_now)
        else context.getString(R.string.last_seen, relative(context, ts, now))

    fun platformName(context: Context, platform: String): String = context.getString(
        when (platform) {
            Platform.MAC -> R.string.platform_mac
            Platform.WINDOWS -> R.string.platform_win
            Platform.ANDROID -> R.string.platform_android
            Platform.IOS -> R.string.platform_ios
            Platform.CLI -> R.string.platform_cli
            else -> R.string.platform_other
        },
    )

    fun fullDateTime(context: Context, ts: Long): String =
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(locale(context))
            .format(Instant.ofEpochMilli(ts).atZone(ZoneId.systemDefault()))

    fun countdown(seconds: Long): String {
        val s = seconds.coerceAtLeast(0)
        return "%d:%02d".format(Locale.ROOT, s / 60, s % 60)
    }
}

/** How a clip is presented in the history (DESIGN §4.4 row rules). */
sealed interface ClipLook {
    data class Text(val preview: String) : ClipLook
    data class Link(val url: String, val host: String, val rest: String) : ClipLook
    data class ColorCode(val code: String, val color: Color) : ClipLook
    data object Image : ClipLook

    companion object {
        private val LINK = Regex("^(?:(https?)://)?((?:[a-z0-9-]+\\.)+[a-z]{2,63})(?::\\d{1,5})?(/\\S*)?$", RegexOption.IGNORE_CASE)
        private val COLOR = Regex("^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")

        fun of(clip: Clip): ClipLook {
            if (clip.isImage) return Image
            val text = clip.text ?: ""
            val t = text.trim()
            if (t.length <= 2048 && !t.contains(Regex("\\s"))) {
                if (COLOR.matches(t)) parseColor(t)?.let { return ColorCode(t.uppercase(), it) }
                val m = LINK.matchEntire(t)
                if (m != null && (m.groupValues[1].isNotEmpty() || t.startsWith("www.", ignoreCase = true))) {
                    val host = m.groupValues[2].lowercase().removePrefix("www.")
                    val afterHost = t.substring(t.indexOf(m.groupValues[2]) + m.groupValues[2].length)
                    val url = if (m.groupValues[1].isEmpty()) "https://${t}" else t
                    return Link(url, host, afterHost.trimEnd('/'))
                }
            }
            return Text(preview(text))
        }

        fun isLink(clip: Clip) = of(clip) is Link

        private fun preview(text: String): String {
            val lines = text.trim().lines().map { it.trimEnd() }.filter { it.isNotBlank() }
            return lines.take(3).joinToString("\n").take(400)
        }

        private fun parseColor(code: String): Color? {
            val hex = code.removePrefix("#")
            val full = when (hex.length) {
                3 -> hex.map { "${it}${it}" }.joinToString("")
                6, 8 -> hex
                else -> return null
            }
            val v = full.toLongOrNull(16) ?: return null
            return if (full.length == 6) Color(0xFF000000 or v) else Color(((v and 0xFF) shl 24) or (v ushr 8))
        }
    }
}
