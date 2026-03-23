package com.bagapp.bag

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    private val channel = "com.bagapp.bag/widget"

    override fun onCreate(savedInstanceState: Bundle?) {
        // Dismiss the Android 12+ system splash screen on the very next frame
        // so it is never visible — our Flutter SplashScreen handles the intro animation.
        installSplashScreen().setKeepOnScreenCondition { false }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkVersion" -> result.success(Build.VERSION.SDK_INT)

                    "requestPinWidget" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val manager = AppWidgetManager.getInstance(this)
                            if (manager.isRequestPinAppWidgetSupported) {
                                val provider = ComponentName(this, BagWidget::class.java)
                                manager.requestPinAppWidget(provider, null, null)
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        } else {
                            result.success(false)
                        }
                    }

                    // Adds or removes FLAG_SECURE to prevent the zpub reveal dialog
                    // from appearing in screenshots, screen recorders, and the
                    // recent-apps thumbnail.
                    "setSecureMode" -> {
                        val secure = call.argument<Boolean>("secure") ?: false
                        if (secure) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
