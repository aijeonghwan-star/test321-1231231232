plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.livesubs"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.example.livesubs"
        minSdk = 29          // 다른 앱의 재생 소리 캡처(AudioPlaybackCapture)는 Android 10+
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release { isMinifyEnabled = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-ktx:1.9.3")

    // 온디바이스 영어 음성 인식 (실시간 스트리밍)
    implementation("net.java.dev.jna:jna:5.13.0@aar")
    implementation("com.alphacephei:vosk-android:0.3.47")

    // 온디바이스 영어 -> 한국어 번역
    implementation("com.google.mlkit:translate:17.0.3")
}
