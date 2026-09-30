import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) {
        load(FileInputStream(f))
    }
}

android {
    namespace = "com.md3music.md3music"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    // Lite 分支：保留 flavor 声明以兼容上游 CI/脚本（125 处引用），但 3D 深度封面已下线：
    //   standard - lite 唯一构建目标（无 ORT so、无深度模型资产）
    //   depth3d  - 已移除 3D 资产与 ONNX AAR，上游 CI 的 "无 AAR 即跳过" 门控会自动跳过它
    // 构建：flutter build apk --release --flavor standard --split-per-abi
    flavorDimensions += "feature"
    productFlavors {
        create("standard") {}
        create("depth3d") {}
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    defaultConfig {
        // CI 的原子随身听兼容包只覆盖 applicationId；namespace、Kotlin 包路径和
        // MethodChannel 名保持不变，避免复制或改写原生代码。
        // Lite：默认包名加 .lite 后缀与完整版共存安装（FileProvider authority
        // 走 ${applicationId} 占位符自动跟随；MethodChannel 名/广播 action 为
        // 独立字符串不受影响）。随身听兼容包仍由 CI 显式覆盖为
        // com.apple.android.music（伪装包名正是其存在意义，不加后缀）。
        applicationId = providers.gradleProperty("md3ApplicationId")
            .getOrElse("com.md3music.md3music.lite")
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 渲染引擎固定为 skia（EnableImpeller=false，兼容优先）。Flutter 3.44 只认
        // manifest 静态值。仅此一处、无 flavor：保证 split-per-abi 产物名不含引擎标识。
        manifestPlaceholders["enableImpeller"] = "false"
        // Lite：只出真实设备 ABI（arm64-v8a / armeabi-v7a）。
        // x86 / x86_64 仅服务模拟器调试，且 libkugou_server.so 的 x86 两个 so
        // 合计 10.1MB —— 一并排除，模拟器请改用 arm64 镜像。
        // ⚠️ ABI 收窄**不能**用 ndk.abiFilters：--split-per-abi 时 Flutter 插件会
        // 注入 splits.abi（默认含 x86_64），AGP 判定两者冲突直接失败
        // （"Conflicting configuration: ndk abiFilters cannot be present when
        //  splits abi filters are set"）。收窄由两处负责：
        //   1) CI 传 --target-platform android-arm64,android-arm（决定 splits 与引擎 so）
        //   2) 下方 externalNativeBuild.cmake.abiFilters（决定 C++ 驱动编译哪些 ABI）
        // USB 独占输出 C++ 驱动：只编译与 jniLibs 相同的 ABI
        externalNativeBuild {
            cmake {
                abiFilters("arm64-v8a", "armeabi-v7a")
            }
        }
    }

    // 2026-09-12：加入 libflacJNI.so（P0-5 flac 扩展）后 native libs 被改为 Stored
    // （APK 153.6→191.2MB）。显式恢复未压缩打包默认（extractNativeLibs=false，
    // 直接从 APK 页对齐加载，安装包最小、加载最快）。
    packaging {
        jniLibs.useLegacyPackaging = false
    }

    signingConfigs {
        create("release") {
            if (keystoreProperties.isNotEmpty()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Use the persistent release signing config (if keystore.properties exists)
            // Falls back to debug signing when keystore.properties is missing (CI / first build)
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        debug {
            // Disable symbol stripping for Gradle 9.x compatibility
            ndk {
                debugSymbolLevel = "none"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.media:media:1.6.0")
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("io.github.proify.lyricon:provider:0.1.70")
    implementation("io.github.proify.lyricon.lyric:model:0.1.70")
    // SuperLyricApi：基于 Binder 的系统级实时歌词 API（jnitpack，settings.gradle.kts 已声明）
    implementation("com.github.HChenX:SuperLyricApi:3.4")
    // JAudioTagger 社区分叉（支持 MP3/FLAC/Ogg/M4A 等格式的 ID3v2 / VorbisComment 标签读写，
    // 用于在下载完成后向音频文件嵌入标题/艺术家/专辑/封面/歌词）。
    // JitPack 上 AdrienPoupa 分叉仅有 2.2.3（无 2.2.5）。
    implementation("com.github.AdrienPoupa:jaudiotagger:2.2.3")
    // 方案B阶段1：app 侧 Kotlin 引用 androidx.media3.common 类型（UnstableApi、Player 等）。
    // media3-common 为单一 maven 源（fork 同版本 1.4.1），此处显式依赖以便编译期可见
    // （fork 用 implementation 隐藏了传递依赖）。session/exoplayer 仍是 fork 本地源码，勿加 maven。
    implementation("androidx.media3:media3-common:1.4.1")
    // 2×2 封面小部件：从专辑封面位图提取主色（vibrant/dominant swatch）
    implementation("androidx.palette:palette-ktx:1.0.0")
    // Lite：已移除 3D 深度封面（ONNX Runtime AAR + Depth Anything V2 / MI-GAN 模型），
    // 这里的 depth3dImplementation 依赖与 android/app/libs/onnxruntime-*.aar、
    // android/app/src/depth3d/ 一并删除，省 42.2MB（13.2MB so + 29MB 模型）。

    // USB 独占数据路径（UsbDither / UsbAudioStream.writeRaw）的 JVM 单元测试
    testImplementation("junit:junit:4.13.2")
}

// MD3Music fork: 全局强制 media3 版本与本地 just_audio fork 的 exoplayer 源码一致（1.4.1）。
// video_player 等库声明更高版本（1.9.2），若不强制会出现重复类（本地源码 vs maven 1.9.2）。
// media3-exoplayer 的 maven 版本全局排除——由 just_audio fork 内的本地源码提供。
configurations.all {
    exclude(group = "androidx.media3", module = "media3-exoplayer")
    resolutionStrategy {
        force(
            "androidx.media3:media3-common:1.4.1",
            "androidx.media3:media3-container:1.4.1",
            "androidx.media3:media3-database:1.4.1",
            "androidx.media3:media3-datasource:1.4.1",
            "androidx.media3:media3-decoder:1.4.1",
            "androidx.media3:media3-exoplayer-dash:1.4.1",
            "androidx.media3:media3-exoplayer-hls:1.4.1",
            "androidx.media3:media3-exoplayer-rtsp:1.4.1",
            "androidx.media3:media3-exoplayer-smoothstreaming:1.4.1",
            "androidx.media3:media3-extractor:1.4.1"
        )
    }
}

flutter {
    source = "../.."
}
