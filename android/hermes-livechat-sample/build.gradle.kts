plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.mobene.hermes.livechat.sample"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.mobene.hermes.livechat.sample"
        minSdk = 23
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(project(":hermes-livechat"))
    implementation("androidx.activity:activity-ktx:1.9.3")
}
