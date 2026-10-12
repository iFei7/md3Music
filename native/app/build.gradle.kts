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
    ndkVersion = "28.2.13676358"

    // P0-B：C JNI shim（libkugou_jni_shim.so）经 ndk-build 构建，按 ABI 以 -l 名称
    // 链接预编译 libkugou_server.so（该 so 无 DT_SONAME，DT_NEEDED 须为纯库名，
    // 运行时由 Android 链接器按 APK lib/<abi>/ 自动解析）。
    // 注：原采用 SDK cmake 3.22.1 方案，因部分环境（本机沙箱）无法启动该 cmake——
    // 其依赖的 api-ms-win-crt-* API-set DLL 解析失败（STATUS_DLL_NOT_FOUND），
    // 而 NDK 自带 make/ninja 工具链验证可用，故切换 ndk-build（单文件 C 无
    // cmake 特性需求；CI 仅需安装 NDK 即可构建）。
    externalNativeBuild {
        ndkBuild {
            path = file("src/main/cpp/Android.mk")
        }
    }

    defaultConfig {
        // 与 lite（com.md3music.md3music.lite）共存安装、数据隔离；namespace/Kotlin 包路径
        // 保留 com.md3music.md3music（JNI shim 符号、FileProvider authority 推导依赖）。
        applicationId = "com.md3music.md3music.native"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0-native"

        // 只构建 jniLibs 中实际存在的 ABI（arm64-v8a / armeabi-v7a；x86 系按体积
        // 决策排除）。Android.mk 内另有 wildcard 校验兜底缺失 ABI 的 so。
        externalNativeBuild {
            ndkBuild {
                abiFilters += listOf("arm64-v8a", "armeabi-v7a")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // 预编译 so 页对齐加载（extractNativeLibs=false），与 Flutter 工程一致
    packaging {
        jniLibs.useLegacyPackaging = false
    }

    // 单元测试：Robolectric 需要加载工程的 Android 资源（字符串/渠道文案、
    // 通知小图标 ic_launcher_monochrome 等），否则资源查询抛
    // Resources$NotFoundException。SDK 级别固定在 app/src/test/resources/robolectric.properties。
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
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

// MD3Music native: 全局排除 Maven 的 media3-exoplayer / media3-session。
// 二者由 :media3fork（fork 本地源码）提供，任何传递依赖再次引入 Maven 版都会造成
// "Duplicate class androidx.media3.exoplayer.*" 编译失败 —— 与 Flutter 工程
// android/app/build.gradle.kts 的全局排除策略对齐。
configurations.configureEach {
    exclude(group = "androidx.media3", module = "media3-exoplayer")
    exclude(group = "androidx.media3", module = "media3-session")
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

    // --- 播放（Media3 1.4.1）---
    // exoplayer / session 由 :media3fork 提供（fork 内嵌本地源码，含 9 处产品级改动：
    // 焦点事件暴露、vivo 车载歌词/原子随身听、DefaultAudioSink 缓冲修复、媒体卡下一首修复、
    // 前台服务补偿等）。必须走本地源码 —— Maven 版同为 1.4.1 但缺失上述改动。
    // 仅 media3-common 走 Maven（同版本，供 app 侧 Kotlin 引用 UnstableApi/Player 等类型）。
    implementation(project(":media3fork"))
    implementation(libs.media3.common)
    // LibflacAudioRenderer 的父类链（DecoderAudioRenderer → SimpleDecoderAudioRenderer）签名中
    // 出现 androidx.media3.decoder.SimpleDecoder，须在 :app 的编译类路径上可见
    // （:media3fork 以 implementation 声明该模块，不向消费者导出）。
    implementation(libs.media3.decoder)

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
