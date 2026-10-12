package com.gracemusic

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.gracemusic.core.theme.Md3MusicTheme
import com.gracemusic.ui.Md3MusicApp
import dagger.hilt.android.AndroidEntryPoint

/**
 * 单 Activity Compose 宿主。
 *
 * 层级：`Md3MusicTheme { Md3MusicApp() }`——主题（配色 / 排版 / 动效常量）
 * 与导航框架（9 条路由的 NavHost）的解耦点，对应 lite
 * `MaterialApp(theme: AppTheme.lightThemeFromSeed(...))` 的角色。
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            // TODO(P1): 主题开关接 DataStore 后按 lite ThemeProvider 状态面传参：
            //   darkTheme 跟随 themeMode（system/light/dark）；
            //   dynamicColor 跟随 use_dynamic_color（默认 false）；
            //   oledBlack 跟随 use_oled_black（默认 false，仅深色生效）。
            Md3MusicTheme {
                Md3MusicApp()
            }
        }
    }
}
