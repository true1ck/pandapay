package app.pandapay.pandapay

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider
import kotlin.math.abs
import kotlin.math.ln

abstract class PandaPayWidgetProvider : HomeWidgetProvider() {
    protected abstract fun buildWidget(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        data: SharedPreferences,
        options: Bundle,
        size: SizeF?,
    ): RemoteViews

    private fun updateWidget(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        data: SharedPreferences,
        options: Bundle,
    ) {
        val sizes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                ?.distinct()
        } else {
            null
        }
        if (sizes.isNullOrEmpty()) {
            manager.updateAppWidget(widgetId, buildWidget(context, manager, widgetId, data, options, null))
        } else {
            val viewsBySize = sizes.associateWith { size ->
                buildWidget(context, manager, widgetId, data, options, size)
            }
            manager.updateAppWidget(widgetId, RemoteViews(viewsBySize))
        }
    }

    final override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            updateWidget(
                context,
                appWidgetManager,
                widgetId,
                widgetData,
                appWidgetManager.getAppWidgetOptions(widgetId),
            )
        }
    }

    final override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        val data = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        updateWidget(context, appWidgetManager, appWidgetId, data, newOptions)
    }

    protected fun isExpanded(options: Bundle, size: SizeF?): Boolean {
        val width = size?.width ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).toFloat()
        val height = size?.height ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT).toFloat()
        return (width >= 250 && height >= 210) ||
            (width >= 330 && height >= 145) ||
            (width >= 170 && height >= 320)
    }

    protected fun expandedDetailsPath(
        options: Bundle,
        data: SharedPreferences,
        squareKey: String,
        portraitKey: String,
        wideKey: String,
        mediumKey: String,
        largeKey: String,
        size: SizeF?,
    ): String? {
        val width = size?.width ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).toFloat()
        val height = size?.height ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT).toFloat()
        val aspectRatio = if (height > 0) width / height else 1f
        val prefix = if (squareKey.startsWith("spending")) "spending" else "expanded"
        // Pick the actual bitmap shape nearest to the host's reported size.
        // Coarse thresholds previously put a 2:1 image in a 4:3 widget.
        val keys = listOf(
            squareKey, portraitKey, wideKey, mediumKey, largeKey,
            "${prefix}_landscape_details_path", "${prefix}_tall_details_path",
        )
        return keys.mapNotNull { key ->
            val path = data.getString(key, null)?.takeIf { it.isNotBlank() }
                ?: return@mapNotNull null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@mapNotNull null
            val imageRatio = bounds.outWidth.toFloat() / bounds.outHeight
            path to abs(ln(imageRatio / aspectRatio.coerceAtLeast(0.01f)))
        }.minByOrNull { it.second }?.first
    }

    protected fun clickIntent(
        context: Context,
        widgetId: Int,
        uri: String,
    ): PendingIntent {
        val intent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse(uri),
            context,
            MainActivity::class.java,
        ).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            context,
            widgetId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    protected fun compactDetailsPath(options: Bundle, size: SizeF?, data: SharedPreferences, squareKey: String, wideKey: String): String? {
        val width = size?.width ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).toFloat()
        val height = size?.height ?: options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT).toFloat()
        return data.getString(if (height > 0 && width / height > 1.5f) wideKey else squareKey, null)
    }

    protected fun setImage(views: RemoteViews, viewId: Int, path: String?): Boolean {
        val bitmap = path?.takeIf { it.isNotBlank() }?.let(BitmapFactory::decodeFile)
        if (bitmap == null) {
            views.setViewVisibility(viewId, android.view.View.GONE)
        } else {
            views.setImageViewBitmap(viewId, bitmap)
            views.setViewVisibility(viewId, android.view.View.VISIBLE)
        }
        return bitmap != null
    }
}

class CombinedHomeWidgetProvider : PandaPayWidgetProvider() {
    override fun buildWidget(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        data: SharedPreferences,
        options: Bundle,
        size: SizeF?,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.combined_home_widget)
        val period = data.getString("spend_period_label", "This month") ?: "This month"
        views.setTextViewText(R.id.widget_period_label, period.uppercase())
        setImage(views, R.id.widget_brand_mark, data.getString("widget_brand_mark_path", null))
        setImage(views, R.id.widget_spend_chart, data.getString("spend_chart_path", null))
        views.setTextViewText(
            R.id.widget_card_name,
            if (data.getBoolean("best_card_none", true)) {
                "Add a card"
            } else {
                data.getString("best_card_name", "")
            },
        )
        views.setTextViewText(
            R.id.widget_card_value,
            if (data.getBoolean("best_card_none", true)) {
                "See card picks"
            } else {
                data.getString("best_card_value_formatted", "")
            },
        )
        val topCategory = data.getString("spend_top_category", "").orEmpty()
        val categoryValue = data.getString("spend_top_category_value_formatted", "").orEmpty()
        views.setTextViewText(
            R.id.widget_top_category,
            if (topCategory.isBlank()) "Tap pie for categories" else "$topCategory  ·  $categoryValue",
        )
        val expanded = isExpanded(options, size)
        val expandedPath = expandedDetailsPath(
            options = options,
            data = data,
            squareKey = "expanded_details_path",
            portraitKey = "expanded_portrait_details_path",
            wideKey = "expanded_wide_details_path",
            mediumKey = "expanded_medium_details_path",
            largeKey = "expanded_large_details_path",
            size = size,
        )
        val rendered = setImage(views, R.id.widget_expanded_details, if (expanded) expandedPath else compactDetailsPath(options, size, data, "compact_details_path", "compact_wide_details_path"))
        views.setViewVisibility(
            R.id.widget_compact_content,
            if (rendered) android.view.View.GONE else android.view.View.VISIBLE,
        )
        views.setViewVisibility(
            R.id.widget_expanded_details,
            if (rendered) android.view.View.VISIBLE else android.view.View.GONE,
        )
        views.setOnClickPendingIntent(
            R.id.widget_container,
            clickIntent(context, widgetId, "pandapay://assistant/spending?period=month"),
        )
        return views
    }
}

class SpendingHomeWidgetProvider : PandaPayWidgetProvider() {
    override fun buildWidget(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        data: SharedPreferences,
        options: Bundle,
        size: SizeF?,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.spending_home_widget)
        val period = data.getString("spend_period_label", "This month") ?: "This month"
        views.setTextViewText(R.id.widget_period_label, period.uppercase())
        setImage(views, R.id.widget_brand_mark, data.getString("widget_brand_mark_path", null))
        setImage(views, R.id.widget_spend_chart, data.getString("spend_chart_path", null))
        views.setTextViewText(
            R.id.widget_top_category,
            data.getString("spend_top_category", "")?.takeIf(String::isNotBlank)
                ?: "No categories yet",
        )
        views.setTextViewText(
            R.id.widget_top_category_value,
            data.getString("spend_top_category_value_formatted", "").orEmpty(),
        )
        views.setTextViewText(
            R.id.widget_rewards,
            "${data.getString("spend_rewards_formatted", "₹0")} rewards",
        )
        val expanded = isExpanded(options, size)
        val spendingDetailsPath = expandedDetailsPath(
            options = options,
            data = data,
            squareKey = "spending_details_path",
            portraitKey = "spending_portrait_details_path",
            wideKey = "spending_wide_details_path",
            mediumKey = "spending_medium_details_path",
            largeKey = "spending_large_details_path",
            size = size,
        )
        val rendered = setImage(
            views,
            R.id.widget_expanded_details,
            if (expanded) spendingDetailsPath else compactDetailsPath(options, size, data, "spending_compact_details_path", "spending_compact_wide_details_path"),
        )
        views.setViewVisibility(
            R.id.widget_compact_content,
            if (rendered) android.view.View.GONE else android.view.View.VISIBLE,
        )
        views.setViewVisibility(
            R.id.widget_expanded_details,
            if (rendered) android.view.View.VISIBLE else android.view.View.GONE,
        )
        views.setOnClickPendingIntent(
            R.id.widget_container,
            clickIntent(context, widgetId, "pandapay://assistant/spending?period=month"),
        )
        return views
    }
}

class BestCardWidgetProvider : PandaPayWidgetProvider() {
    override fun buildWidget(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        data: SharedPreferences,
        options: Bundle,
        size: SizeF?,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.best_card_widget)
        setImage(views, R.id.widget_brand_mark, data.getString("widget_brand_mark_path", null))
        setImage(views, R.id.widget_card_art, data.getString("best_card_art_path", null))
        val hasCard = !data.getBoolean("best_card_none", true)
        views.setTextViewText(
            R.id.widget_card_name,
            if (hasCard) data.getString("best_card_name", "") else "No card yet",
        )
        views.setTextViewText(
            R.id.widget_card_value,
            if (hasCard) data.getString("best_card_value_formatted", "")
            else "Open PandaPay to see your card picks",
        )
        views.setTextViewText(
            R.id.widget_card_reason,
            data.getString("best_card_reason", "")?.takeIf(String::isNotBlank)
                ?: "Recommended for your Home selection",
        )
        views.setOnClickPendingIntent(
            R.id.widget_container,
            clickIntent(context, widgetId, "pandapay://assistant/best-card"),
        )
        return views
    }
}
