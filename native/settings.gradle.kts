// native 分支独立原生 Gradle 工程（与 Flutter 的 android/ 并存）。
// 仓库配置对齐 Flutter 工程 android/settings.gradle.kts：google + mavenCentral +
// gradlePluginPortal（插件面），google + mavenCentral + jitpack（依赖面，JAudioTagger
// 社区分叉托管在 JitPack，国内镜像不代理，必须显式声明）。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    // Kotlin 2.x 内置的 Compose 编译器插件（版本与 Kotlin 一致）
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.20" apply false
    // KSP：2.3.12 为 Maven Central 上可解析的、基于 Kotlin 2.3.20 构建的最新匹配版
    // （其 POM 依赖 kotlin-stdlib 2.3.20，与 Kotlin 插件版本严格对应）
    id("com.google.devtools.ksp") version "2.3.12" apply false
    id("com.google.dagger.hilt.android") version "2.60.1" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.3.20" apply false
}

dependencyResolutionManagement {
    repositoriesMode.set(org.gradle.api.initialization.resolve.RepositoriesMode.PREFER_PROJECT)
    repositories {
        google()
        mavenCentral()
        // JAudioTagger 社区分叉（com.github.AdrienPoupa:jaudiotagger）托管在 JitPack，
        // 国内镜像源（aliyun）不代理 JitPack，必须显式在 settings 中声明。
        maven { url = uri("https://jitpack.io") }
    }
}

include(":app")
// MD3Music native: just_audio fork 内嵌 media3 源码（exoplayer/session/decoder-flac）编译模块。
// 单独成模块的原因见 media3fork/build.gradle.kts 顶部注释（R 引用零改动 + 单一事实来源）。
include(":media3fork")
