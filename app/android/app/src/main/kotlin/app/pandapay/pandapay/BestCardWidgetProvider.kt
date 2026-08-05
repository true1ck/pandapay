package app.pandapay.pandapay

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * UA-8.2 (Chunk 32): reads the "best card right now" data that
 * app/lib/features/home_widget/home_widget_service.dart writes via
 * `HomeWidget.saveWidgetData` (backed by this same SharedPreferences file)
 * and pushes it into the widget's RemoteViews.
 *
 * Keys read here (`best_card_name`, `best_card_value_formatted`,
 * `best_card_none`) must match `HomeWidgetService`'s
 * `cardNameKey`/`cardValueKey`/`noCardKey` constants exactly — there is no
 * shared schema file between Dart and Kotlin here, just this comment.
 *
 * NOT VERIFIED: this class was never compiled against a real Android
 * build, never registered through an actual `flutter build apk`/gradle
 * run, and never seen rendering on a real device or emulator — this
 * sandbox has no Android SDK/emulator (same gap noted for UA-4/UA-5.3's
 * native plumbing in PROGRESS.md). It's wired into AndroidManifest.xml as
 * a `<receiver>` so the pieces are structurally complete, but "structurally
 * complete" is explicitly not the same claim as "verified working."
 */
class BestCardWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.best_card_widget)

            val noCard = widgetData.getBoolean("best_card_none", true)
            if (noCard) {
                views.setTextViewText(R.id.widget_card_name, "No card yet")
                views.setTextViewText(R.id.widget_card_value, "")
            } else {
                val name = widgetData.getString("best_card_name", "") ?: ""
                val value = widgetData.getString("best_card_value_formatted", "") ?: ""
                views.setTextViewText(R.id.widget_card_name, name)
                views.setTextViewText(R.id.widget_card_value, value)
            }

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
