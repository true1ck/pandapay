package app.pandapay.pandapay

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

/**
 * S2 (ui-spec System Surfaces, GAP_ANALYSIS.md §3) — Quick Settings tile
 * showing the "best card right now" at a glance. Reads the exact same
 * SharedPreferences file BestCardWidgetProvider.kt already reads (written
 * from Dart via `HomeWidget.saveWidgetData`, see
 * app/lib/features/home_widget/home_widget_service.dart) — same keys
 * (`best_card_name`, `best_card_value_formatted`, `best_card_none`), no new
 * Dart-side plumbing needed. Tapping the tile opens the app; a
 * QuickSettings tile can't render rich UI or accept taps on sub-elements,
 * so "open the app to see full detail" is the tile's whole interaction,
 * same as most system Quick Settings tiles that surface a single glanceable
 * fact and defer everything else to the app.
 *
 * NOT VERIFIED: same caveat as BestCardWidgetProvider.kt — never compiled
 * against a real Android build or seen rendering in a real Quick Settings
 * panel in this sandbox (no Android SDK/emulator here). Registered in
 * AndroidManifest.xml as a `<service>` so the pieces are structurally
 * complete; that is explicitly not the same claim as "verified working."
 */
@RequiresApi(Build.VERSION_CODES.N)
class BestCardTileService : TileService() {
    companion object {
        private const val PREFS_NAME = "HomeWidgetPreferences"
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        if (launchIntent != null) {
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            startActivityAndCollapse(launchIntent)
        }
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val prefs: SharedPreferences = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val noCard = prefs.getBoolean("best_card_none", true)

        if (noCard) {
            tile.label = "PandaPay"
            tile.subtitle = "No recommendation yet"
            tile.state = Tile.STATE_INACTIVE
        } else {
            val name = prefs.getString("best_card_name", "") ?: ""
            val value = prefs.getString("best_card_value_formatted", "") ?: ""
            tile.label = name
            tile.subtitle = value
            tile.state = Tile.STATE_ACTIVE
        }
        tile.updateTile()
    }
}
