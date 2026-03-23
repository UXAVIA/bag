package com.bagapp.bag

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
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
 *
 * Privacy: when the user has Tor enabled, all network traffic is routed
 * through the local Orbot SOCKS5 proxy (127.0.0.1:9050). If Orbot is
 * unreachable the worker retries rather than falling back to clearnet.
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

        // ── Tor pre-flight ────────────────────────────────────────────────────
        // Flutter stores SharedPreferences keys with a "flutter." prefix.
        val flutterPrefs = applicationContext.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        )
        val useTor = flutterPrefs.getBoolean("flutter.use_tor", false)
        if (useTor) {
            if (!isOrbotReachable()) {
                Log.w(TAG, "Tor enabled but Orbot unreachable — retrying later")
                return Result.retry()
            }
            Log.d(TAG, "Tor enabled and Orbot reachable — routing through SOCKS5")
        }

        Log.d(TAG, "Native chart refresh: $currency, timeframe=${timeframeDays}d, pair=$pair")

        return try {
            val prices = fetchKrakenPrices(pair, timeframeDays, useTor)
                ?: return Result.retry()

            if (prices.size < 2) return Result.success() // nothing to render

            val tfChange = (prices.last() - prices.first()) / prices.first() * 100
            val changeStr = "${if (tfChange >= 0) "+" else ""}${"%.1f".format(tfChange)}%"

            prefs.edit()
                .putString("widget_chart_prices", JSONArray(prices).toString())
                .putString("widget_change", changeStr)
                .putBoolean("widget_change_positive", tfChange >= 0)
                .apply()

            // Redraw all widget instances with the fresh data.
            val mgr = AppWidgetManager.getInstance(applicationContext)
            val provider = ComponentName(applicationContext, BagWidget::class.java)
            val updatedPrefs = applicationContext.getSharedPreferences(
                "HomeWidgetPreferences", Context.MODE_PRIVATE,
            )
            for (id in mgr.getAppWidgetIds(provider)) {
                BagWidget.updateWidget(applicationContext, mgr, id, updatedPrefs)
            }

            Log.d(TAG, "Chart updated: ${prices.size} candles, change=$changeStr")
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Fetch failed: $e")
            Result.retry()
        }
    }

    // ── Tor probe ──────────────────────────────────────────────────────────────

    /** TCP-probes the local Orbot SOCKS5 port. Returns true if reachable. */
    private fun isOrbotReachable(): Boolean = try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", 9050), 5_000)
        }
        true
    } catch (_: Exception) {
        false
    }

    // ── Kraken OHLC fetch ──────────────────────────────────────────────────────

    private fun fetchKrakenPrices(pair: String, timeframeDays: Int, useTor: Boolean): List<Double>? {
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

        // Route through Orbot SOCKS5 when Tor is enabled.
        // java.net.Proxy tunnels the TCP connection; TLS handshake is end-to-end.
        val proxy = if (useTor)
            Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", 9050))
        else
            Proxy.NO_PROXY
        val timeout = if (useTor) 60_000 else 15_000

        val conn = URL(urlStr).openConnection(proxy) as HttpURLConnection
        conn.apply {
            requestMethod = "GET"
            setRequestProperty("Accept", "application/json")
            connectTimeout = timeout
            readTimeout    = timeout
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
