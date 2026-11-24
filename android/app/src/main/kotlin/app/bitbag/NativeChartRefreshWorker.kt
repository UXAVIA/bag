package app.bitbag

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL

/**
 * Native Kotlin WorkManager Worker that fetches BTC chart data from Kraken
 * and updates the home screen widget — no Flutter engine required.
 *
 * Triggered immediately from BagWidgetConfigureActivity when the user
 * changes the widget timeframe, so the chart updates in seconds rather than
 * waiting for the next 15-minute periodic Dart task.
 *
 * Data sources:
 *  - Timeframe: HomeWidgetPreferences → "widget_timeframe_days"
 *  - Currency:  HomeWidgetPreferences → "widget_currency"  (saved by Dart WidgetService.update())
 *
 * Outputs (written back to HomeWidgetPreferences):
 *  - "widget_chart_prices"    JSON array of close prices oldest→newest
 *  - "widget_change"          Formatted timeframe % change string
 *  - "widget_change_positive" Boolean
 *  - "widget_route_ok"        Boolean: whether this direct fetch got through
 *    (Task A5; the widget then shows "Updated" or "Paused since"). Never
 *    "widget_fetched_at": that is the time of the price, which this worker
 *    doesn't fetch.
 *
 * Privacy: it only ever fetches direct. With a private route on it makes
 * no request at all and leaves the chart to the Dart WorkManager task,
 * which fetches through the route (or fails closed): Tor
 * (`flutter.use_tor`) runs inside the Flutter engine, out of a native
 * worker's reach, and a custom proxy's config (`flutter.use_proxy`) is
 * encrypted where only Dart can read it.
 */
class NativeChartRefreshWorker(
    context: Context,
    params: WorkerParameters,
) : Worker(context, params) {

    override fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(
            "HomeWidgetPreferences", Context.MODE_PRIVATE,
        )
        val timeframeDays = prefs.getInt("widget_timeframe_days", 7)
        val currency = prefs.getString("widget_currency", "usd")?.lowercase() ?: "usd"
        val pair = KRAKEN_PAIRS[currency] ?: KRAKEN_PAIRS["usd"]!!
        val isGold = currency == GOLD

        // Flutter stores SharedPreferences keys with a "flutter." prefix.
        val flutterPrefs = applicationContext.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        )

        // ── Custom proxy ──────────────────────────────────────────────────────
        // The proxy config is in flutter_secure_storage, which Kotlin can't
        // decrypt. Skip without touching the network; the Dart WorkManager
        // task refreshes the widget through the proxy (or fails closed).
        if (flutterPrefs.getBoolean("flutter.use_proxy", false)) {
            Log.i(TAG, "Custom proxy on — native refresh skipped; the Dart worker refreshes through the proxy")
            return Result.success()
        }

        // ── Built-in Tor ──────────────────────────────────────────────────────
        // Bag's Tor client runs inside the Flutter engine (TorHost), which a
        // native worker can't reach. Skip without touching the network; the
        // Dart WorkManager task refreshes the chart through Tor.
        if (flutterPrefs.getBoolean("flutter.use_tor", false)) {
            Log.i(TAG, "Built-in Tor on: skipping native chart refresh")
            return Result.success()
        }

        Log.d(TAG, "Native chart refresh: $currency, timeframe=${timeframeDays}d, pair=${if (isGold) "$KRAKEN_GOLD_PAIR (derived)" else pair}")

        return try {
            val prices = (if (isGold) fetchGoldPrices(timeframeDays)
                          else fetchKrakenPrices(pair, timeframeDays))
                ?: return if (applicationContext.privateRouteOn()) Result.success() else failed(prefs)

            if (prices.size < 2) return Result.success() // nothing to render

            val tfChange = (prices.last() - prices.first()) / prices.first() * 100
            val changeStr = "${if (tfChange >= 0) "+" else ""}${"%.1f".format(tfChange)}%"

            val editor = prefs.edit()
                .putString("widget_chart_prices", JSONArray(prices).toString())
                .putString("widget_change", changeStr)
                .putBoolean("widget_change_positive", tfChange >= 0)
            // Only while still direct: the flag describes the route the
            // widget's badge names, and this fetch was direct.
            if (!applicationContext.privateRouteOn()) editor.putBoolean("widget_route_ok", true)
            editor.apply()

            redrawAll()

            Log.d(TAG, "Chart updated: ${prices.size} candles, change=$changeStr")
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Fetch failed: $e")
            if (applicationContext.privateRouteOn()) Result.success() else failed(prefs)
        }
    }

    /**
     * A direct fetch that didn't get through: the widget keeps its chart
     * and shows its time as paused until a fetch gets through (Task A5),
     * and WorkManager retries.
     */
    private fun failed(prefs: SharedPreferences): Result {
        prefs.edit().putBoolean("widget_route_ok", false).apply()
        redrawAll()
        return Result.retry()
    }

    /** Redraws every widget instance from HomeWidgetPreferences. */
    private fun redrawAll() {
        val mgr = AppWidgetManager.getInstance(applicationContext)
        val provider = ComponentName(applicationContext, BagWidget::class.java)
        val updatedPrefs = applicationContext.getSharedPreferences(
            "HomeWidgetPreferences", Context.MODE_PRIVATE,
        )
        for (id in mgr.getAppWidgetIds(provider)) {
            BagWidget.updateWidget(applicationContext, mgr, id, updatedPrefs)
        }
    }

    // ── Kraken OHLC fetch ──────────────────────────────────────────────────────

    /**
     * BTC priced in gold: BTC/USD ÷ PAXG/USD, candle by candle. Both requests
     * use the same interval and `since`, and Kraken aligns every pair to the
     * same candle boundaries, so the series line up from the most recent
     * candle backwards; only the start differs when PAXG's shorter history
     * (from 2019) truncates the ALL timeframe. Hence alignment from the end.
     */
    private fun fetchGoldPrices(timeframeDays: Int): List<Double>? {
        val btcUsd = fetchKrakenPrices(KRAKEN_PAIRS["usd"]!!, timeframeDays) ?: return null
        Thread.sleep(1_100) // Kraken tolerates ~1 public request per second
        val paxgUsd = fetchKrakenPrices(KRAKEN_GOLD_PAIR, timeframeDays) ?: return null
        val n = minOf(btcUsd.size, paxgUsd.size)
        return btcUsd.takeLast(n).zip(paxgUsd.takeLast(n))
            .filter { (_, paxg) -> paxg > 0 }
            .map { (btc, paxg) -> btc / paxg }
    }

    private fun fetchKrakenPrices(pair: String, timeframeDays: Int): List<Double>? {
        val nowSecs = System.currentTimeMillis() / 1000
        val interval: Int
        val since: Long?

        when {
            timeframeDays == 0 -> { interval = 10080; since = null }              // ALL
            timeframeDays <= 1 -> { interval = 60;    since = nowSecs - 90_000 }  // 1D hourly
            timeframeDays <= 7 -> { interval = 60;    since = nowSecs - 691_200 } // 1W hourly
            timeframeDays <= 30 -> { interval = 1440; since = nowSecs - 2_764_800 }  // 1M daily
            timeframeDays <= 365 -> { interval = 1440; since = nowSecs - 31_968_000 } // 1Y daily
            else -> { interval = 10080; since = nowSecs - 157_766_400 }           // 5Y weekly
        }

        val urlStr = buildString {
            append("https://api.kraken.com/0/public/OHLC?pair=$pair&interval=$interval")
            if (since != null) append("&since=$since")
        }

        // A private route switched on since doWork() checked: no request.
        if (applicationContext.privateRouteOn()) {
            Log.i(TAG, "Private route switched on: skipping native chart refresh")
            return null
        }
        // Direct, never through a system proxy: there is no private route.
        val conn = URL(urlStr).openConnection(Proxy.NO_PROXY) as HttpURLConnection
        conn.apply {
            requestMethod = "GET"
            setRequestProperty("Accept", "application/json")
            connectTimeout = TIMEOUT_MS
            readTimeout    = TIMEOUT_MS
        }

        val body = conn.inputStream.bufferedReader().readText()
        val json = JSONObject(body)

        val errors = json.getJSONArray("error")
        if (errors.length() > 0) {
            Log.e(TAG, "Kraken error: $errors")
            return null
        }

        val result = json.getJSONObject("result")
        val key = result.keys().asSequence().firstOrNull { it != "last" } ?: return null
        val ohlc = result.getJSONArray(key)

        return (0 until ohlc.length()).map { i ->
            ohlc.getJSONArray(i).getString(4).toDouble() // index 4 = close price
        }
    }

    companion object {
        private const val TAG = "NativeChartRefresh"
        private const val GOLD = "xau"
        private const val KRAKEN_GOLD_PAIR = "PAXGUSD"
        private const val TIMEOUT_MS = 15_000

        val KRAKEN_PAIRS = mapOf(
            "usd" to "XXBTZUSD",
            "eur" to "XXBTZEUR",
            "gbp" to "XXBTZGBP",
            "cad" to "XXBTZCAD",
            "jpy" to "XXBTZJPY",
            "chf" to "XBTCHF",
            "aud" to "XBTAUD",
        )
    }
}
