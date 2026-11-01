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
    // Live tests against a real CalDAV server (LiveCalDAVTest, CrossClientLiveTest) run only with these set, and
    // then every time (the server is not a task input).
    val live = listOf("TODOTIM_LIVE_URL", "TODOTIM_LIVE_USER", "TODOTIM_LIVE_PASSWORD", "TODOTIM_CROSS_STEP", "TODOTIM_CROSS_DIR")
    for (name in live) System.getenv(name)?.let { environment(name, it) }
    if (System.getenv("TODOTIM_LIVE_URL") != null) {
        outputs.upToDateWhen { false }
        outputs.cacheIf { false }
    }
}
