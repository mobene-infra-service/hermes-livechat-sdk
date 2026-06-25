plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.mobene.hermes.livechat"
    compileSdk = 35

    defaultConfig {
        minSdk = 23
        consumerProguardFiles("consumer-rules.pro")
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
    api("io.github.centrifugal:centrifuge-java:0.6.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Markwon：正式 Markdown 渲染库，替代手写 inline 解析器，与 widget(markdown-it) 渲染范围对齐。
    // core    —— 段落 / 列表 / 粗体 / 斜体 / 行内 code / 显式链接
    // linkify —— 裸 URL 自动识别为可点击链接
    // image   —— 正文内联 ![](url) 网络图片
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:linkify:4.6.2")
    implementation("io.noties.markwon:image:4.6.2")

    // 纯函数业务规则（MessageContent）的本地单元测试，不依赖 Android 运行时。
    testImplementation("junit:junit:4.13.2")
}
