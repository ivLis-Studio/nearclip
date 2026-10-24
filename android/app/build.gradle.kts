plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "studio.ivlis.nearclip"
    compileSdk = 36

    defaultConfig {
        applicationId = "studio.ivlis.nearclip"
        minSdk = 26
        targetSdk = 36
        versionCode = 3
        versionName = "1.0.2"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    androidResources {
        generateLocaleConfig = true
    }

    // Licenses of the embedded Tailscale node (tailnet/build.sh notices) for Settings › Open-source licenses.
    sourceSets.getByName("main").assets.srcDir(rootProject.file("../tailnet/notices"))

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
        // The embedded Tailscale node (tailnet/build.sh android) is ~21 MB per ABI; compressing it in the APK
        // keeps the download small (the installer extracts only the device's ABI).
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

// The native library is built outside Gradle (Go + NDK): fail early with a clear message when it is missing.
val tailnetLib = rootProject.file("app/src/main/jniLibs/arm64-v8a/libnctailnet.so")
tasks.named("preBuild") {
    doFirst {
        check(tailnetLib.exists()) { "Missing ${tailnetLib.path} — run tailnet/build.sh android first." }
    }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.kotlinx.coroutines.android)

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.lifecycle.service)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.foundation)
    implementation(libs.compose.animation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.zxing.core)

    // Opt-in instant capture (runtime/InstantCapture.kt): clipboard reads as the shell user through Shizuku.
    implementation(libs.shizuku.api)
    implementation(libs.shizuku.provider)
    implementation(libs.hiddenapibypass)

    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
}
