// Pure Kotlin/JVM: models, iCalendar, CalDAV, sync, parsing. No Android APIs, so all tests run on the host JVM.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin { jvmToolchain(21) }

dependencies {
    api(libs.coroutines.core)
    api(libs.serialization.json)
    api(libs.okhttp)
    // Android ships XmlPullParser; on the JVM kxml2 provides it.
    compileOnly(libs.kxml2)
    testImplementation(libs.kxml2)
    testImplementation(libs.junit)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.coroutines.test)
}

// Shared golden fixtures (also read by the Swift tests).
tasks.test {
    systemProperty("todotim.fixtures", rootProject.projectDir.resolve("../fixtures").canonicalPath)
    inputs.dir(rootProject.projectDir.resolve("../fixtures"))
}
