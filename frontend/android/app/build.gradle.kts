import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material, read from an untracked `android/key.properties` or
// from the environment. Never from a file in this repository.
//
// Absent material must fail the build rather than fall back to the debug keys.
// A release APK signed with the debug key installs on a student's phone and then
// can never be updated: the store rejects every later build because the signing
// identity changed. That failure appears long after the mistake, on a device we
// do not control, so it is worth failing here instead.
//
// `key.properties` has to be loaded explicitly. Gradle reads `gradle.properties`
// on its own and nothing else, so without this block the file named in the error
// message below would be silently ignored and the documented way of configuring
// a release build would not work.
val keyProperties = Properties().apply {
    val keyPropertiesFile = rootProject.file("key.properties")
    if (keyPropertiesFile.exists()) {
        keyPropertiesFile.inputStream().use { load(it) }
    }
}

// A Gradle property wins over the environment, which wins over the file, so a
// one-off CI invocation can override the developer's local file without editing
// it.
fun signingValue(name: String): String? =
    (project.findProperty(name) as String?)
        ?: System.getenv(name)
        ?: keyProperties.getProperty(name)

val releaseStorePath: String? = signingValue("PEERPASS_KEYSTORE")
val releaseStorePassword: String? = signingValue("PEERPASS_KEYSTORE_PASSWORD")
val releaseKeyAlias: String? = signingValue("PEERPASS_KEY_ALIAS")
val releaseKeyPassword: String? = signingValue("PEERPASS_KEY_PASSWORD")

val hasReleaseSigningMaterial = listOf(
    releaseStorePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

// Only demanded when a release variant is actually being assembled, so that
// `./gradlew tasks`, `flutter analyze` and the debug build keep working on a
// machine that has no keystore, which is every developer machine and CI.
if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) } &&
    !hasReleaseSigningMaterial
) {
    throw GradleException(
        """
        |Release signing is not configured, so this release build cannot proceed.
        |
        |It will NOT fall back to the debug keys: an APK signed with the debug key
        |installs but can never be updated from the store afterwards.
        |
        |Set all four of these, as environment variables or as Gradle properties:
        |  PEERPASS_KEYSTORE          path to the .jks or .keystore file
        |  PEERPASS_KEYSTORE_PASSWORD password for the keystore
        |  PEERPASS_KEY_ALIAS         key alias within it
        |  PEERPASS_KEY_PASSWORD      password for that key
        |
        |Or write them to android/key.properties, which is git-ignored:
        |  PEERPASS_KEYSTORE=/absolute/path/to/peerpass-release.jks
        |  PEERPASS_KEYSTORE_PASSWORD=...
        |  PEERPASS_KEY_ALIAS=...
        |  PEERPASS_KEY_PASSWORD=...
        |
        |Never commit a keystore or its passwords.
        """.trimMargin(),
    )
}

android {
    namespace = "com.peerpass.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.peerpass.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (hasReleaseSigningMaterial) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseStorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Assigned only when real material exists. Combined with the check
            // above, a release build either uses the real key or fails.
            signingConfig = if (hasReleaseSigningMaterial) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}
kotlin {
  compilerOptions {
    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
  }
}


flutter {
    source = "../.."
}
