pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        maven { url = uri("https://maven.google.com") }
        maven { url = uri("https://repo1.maven.org/maven2") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// Some Flutter plugins still declare their Android Gradle and Kotlin plugins
// in a project-level buildscript block. Put the verified local Maven cache
// first for those legacy buildscript dependencies too; the project-level
// `allprojects.repositories` block cannot affect buildscript resolution.
gradle.beforeProject {
    buildscript.repositories {
        maven { url = uri(System.getProperty("user.home") + "/local-maven-repo") }
        maven { url = uri("https://maven.google.com") }
        maven { url = uri("https://repo1.maven.org/maven2") }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.12.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("com.google.gms.google-services") version "4.4.4" apply false
}

include(":app")
