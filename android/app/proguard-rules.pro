# Flutter engine — keep all Flutter plugin classes.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# flutter_foreground_task — service and task handler classes resolved by name.
-keep class com.pravera.flutter_foreground_task.** { *; }

# home_widget — background callback receiver resolved by name.
-keep class es.antonborri.home_widget.** { *; }

# WorkManager — worker classes registered by name in WorkerFactory.
-keep class androidx.work.** { *; }
-keep class com.bagapp.bag.NativeChartRefreshWorker { *; }

# Flutter Play Core deferred components — not used in F-Droid/sideload builds,
# but Flutter's engine references these classes. Suppress R8 missing-class errors.
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Strip verbose debug logs from release APK.
# Log.d and Log.v carry no runtime side-effects; removing them is safe.
-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
}
