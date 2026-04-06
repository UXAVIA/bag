import com.android.build.gradle.internal.api.ApkVariantOutputImpl

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.bitbag"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "app.bitbag"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing: read credentials from environment variables so no
    // secrets are committed to the repository.
    //
    // Required env vars for release builds:
    //   BAG_KEYSTORE_PATH   — absolute path to the .jks / .keystore file
    //   BAG_KEYSTORE_PASS   — keystore password
    //   BAG_KEY_ALIAS       — key alias inside the keystore
    //   BAG_KEY_PASS        — key password
    //
    // To generate a new keystore (one-time):
    //   keytool -genkey -v -keystore bag-release.jks -keyalg RSA \
    //     -keysize 2048 -validity 10000 -alias bag
    //
    // Local dev without env vars falls back to the debug keystore so
    // `flutter run --release` still works on a dev machine.
    val envKeystorePath = System.getenv("BAG_KEYSTORE_PATH")
    val envKeystorePass = System.getenv("BAG_KEYSTORE_PASS")
    val envKeyAlias     = System.getenv("BAG_KEY_ALIAS")
    val envKeyPass      = System.getenv("BAG_KEY_PASS")
    val hasReleaseKey   = envKeystorePath != null && envKeystorePass != null &&
                          envKeyAlias != null && envKeyPass != null

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile     = file(envKeystorePath!!)
                storePassword = envKeystorePass
                keyAlias      = envKeyAlias
                keyPassword   = envKeyPass
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (hasReleaseKey)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

// Per-ABI version codes for F-Droid split APK builds.
// Only activates when built with --split-per-abi; universal APK/AAB builds are unaffected.
val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abiVersionCode = abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride = variant.versionCode * 10 + abiVersionCode
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("androidx.core:core-splashscreen:1.0.1")
}
