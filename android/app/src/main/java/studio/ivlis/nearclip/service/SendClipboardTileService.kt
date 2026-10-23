package studio.ivlis.nearclip.service

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.runtime.Nearclip
import studio.ivlis.nearclip.ui.SendActivity

/** Quick Settings tile "Send clipboard" (DESIGN §5 Android). */
class SendClipboardTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        val rt = Nearclip.get(this)
        val snap = rt.engine.state.value
        val paused = rt.settings.value.paused
        tile.label = getString(R.string.send_clipboard)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_content_paste_go)
        tile.state = if (paused) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        if (Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = when {
                paused -> getString(R.string.syncing_paused)
                snap.onlineCount > 0 -> resources.getQuantityString(R.plurals.devices_connected_short, snap.onlineCount, snap.onlineCount)
                else -> getString(R.string.app_name)
            }
        }
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val intent = SendActivity.clipboardIntent(this)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
