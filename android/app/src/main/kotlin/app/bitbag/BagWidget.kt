package app.bitbag

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import android.util.SizeF
import android.widget.RemoteViews
import android.app.PendingIntent
import android.content.Intent
import androidx.work.WorkManager
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray

class BagWidget : HomeWidgetProvider() {

    companion object {
        private const val TAG = "BagWidget"

        // Pre-API31 size thresholds (dp) for layout selection.
        // On API 31+ the launcher picks the right RemoteViews automatically.
        private const val MEDIUM_MIN_HEIGHT_DP = 110
        private const val LARGE_MIN_HEIGHT_DP = 210

        fun updateWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int,
            widgetData: SharedPreferences,
        ) {
            try {
                val small = buildSmall(context, widgetData, appWidgetId)
                val medium = buildMedium(context, widgetData, appWidgetId)
                val large = buildLarge(context, widgetData, appWidgetId)

                val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // Android 12+: launcher picks the largest layout that fits
                    // within the current widget dimensions.
                    // small  = 2×1 flat net worth row
                    // medium = 2×2 / 3×2 price + net worth
                    // large  = 4×3+ price + net worth + chart
                    RemoteViews(
                        mapOf(
                            SizeF(80f, 40f) to small,
                            SizeF(80f, 110f) to medium,
                            SizeF(200f, 210f) to large,
                        )
                    )
                } else {
                    val opts = appWidgetManager.getAppWidgetOptions(appWidgetId)
                    val h = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
                    when {
                        h >= LARGE_MIN_HEIGHT_DP -> large
                        h >= MEDIUM_MIN_HEIGHT_DP -> medium
                        else -> small
                    }
                }

                appWidgetManager.updateAppWidget(appWidgetId, views)
                Log.d(TAG, "Widget $appWidgetId updated")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to update widget $appWidgetId", e)
            }
        }

        // ── Small: net worth only ──────────────────────────────────────────
        private fun buildSmall(context: Context, data: SharedPreferences, appWidgetId: Int): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.bag_widget_small)
            views.setTextViewText(R.id.widget_net_worth, data.getString("widget_net_worth", null) ?: "—")
            views.setTextViewText(
                R.id.widget_updated,
                data.getString("widget_updated_at", null)?.let { "↻ $it" } ?: ""
            )
            applyTap(context, views, R.id.widget_net_worth)
            applySettingsTap(context, views, appWidgetId)
            return views
        }

        // ── Medium: price + % + net worth ──────────────────────────────────
        private fun buildMedium(context: Context, data: SharedPreferences, appWidgetId: Int): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.bag_widget)
            applyPriceData(context, views, data)
            applyPnlData(views, data)
            applyFeeData(views, data)
            applySettingsTap(context, views, appWidgetId)
            return views
        }

        // ── Large: full-bleed native sparkline background + text overlay ────
        private fun buildLarge(context: Context, data: SharedPreferences, appWidgetId: Int): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.bag_widget_large)
            applyPriceData(context, views, data)
            applyPnlData(views, data)
            applyFeeData(views, data)
            applySettingsTap(context, views, appWidgetId)

            val chartJson = data.getString("widget_chart_prices", null)
            if (chartJson != null) {
                try {
                    val arr = JSONArray(chartJson)
                    val prices = (0 until arr.length()).map { arr.getDouble(it) }
                    if (prices.size >= 2) {
                        // Render at 400×200 px — well within the ~1 MB Binder IPC limit
                        // (~320 KB ARGB_8888). fitXY on the ImageView fills the full
                        // background; aspect-ratio stretch is fine for a decorative sparkline.
                        val bitmap = NativeChartRenderer.render(prices, 400, 200)
                        views.setImageViewBitmap(R.id.widget_chart_bg, bitmap)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to render native chart", e)
                }
            }

            return views
        }

        /** Shows the DCA P/L row when both amount and percentage are stored,
         *  hides it otherwise. Only called for medium and large layouts. */
        private fun applyPnlData(views: RemoteViews, data: SharedPreferences) {
            val pnlAmount = data.getString("widget_pnl_amount", null)
            val pnlPct = data.getString("widget_pnl_pct", null)
            val pnlPositive = data.getBoolean("widget_pnl_positive", true)

            if (!pnlAmount.isNullOrEmpty() && !pnlPct.isNullOrEmpty()) {
                views.setTextViewText(R.id.widget_pnl_amount, pnlAmount)
                views.setTextViewText(R.id.widget_pnl_pct, pnlPct)
                val color = if (pnlPositive) 0xFF00C896.toInt() else 0xFFFF4757.toInt()
                views.setTextColor(R.id.widget_pnl_pct, color)
                views.setViewVisibility(R.id.widget_pnl_row, android.view.View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_pnl_row, android.view.View.GONE)
            }
        }

        /** Shows the fast fee row when enabled and data is available, hides otherwise. */
        private fun applyFeeData(views: RemoteViews, data: SharedPreferences) {
            val showFee = data.getBoolean("widget_show_fee", false)
            val fastFee = data.getString("widget_fast_fee", null)

            if (showFee && !fastFee.isNullOrEmpty()) {
                views.setTextViewText(R.id.widget_fast_fee, fastFee)
                views.setViewVisibility(R.id.widget_fee_row, android.view.View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_fee_row, android.view.View.GONE)
            }
        }

        private fun applyPriceData(context: Context, views: RemoteViews, data: SharedPreferences) {
            val price = data.getString("widget_price", null)
            val netWorth = data.getString("widget_net_worth", null)
            val change = data.getString("widget_change", null)
            val changePositive = data.getBoolean("widget_change_positive", true)
            val updatedAt = data.getString("widget_updated_at", null)

            views.setTextViewText(R.id.widget_price, price ?: "—")
            views.setTextViewText(R.id.widget_net_worth, netWorth ?: "—")
            views.setTextViewText(R.id.widget_updated, if (updatedAt != null) "Updated $updatedAt" else "")

            if (!change.isNullOrEmpty()) {
                views.setTextViewText(R.id.widget_change, change)
                val color = if (changePositive) 0xFF00C896.toInt() else 0xFFFF4757.toInt()
                views.setTextColor(R.id.widget_change, color)
            } else {
                views.setTextViewText(R.id.widget_change, "")
            }

            applyTap(context, views, R.id.widget_price, R.id.widget_net_worth)
        }

        private fun applyTap(context: Context, views: RemoteViews, vararg ids: Int) {
            val intent = Intent(context, MainActivity::class.java)
            val pi = PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            for (id in ids) views.setOnClickPendingIntent(id, pi)
        }

        private fun applySettingsTap(context: Context, views: RemoteViews, appWidgetId: Int) {
            val intent = Intent(context, BagWidgetConfigureActivity::class.java).apply {
                action = AppWidgetManager.ACTION_APPWIDGET_CONFIGURE
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            }
            // Use appWidgetId as request code so each instance gets its own PendingIntent.
            val pi = PendingIntent.getActivity(
                context, appWidgetId,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_settings_btn, pi)
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        Log.d(TAG, "onUpdate called for ${appWidgetIds.size} widget(s)")
        for (id in appWidgetIds) {
            updateWidget(context, appWidgetManager, id, widgetData)
        }
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        Log.d(TAG, "onEnabled — first widget instance added")
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        Log.d(TAG, "onDisabled — last widget instance removed, cancelling WorkManager")
        WorkManager.getInstance(context).cancelUniqueWork("bag_widget_refresh")
    }
}
