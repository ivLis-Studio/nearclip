package studio.ivlis.nearclip.runtime

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI

object UpdateChecker {
    const val RELEASE_URL = "https://github.com/ivLis-Studio/nearclip/releases/latest"
    private val versionPattern = Regex("\\d+\\.\\d+\\.\\d+")
    suspend fun check(context: Context, current: String): String? = withContext(Dispatchers.IO) {
        val prefs = context.getSharedPreferences("nearclip.updates", Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        if (now - prefs.getLong("at", 0) < 86_400_000L) return@withContext prefs.getString("newer", null)
        val connection = URI("https://api.github.com/repos/ivLis-Studio/nearclip/releases/latest").toURL().openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 10_000; connection.readTimeout = 10_000
            connection.setRequestProperty("Accept", "application/vnd.github+json")
            if (connection.responseCode != 200) error("release check failed")
            val release = JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
            val version = release.getString("tag_name").removePrefix("v")
            require(versionPattern.matches(version) && !release.optBoolean("draft") && !release.optBoolean("prerelease"))
            val available = version.split('.').map { it.toInt() }.zip(current.split('.').map { it.toInt() })
                .firstOrNull { it.first != it.second }?.let { it.first > it.second } == true
            val newer = version.takeIf { available }
            prefs.edit().putLong("at", now).putString("newer", newer).apply()
            newer
        } finally { connection.disconnect() }
    }
}
