package app.pandapay.pandapay

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * UA-8.2: reads the "best card right now" data that
 * app/lib/features/home_widget/home_widget_service.dart writes via
 * `HomeWidget.saveWidgetData` and pushes it into the widget's RemoteViews.
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
            val name = widgetData.getString("best_card_name", "") ?: ""
            val value = widgetData.getString("best_card_value_formatted", "") ?: ""

            if (noCard || name.isEmpty()) {
                views.setTextViewText(R.id.widget_card_name, "No card yet")
                views.setTextViewText(R.id.widget_card_value, "Tap to open PandaPay")
            } else {
                views.setTextViewText(R.id.widget_card_name, name)
                views.setTextViewText(R.id.widget_card_value, value)
            }

            // Clicking anywhere on the widget launches PandaPay
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
            launchIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            val pendingIntent = PendingIntent.getActivity(
                context,
                widgetId,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_container, pendingIntent)

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
