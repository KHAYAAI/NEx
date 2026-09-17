// The pocket app shell — written, NOT buildable in this environment.
// The Android Gradle Plugin needs the Android SDK/platform artifacts
// from dl.google.com, which this environment's network policy blocks
// (verified: CONNECT to dl.google.com returns a 403 from the egress
// proxy, same class of restriction as huggingface.co and Docker Hub —
// see hub/models/README.md and hub/dreaming/README.md for the same
// pattern elsewhere in this repo). Unlike pocket/sync/, which is pure
// JVM and genuinely builds and tests here, this module is a reviewable
// draft: real Kotlin/Compose source, real dependency on pocket/sync's
// actual API, but unverified by any compiler in this session. See
// pocket/README.md.
plugins {
    id("com.android.application") version "8.6.0"
    id("org.jetbrains.kotlin.android") version "2.0.21"
}

android {
    namespace = "com.nex.pocket"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.nex.pocket"
        minSdk = 26 // Android 8+, matches /e/OS and LineageOS's realistic floor
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    // Not `implementation(project(":sync"))`: sharing a settings.gradle.kts
    // with pocket/sync/ was tried and reverted — this module's plugin
    // resolution failure (above) blocked even configuring pocket/sync,
    // which genuinely builds and tests standalone. They're deliberately
    // separate Gradle projects; MainActivity.kt/PocketViewModel.kt still
    // import nex.pocket.sync.OfflineQueue by its real package name to
    // keep the intended dependency visible in source, even though no
    // build here can resolve it. A real build would either restore a
    // multi-module setup once the Android SDK is available, or publish
    // pocket/sync as a local Maven artifact.
    //
    // OfflineQueue's persistence (org.xerial:sqlite-jdbc) is also a
    // desktop/JVM JDBC driver with native bindings that do not run on
    // Android — a real Android build needs the same public API backed
    // by androidx.room or android.database.sqlite instead. Tracked in
    // pocket/README.md as unbuilt, not silently assumed to work.
    implementation("androidx.compose.ui:ui:1.7.0")
    implementation("androidx.compose.material3:material3:1.3.0")
    implementation("androidx.activity:activity-compose:1.9.2")
}
