// A deliberately separate Gradle project from pocket/sync/, not a
// multi-module build with it — see pocket/README.md. Sharing one
// settings.gradle.kts would mean this module's broken plugin
// resolution (no Android SDK / dl.google.com blocked here) blocks even
// configuring pocket/sync, which genuinely builds and tests on its
// own. Verified: it does exactly that if the two are merged.
rootProject.name = "nex-pocket-client"

pluginManagement {
    repositories {
        google()
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
