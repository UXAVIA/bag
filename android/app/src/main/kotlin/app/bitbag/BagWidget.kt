package app.bitbag

import android.app.AlarmManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.text.format.DateUtils
import android.util.Log
import android.util.SizeF
import android.widget.RemoteViews
import android.app.PendingIntent
import android.content.Intent
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

class BagWidget : HomeWidgetProvider() {

    companion object {
        private const val TAG = "BagWidget"

        // Pre-API31 size thresholds (dp) for layout selection.
        // On API 31+ the launcher picks the right RemoteViews automatically.
        private const val MEDIUM_MIN_HEIGHT_DP = 110
        private const val LARGE_MIN_HEIGHT_DP = 210

        // Medium widgets at least this wide (dp) say "Paused since HH:mm";
        // narrower ones (2×2), like the small strip, say "Paused HH:mm".
        private const val LONG_TIME_MIN_WIDTH_DP = 180

        // Route badge and freshness text (Task A5), as drawn. The dots and
        // the badge tones are drawables (widget_route_*).
        private val TEXT_WHITE = 0xFFFFFFFF.toInt()
        private val TEXT_MUTED = 0xFFA9A9C4.toInt()
        private val TEXT_PAUSED = 0xFFFF6B78.toInt()

        // The midnight redraw's PendingIntent request code: one fixed code, so
        // each alarm set replaces the last.
        private const val MIDNIGHT_REDRAW_REQUEST = 7301

        /** The route the widget's prices come through, as its badge names it. */
        private enum class WidgetRoute(val label: String) {
            TOR("Tor"),
            PROXY("Proxy"),
            DIRECT("Direct"),
        }

        fun updateWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int,
            widgetData: SharedPreferences,
        ) {
            try {
                val small = buildSmall(context, widgetData, appWidgetId)
                val narrowMedium = buildMedium(context, widgetData, appWidgetId, short = true)
                val medium = buildMedium(context, widgetData, appWidgetId, short = false)
                val large = buildLarge(context, widgetData, appWidgetId)

                val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // Android 12+: launcher picks the largest layout that fits
                    // within the current widget dimensions.
                    // small  = 2×1 flat net worth row
                    // medium = 2×2 / 3×2 price + net worth (the narrow one
                    //          with the short "Paused HH:mm")
                    // large  = 4×3+ price + net worth + chart
                    RemoteViews(
                        mapOf(
                            SizeF(80f, 40f) to small,
                            SizeF(80f, 110f) to narrowMedium,
                            SizeF(LONG_TIME_MIN_WIDTH_DP.toFloat(), 110f) to medium,
                            SizeF(200f, 210f) to large,
                        )
                    )
                } else {
                    val opts = appWidgetManager.getAppWidgetOptions(appWidgetId)
                    val h = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
                    val w = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
                    when {
                        h >= LARGE_MIN_HEIGHT_DP -> large
                        h >= MEDIUM_MIN_HEIGHT_DP ->
                            if (w >= LONG_TIME_MIN_WIDTH_DP) medium else narrowMedium
                        else -> small
                    }
                }

                appWidgetManager.updateAppWidget(appWidgetId, views)
                Log.d(TAG, "Widget $appWidgetId updated")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to update widget $appWidgetId", e)
            }
            scheduleMidnightRedraw(context)
        }

        // ── The day rule at midnight (Task A5) ──────────────────────────────

        /**
         * Redraws every widget at the next local midnight, from what is saved,
         * so a fetch from before it shows its date ("Updated 21 Nov") even
         * when nothing fetches (offline, or the job deferred): the widget has
         * no update period of its own (`updatePeriodMillis="0"`), and the Dart
         * job needs a network. The broadcast is the update `HomeWidget`
         * itself sends, so it lands in [onUpdate], which only renders
         * HomeWidgetPreferences: no request.
         *
         * Non-wakeup, in a 15-minute window from midnight (`setWindow`,
         * `RTC`, API 19): no exact-alarm permission, and a sleeping device
         * redraws when it next wakes. A plain inexact `set()` may slip by up
         * to 75 % of the time left to its trigger, and older Android doesn't
         * cap that. An alarm, not a WorkManager job: in a rare standby bucket
         * a job can wait up to a day. Set after every render; the fixed
         * request code makes each one replace the last.
         */
        private fun scheduleMidnightRedraw(context: Context) {
            try {
                val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
                alarms.setWindow(
                    AlarmManager.RTC,
                    nextLocalMidnightMillis(System.currentTimeMillis()),
                    15 * 60_000L,
                    midnightRedrawIntent(context),
                )
            } catch (e: Exception) {
                Log.w(TAG, "Could not schedule the midnight redraw: $e")
            }
        }

        /** The update broadcast for every Bag widget, as one PendingIntent. */
        private fun midnightRedrawIntent(context: Context): PendingIntent {
            val ids = AppWidgetManager.getInstance(context)
                .getAppWidgetIds(ComponentName(context, BagWidget::class.java))
            val intent = Intent(context, BagWidget::class.java).apply {
                action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            }
            return PendingIntent.getBroadcast(
                context, MIDNIGHT_REDRAW_REQUEST, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        /** The next local midnight after [now] (epoch millis), in the device's zone. */
        private fun nextLocalMidnightMillis(now: Long): Long {
            val midnight = Calendar.getInstance()
            midnight.timeInMillis = now
            midnight.add(Calendar.DAY_OF_YEAR, 1)
            midnight.set(Calendar.HOUR_OF_DAY, 0)
            midnight.set(Calendar.MINUTE, 0)
            midnight.set(Calendar.SECOND, 0)
            midnight.set(Calendar.MILLISECOND, 0)
            return midnight.timeInMillis
        }

        // ── Small: net worth only ──────────────────────────────────────────
        private fun buildSmall(context: Context, data: SharedPreferences, appWidgetId: Int): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.bag_widget_small)
            views.setTextViewText(R.id.widget_net_worth, data.getString("widget_net_worth", null) ?: "—")
            applyRouteAndTime(views, data, short = true)
            applyLaunchTap(context, views)
            applySettingsTap(context, views, appWidgetId)
            return views
        }

        // ── Medium: price + % + net worth ──────────────────────────────────
        private fun buildMedium(context: Context, data: SharedPreferences, appWidgetId: Int, short: Boolean): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.bag_widget)
            applyPriceData(views, data)
            applyRouteAndTime(views, data, short)
            applyPnlData(views, data)
            applyFeeData(views, data)
            applyLaunchTap(context, views)
            applySettingsTap(context, views, appWidgetId)
            return views
        }

        // ── Large: full-bleed native sparkline background + text overlay ────
        private fun buildLarge(context: Context, data: SharedPreferences, appWidgetId: Int): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.bag_widget_large)
            applyPriceData(views, data)
            applyRouteAndTime(views, data, short = false)
            applyPnlData(views, data)
            applyFeeData(views, data)
            applyLaunchTap(context, views)
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

        private fun applyPriceData(views: RemoteViews, data: SharedPreferences) {
            val price = data.getString("widget_price", null)
            val netWorth = data.getString("widget_net_worth", null)
            val change = data.getString("widget_change", null)
            val changePositive = data.getBoolean("widget_change_positive", true)

            views.setTextViewText(R.id.widget_price, price ?: "—")
            views.setTextViewText(R.id.widget_net_worth, netWorth ?: "—")

            if (!change.isNullOrEmpty()) {
                views.setTextViewText(R.id.widget_change, change)
                val color = if (changePositive) 0xFF00C896.toInt() else 0xFFFF4757.toInt()
                views.setTextColor(R.id.widget_change, color)
            } else {
                views.setTextViewText(R.id.widget_change, "")
            }
        }

        // ── Route badge and freshness (Task A5) ────────────────────────────

        /**
         * The badge (Tor, Proxy or Direct) and the time the prices were
         * fetched. The keys come from lib/services/widget_service.dart:
         * the route flags (`writeWidgetRouteFlags`), `widget_route_ok` (the
         * last fetch got its price through the route) and
         * `widget_fetched_at` (epoch seconds). Every read is type-safe: a
         * typed getter on a key stored as another type throws and the
         * widget doesn't render.
         *
         * Tor and Proxy have a dot, green while the route delivers and red
         * when paused; Direct has none, and only its time turns red.
         * [short] picks "Paused HH:mm" over "Paused since HH:mm".
         */
        private fun applyRouteAndTime(views: RemoteViews, data: SharedPreferences, short: Boolean) {
            val all = data.all
            val ok = all["widget_route_ok"] as? Boolean ?: true
            val route = widgetRoute(all)
            if (route == null) {
                views.setViewVisibility(R.id.widget_route_badge, android.view.View.GONE)
            } else {
                val direct = route == WidgetRoute.DIRECT
                views.setTextViewText(R.id.widget_route_label, route.label)
                views.setTextColor(R.id.widget_route_label, if (direct) TEXT_MUTED else TEXT_WHITE)
                views.setInt(
                    R.id.widget_route_badge, "setBackgroundResource",
                    when {
                        direct -> R.drawable.widget_route_badge_direct
                        ok -> R.drawable.widget_route_badge_ok
                        else -> R.drawable.widget_route_badge_failed
                    },
                )
                if (direct) {
                    views.setViewVisibility(R.id.widget_route_dot, android.view.View.GONE)
                } else {
                    views.setImageViewResource(
                        R.id.widget_route_dot,
                        if (ok) R.drawable.widget_route_dot_ok else R.drawable.widget_route_dot_failed,
                    )
                    views.setViewVisibility(R.id.widget_route_dot, android.view.View.VISIBLE)
                }
                views.setViewVisibility(R.id.widget_route_badge, android.view.View.VISIBLE)
            }

            val time = freshnessText(all, ok, short)
            views.setTextViewText(R.id.widget_updated, time ?: "")
            views.setTextColor(R.id.widget_updated, if (ok) TEXT_MUTED else TEXT_PAUSED)
            views.setViewVisibility(
                R.id.widget_updated,
                if (time == null) android.view.View.GONE else android.view.View.VISIBLE,
            )
        }

        /**
         * Tor first, then Proxy, as Dart's `NetworkSettings.route` decides
         * (both flags are set for a moment while the app switches between
         * them). Null while the app hasn't written the flags yet (an
         * upgrade before its first widget update): no badge rather than a
         * "Direct" that may not be true.
         */
        private fun widgetRoute(all: Map<String, *>): WidgetRoute? {
            val tor = all["widget_use_tor"] as? Boolean
            val proxy = all["widget_use_proxy"] as? Boolean
            return when {
                tor == true -> WidgetRoute.TOR
                proxy == true -> WidgetRoute.PROXY
                tor == null && proxy == null -> null
                else -> WidgetRoute.DIRECT
            }
        }

        /**
         * "Updated 14:32", or "Paused since 14:32" ("Paused 14:32" when
         * [short]) when the last fetch didn't get through. A fetch from
         * another day shows its date ("21 Nov"): a bare time from days ago
         * would read as fresh. Null before the first fetch (badge only).
         */
        private fun freshnessText(all: Map<String, *>, ok: Boolean, short: Boolean): String? {
            val seconds = (all["widget_fetched_at"] as? Number)?.toLong() ?: return null
            val millis = seconds * 1000
            val pattern = if (DateUtils.isToday(millis)) "HH:mm" else "d MMM"
            val stamp = SimpleDateFormat(pattern, Locale.US).format(Date(millis))
            return when {
                ok -> "Updated $stamp"
                short -> "Paused $stamp"
                else -> "Paused since $stamp"
            }
        }

        /**
         * Makes the entire widget surface open the app.
         *
         * The intent is attached to the root container rather than to
         * individual text views, so any tap that isn't consumed by a more
         * specific child launches Bag. Android dispatches touches to the
         * deepest clickable view first, so the settings gear — which sets its
         * own PendingIntent in [applySettingsTap] — still wins within its own
         * bounds.
         */
        private fun applyLaunchTap(context: Context, views: RemoteViews) {
            val intent = Intent(context, MainActivity::class.java).apply {
                // Bring the existing task forward rather than stacking a new
                // activity on top of whatever the user last had open.
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val pi = PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, pi)
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
        Log.d(TAG, "onEnabled — first widget instance added, scheduling immediate chart refresh")
        // Fetch chart data immediately so the sparkline appears without waiting
        // for the next 15-minute Dart background task or the user opening the app.
        val work = OneTimeWorkRequestBuilder<NativeChartRefreshWorker>().build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            "bag_chart_refresh_on_add",
            ExistingWorkPolicy.REPLACE,
            work,
        )
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        Log.d(TAG, "onDisabled — last widget instance removed, cancelling WorkManager")
        WorkManager.getInstance(context).cancelUniqueWork("bag_widget_refresh")
        (context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager)?.cancel(midnightRedrawIntent(context))
    }
}
