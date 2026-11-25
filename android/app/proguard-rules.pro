# Flutter engine — keep all Flutter classes except the Play Store deferred
# component manager, which references com.google.android.play.core.* classes
# that F-Droid's scanner rejects as proprietary.  We don't use deferred
# components, so letting R8 strip it removes the Play Core type references.
-keep class !io.flutter.embedding.engine.deferredcomponents.**, !io.flutter.embedding.android.FlutterPlayStoreSplitApplication, io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# flutter_foreground_task — service and task handler classes resolved by name.
-keep class com.pravera.flutter_foreground_task.** { *; }

# home_widget — background callback receiver resolved by name.
-keep class es.antonborri.home_widget.** { *; }

# WorkManager — worker classes registered by name in WorkerFactory.
-keep class androidx.work.** { *; }
-keep class app.bitbag.NativeChartRefreshWorker { *; }

# Flutter engine references Play Core for deferred components support.
# These classes are not shipped in the APK — the -dontwarn rules let R8 ignore
# the unresolved references in io.flutter.embedding.engine.deferredcomponents.
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Strip verbose debug logs from release APK.
# Log.d and Log.v carry no runtime side-effects; removing them is safe.
-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
}
