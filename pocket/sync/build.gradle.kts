// Pure-JVM Kotlin module — deliberately no Android Gradle Plugin
// dependency, so it builds and tests with plain `gradle`, no Android
// SDK required (this environment has no Android SDK and dl.google.com
// is blocked by its network policy — see pocket/README.md). The real
// Android app (pocket/client/) depends on this module's public API;
// this is where the actual store-and-forward logic lives and is
// verified for real.
plugins {
    kotlin("jvm") version "2.0.21"
    application
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.xerial:sqlite-jdbc:3.46.1.3")
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.0")
}

kotlin {
    jvmToolchain(21)
}

application {
    mainClass.set("nex.pocket.sync.CliKt")
}

tasks.test {
    useJUnitPlatform()
}
