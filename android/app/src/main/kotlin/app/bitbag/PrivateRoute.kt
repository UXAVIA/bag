package app.bitbag

import android.content.Context

/**
 * Tor or a custom proxy is on, as the app last saved it (`flutter.use_tor`,
 * `flutter.use_proxy` in FlutterSharedPreferences). Native code fetches only
 * direct, so it makes no request while this is true. Read fresh on every
 * call: the route can change between two of them.
 */
internal fun Context.privateRouteOn(): Boolean {
    val flutterPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    return flutterPrefs.getBoolean("flutter.use_tor", false) ||
        flutterPrefs.getBoolean("flutter.use_proxy", false)
}
