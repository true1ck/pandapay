allprojects {
    repositories {
        // Pre-seeded local copy of artifacts that keep failing to download
        // over this network (TLS "bad_record_mac" flakiness) — checked
        // first so a cached hit skips the flaky remote fetch entirely.
        maven { url = uri(System.getProperty("user.home") + "/local-maven-repo") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Older plugins (e.g. telephony 0.2.0) predate AGP's mandatory `namespace`
// requirement and don't declare one in their build.gradle. Backfill it from
// the plugin's AndroidManifest.xml package attribute so AGP 9.x can build them.
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension> {
            if (namespace == null) {
                val manifestFile = file("src/main/AndroidManifest.xml")
                if (manifestFile.exists()) {
                    val manifestText = manifestFile.readText()
                    val packageMatch = Regex("package=\"([^\"]+)\"").find(manifestText)
                    packageMatch?.groupValues?.get(1)?.let { pkg ->
                        namespace = pkg
                    }
                }
            }
        }
    }
}

// Several old plugins (telephony, home_widget) hardcode their own mismatched
// Java/Kotlin JVM targets, which Kotlin's compiler rejects as inconsistent.
// Force both to the app's JVM target (17) app-wide, after each subproject's
// own build script has had a chance to set (and be overridden on) its own
// compileOptions/kotlinOptions.
val jvmTargetMismatchedPlugins = setOf("telephony", "home_widget")
gradle.projectsEvaluated {
    subprojects.filter { it.name in jvmTargetMismatchedPlugins }.forEach { sub ->
        // telephony 0.2.0 hardcodes compileSdkVersion 31 in its own build
        // script. Override it only after every project has been evaluated;
        // doing this in plugins.withId runs too early and telephony silently
        // assigns 31 again afterwards. Its AndroidX dependencies require 34+.
        if (sub.name == "telephony") {
            sub.extensions.configure<com.android.build.gradle.LibraryExtension> {
                compileSdk = 37
            }
        }

        sub.tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
        sub.tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
