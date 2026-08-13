import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing reads from android/key.properties, which is gitignored and
// created locally by whoever cuts the release — see android/key.properties.example.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "app.pandapay.pandapay"
    // flutter_secure_storage requires compiling against API 37+.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications requires core library desugaring.
        isCoreLibraryDesugaringEnabled = true
    }

    // resValue() in productFlavors below needs this explicitly on — recent
    // AGP defaults it off to keep the resource table lean when unused.
    buildFeatures {
        resValues = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.pandapay.pandapay"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Pinned to 24 (Android 7.0), not flutter.minSdkVersion's default —
        // S2's QuickSettingsTileService (BestCardTileService.kt) needs API
        // 24+ to exist at all, and UA-0.1.1's original plan already called
        // for min SDK 24 regardless. ~99%+ of active Android devices are
        // already past this floor.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Plan Phase 0.3's remaining gap: env.dart already differentiates
    // dev/staging/prod at the Dart level via --dart-define, but nothing at
    // the Android build level let dev/staging/prod builds coexist on one
    // device or be identified in the launcher. applicationIdSuffix (not a
    // separate signing config) is enough for that — release signing stays
    // the single config above; --flavor only changes the app id and label.
    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "PandaPay Dev")
        }
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            resValue("string", "app_name", "PandaPay Staging")
        }
        create("prod") {
            dimension = "environment"
            // No suffix — this is the applicationId Play Console releases
            // ship under, must stay app.pandapay.pandapay.
            resValue("string", "app_name", "PandaPay")
        }
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // R8 minification was silently on by default (Flutter's Gradle
            // plugin default for release, with no proguard-rules.pro in this
            // project to add keep exceptions) and was stripping something
            // androidx.work's Room-generated WorkDatabase needs at runtime —
            // found by actually installing a release build, which crashed
            // immediately on launch with "Failed to create an instance of
            // androidx.work.impl.WorkDatabase", while the identical debug
            // build (no minification) ran fine. Disabling minification is
            // the safe fix over hand-tuning keep rules blind; costs APK
            // size, not correctness, and can be revisited with a real
            // proguard-rules.pro later if size becomes a concern.
            isMinifyEnabled = false
            isShrinkResources = false

            // Falls back to the debug key when key.properties isn't present
            // (e.g. `flutter run --release` on a machine without the release
            // keystore) so local release-mode runs still work. Play Console
            // uploads must come from a build made where key.properties exists.
            signingConfig = if (hasKeystoreProperties) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
