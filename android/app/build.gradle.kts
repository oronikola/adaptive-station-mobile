import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

// Real upload-key signing for the release build — see android/key.properties
// (gitignored; never commit it) and android/app/upload-keystore.jks (also
// gitignored). Loaded conditionally so a fresh checkout without that file
// (e.g. CI, or a teammate who hasn't been handed the keystore) still builds
// debug/profile fine; only `assembleRelease`/`bundleRelease` needs it.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.adaptivestation.app"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications.
        isCoreLibraryDesugaringEnabled = true
    }

    // AGP 8+ no longer generates BuildConfig by default — MainActivity's
    // "getFlavor" channel handler reads BuildConfig.FLAVOR, so this must be
    // on explicitly.
    buildFeatures {
        buildConfig = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.adaptivestation.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Falls back to the debug key only when key.properties is
            // genuinely absent (see hasReleaseSigning above) — a real
            // release build always uses the upload key once it exists.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // Two genuinely separate builds from one codebase: `parent` is the one
    // that ever goes to Play Store (no SMS/phone permissions at all — see
    // src/parent/AndroidManifest.xml's tools:node="remove" entries, which
    // strip out what sim_data_new/flutter_foreground_task inject on their
    // own regardless of which Dart entry point is used); `gateway` keeps
    // every permission the SMS-sending fleet phones need and is only ever
    // sideloaded directly onto school-owned devices, never published.
    //
    // Both flavors deliberately share the same applicationId. Giving them
    // separate ids would need a second Firebase Android app registered
    // against google-services.json (Firebase Console access, not something
    // done from here) — and since a gateway phone and a parent phone are
    // always different physical devices anyway, there's no real need for
    // them to be independently installable side by side on one device.
    flavorDimensions += "role"
    productFlavors {
        create("parent") { dimension = "role" }
        create("gateway") { dimension = "role" }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
