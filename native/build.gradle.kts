// native 工程根构建脚本：仅声明插件（apply false），版本在 settings.gradle.kts 统一管理。
plugins {
    id("com.android.application") apply false
    id("org.jetbrains.kotlin.android") apply false
    id("org.jetbrains.kotlin.plugin.compose") apply false
    id("com.google.devtools.ksp") apply false
    id("com.google.dagger.hilt.android") apply false
    id("org.jetbrains.kotlin.plugin.serialization") apply false
}
