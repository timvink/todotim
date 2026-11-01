import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "app.todotim.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "app.todotim.android"
        minSdk = 29
        targetSdk = 36
        // Releases pass the tag's version (-PtodotimVersion=X.Y.Z); local builds are 0.0.1.
        val version = (findProperty("todotimVersion") as String?) ?: "0.0.1"
        val (major, minor, patch) = version.split(".").map { it.toInt() }
        versionCode = major * 10000 + minor * 100 + patch
        versionName = version
    }

    // Release signing from android/keystore.properties (gitignored: storeFile, storePassword, keyAlias,
    // keyPassword; storeFile relative to android/). Without it, release builds are signed with the debug key.
    val keystoreProperties = rootProject.file("keystore.properties").takeIf { it.isFile }?.let { file ->
        Properties().apply { file.inputStream().use(::load) }
    }
    signingConfigs {
        if (keystoreProperties != null) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        // Installs next to the release app (own data, own sync account), labelled "TodoTim debug"
        // (src/debug/res/values/strings.xml).
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
    buildFeatures { compose = true }
}

kotlin { jvmToolchain(21) }

dependencies {
    implementation(project(":core"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material.icons)
    implementation(libs.activity.compose)
    implementation(libs.work.runtime)
    debugImplementation(libs.compose.ui.tooling)
    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
}
