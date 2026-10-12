plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.devtools.ksp")
    id("com.google.dagger.hilt.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.md3music.md3music"
    compileSdk = 36

    defaultConfig {
        // 与 lite（com.md3music.md3music.lite）共存安装、数据隔离；namespace/Kotlin 包路径
        // 保留 com.md3music.md3music（JNI shim 符号、FileProvider authority 推导依赖）。
        applicationId = "com.md3music.md3music.native"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0-native"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // 预编译 so 页对齐加载（extractNativeLibs=false），与 Flutter 工程一致
    packaging {
        jniLibs.useLegacyPackaging = false
    }

    buildTypes {
        debug {
            // 与 Flutter 工程 android/app/build.gradle.kts 对齐：Gradle 9.x 下显式固定
            // 符号剥离级别，保证预编译 so（libkugou_server.so / libflacJNI.so）打包行为
            // 跨 AGP 版本稳定（.dynsym 导出符号为 dart:ffi / JNI 契约，必须保留）。
            ndk {
                debugSymbolLevel = "none"
            }
        }
        release {
            // R8 规则与混淆配置后续阶段补齐，骨架期暂不开 minify
            isMinifyEnabled = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // --- Compose（BOM 统一版本）---
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    // --- AndroidX 基础 ---
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.palette.ktx)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.security.crypto)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.hilt.navigation.compose)

    // --- DI（Hilt）---
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)

    // --- 数据库（Room）---
    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)

    // --- 网络（Retrofit + OkHttp + kotlinx.serialization）---
    implementation(libs.retrofit)
    implementation(libs.retrofit.converter.kotlinx.serialization)
    implementation(libs.okhttp)

    // --- 播放（Media3 锁定 1.4.1，与 just_audio fork 内嵌源码对齐）---
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.session)
    implementation(libs.media3.common)

    // --- 图片（Coil 3 + okhttp 网络组件）---
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    // --- 异步 / 序列化 ---
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)

    // --- 单元测试 ---
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)

    // --- Compose UI 测试 ---
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
}
