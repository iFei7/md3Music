// MD3Music native —— just_audio fork 内嵌 media3 源码（exoplayer / session / decoder-flac）的编译模块。
//
// 为什么必须保留 fork 的本地源码、而不能退回 Maven media3（版本同为 1.4.1）：
//   fork 在 vendored 源码上做了 9 处**产品级**改动，Maven 版全部缺失：
//     1. exoplayer/AudioFocusManager.java  —— 将焦点事件暴露给宿主（Dart/原生三模式决策的基础）
//     2. exoplayer/audio/DefaultAudioSink.java —— pending inputBuffer 清理与 AudioTrack 初始化解耦（P0-5 缓冲）
//     3. exoplayer/ExoPlayerImpl.java        —— 媒体卡片「下一首」按钮消失修复
//     4. session/legacy/MediaSessionCompat.java —— vivo 车载歌词注入（UCAR）+ 原子随身听 + 封面 1x1 规避
//     5. session/LegacyConversions.java      —— 原子随身听（vivomusicmix）能力位 7|8|16
//     6. session/MediaSessionService.java    —— 手动触发 now playing 通知刷新
//     7. session/MediaNotificationManager.java —— 后台切歌 startForegroundService 被拒的补偿
//     8. session/MediaSessionLegacyStub.java —— 封面链路诊断日志
//     9. session/MediaSessionImpl.java       —— 平台/legacy PlaybackState customActions 暴露
//
// 为什么不把源码直接并进 :app：
//   vendored 源码包名是 androidx.media3.*，但 session 的 4 个文件（CommandButton /
//   DefaultMediaNotificationProvider / legacy/MediaControllerCompat / LegacyConversions）
//   `import com.ryanheise.just_audio.R`（通知图标、布局、多语言字符串），且这些资源必须一并编译。
//   若并入 :app（namespace = com.gracemusic），需改动 third_party 下由 lite 分支共享的
//   源码（破坏单一事实来源）。此处将本模块 namespace 设为 com.ryanheise.just_audio，
//   使 R 零改动解析，且 third_party 源码保持逐字节不变。
//
// 与 Maven 的边界：exoplayer / session 由本模块提供；:app 全局排除 Maven 的
//   media3-exoplayer / media3-session（防重复类），仅保留 media3-common（同版本 1.4.1）。
// 源码与资源均**零拷贝**：srcDirs 直接指向 third_party/just_audio/android 下的 vendored 目录。
// 注：libflacJNI.so 不在此模块打包 —— 它由 native/scripts/sync_jnilibs.sh 维护在
//   :app 的 jniLibs（同一份 so 若同时被两处打包会触发 "2 files found with path" 合并冲突）；
//   FlacLibrary 以 System.loadLibrary("flacJNI") 按库名加载，与打包模块无关。

plugins {
    id("com.android.library")
}

// 仓库根 = native/ 的上一级；fork 源码位于 <repo>/third_party/just_audio/android/src/main
val forkMainDir = rootProject.file("../third_party/just_audio/android/src/main")

android {
    namespace = "com.ryanheise.just_audio"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            // 仅纳入 vendored media3 源码；不含 com/ryanheise/just_audio 下的 Flutter 插件层
            // （AudioPlayer/JustAudioPlugin/BetterEventChannel/MainMethodCallHandler 依赖 io.flutter，
            //  原生化时由 :app 的 player/engine 以 Kotlin 重写，DSP 类单独移植）。
            java.srcDirs(
                File(forkMainDir, "java/androidx/media3/exoplayer"),
                File(forkMainDir, "java/androidx/media3/session"),
                File(forkMainDir, "java/androidx/media3/decoder/flac"),
            )
            // fork 的通知图标（media3_icon_*）、9 个通知布局、83 个 values 多语言目录
            res.srcDirs(File(forkMainDir, "res"))
        }
    }

    lint {
        // vendored 第三方源码（media3 1.4.1 + fork 改动）不作为本工程 lint 门禁对象，
        // 保持与 fork 库一致的宽松策略（fork build.gradle.kts 亦 disable 同名规则）。
        disable += listOf(
            "AndroidGradlePluginVersion",
            "InvalidPackage",
            "GradleDependency",
            "NewerVersionAvailable",
            "MissingTranslation",
            "MissingDefaultResource",
        )
        abortOnError = false
    }
}

dependencies {
    val media3Version = libs.versions.media3.get()

    // 与 fork build.gradle.kts 逐项对齐的 Maven 依赖面（本地源码版 exoplayer 的其余 media3 模块）
    implementation("androidx.media3:media3-common:$media3Version")
    implementation("androidx.media3:media3-container:$media3Version")
    implementation("androidx.media3:media3-database:$media3Version")
    implementation("androidx.media3:media3-datasource:$media3Version")
    implementation("androidx.media3:media3-decoder:$media3Version")
    implementation("androidx.media3:media3-extractor:$media3Version")

    // MD3Music fork: AudioFocusRequestCompat（自动携带 ACCEPTS_DUCKING，焦点事件可达）
    implementation("androidx.media:media:1.7.0")

    // androidx.media:media:1.7.0 的传递依赖把 androidx.core 解析到 1.6.0，而 vendored
    // media3-session 使用了 core 1.7.0+ 的 API（NotificationCompat.Builder
    // #setForegroundServiceBehavior 等），不显式抬升会编译失败。版本与 :app 的
    // core-ktx 保持一致，避免同一 build 内 core 出现两个版本。
    implementation(libs.androidx.core)

    // 本地 exoplayer 源码所需的注解依赖（原 Maven media3-exoplayer 自带传递依赖，此处显式补齐）
    compileOnly("com.google.errorprone:error_prone_annotations:2.28.0")
    compileOnly("org.checkerframework:checker-qual:3.43.0")

    // fork 自带蝰蛇母带 DSP 的 JVM 单测依赖（与 fork 保持一致）
    testImplementation("junit:junit:4.13.2")
}
