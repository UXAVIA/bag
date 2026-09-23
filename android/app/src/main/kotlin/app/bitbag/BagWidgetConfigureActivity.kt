package app.bitbag

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.Log
import android.widget.TextView
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager

class BagWidgetConfigureActivity : Activity() {

    companion object {
        private const val TAG = "WidgetConfigure"
    }

    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    private val timeframes = listOf(
        Triple(R.id.btn_1d,  1,    "1D"),
        Triple(R.id.btn_1w,  7,    "1W"),
        Triple(R.id.btn_1m,  30,   "1M"),
        Triple(R.id.btn_1y,  365,  "1Y"),
        Triple(R.id.btn_5y,  1825, "5Y"),
        Triple(R.id.btn_all, 0,    "ALL"),
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)

        appWidgetId = intent.extras
            ?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID

        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        setContentView(R.layout.activity_bag_widget_configure)

        val prefs = getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val currentDays = prefs.getInt("widget_timeframe_days", 7)

        timeframes.forEach { (viewId, days, _) ->
            val btn = findViewById<TextView>(viewId)
            updateButtonStyle(btn, days == currentDays)
            btn.setOnClickListener { saveAndFinish(days) }
        }
    }

    private fun saveAndFinish(days: Int) {
        val prefs = getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)

        // Save new timeframe to HomeWidgetPreferences (read by Kotlin).
        // Also bridge to Flutter's SharedPreferences so the periodic Dart
        // background task reads the correct timeframe too.
        prefs.edit()
            .putInt("widget_timeframe_days", days)
            .remove("widget_change")
            .remove("widget_change_positive")
            .remove("widget_chart_prices")
            .remove("widget_chart") // legacy key
            .apply()

        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .putInt("flutter.widget_timeframe_days", days)
            .apply()

        // Trigger a native Kotlin one-shot Worker that fetches Kraken chart data
        // immediately — no Flutter engine needed, updates in seconds.
        triggerImmediateRefresh()

        // Redraw widget with cleared chart (shows plain background while refresh runs).
        val mgr = AppWidgetManager.getInstance(this)
        BagWidget.updateWidget(this, mgr, appWidgetId,
            getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE))

        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
        finishAndRemoveTask()
    }

    /** Enqueues a one-shot NativeChartRefreshWorker to fetch Kraken chart data
     *  for the newly selected timeframe immediately. Pure Kotlin — no Flutter. */
    private fun triggerImmediateRefresh() {
        try {
            val request = OneTimeWorkRequest.Builder(NativeChartRefreshWorker::class.java)
                .build()
            WorkManager.getInstance(this).enqueue(request)
            Log.d(TAG, "Enqueued NativeChartRefreshWorker for timeframe change")
        } catch (e: Exception) {
            Log.w(TAG, "Could not enqueue native refresh: $e")
        }
    }

    private fun updateButtonStyle(btn: TextView, selected: Boolean) {
        val bg = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = 8f
            if (selected) {
                setColor(0x26F7931A.toInt())
                setStroke(2, 0x80F7931A.toInt())
            } else {
                setColor(0xFF1C1C27.toInt())
                setStroke(1, 0xFF252535.toInt())
            }
        }
        btn.background = bg
        btn.setTextColor(if (selected) Color.parseColor("#F7931A") else Color.parseColor("#8888AA"))
    }
}
