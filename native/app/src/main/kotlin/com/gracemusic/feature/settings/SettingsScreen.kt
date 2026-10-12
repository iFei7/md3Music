package com.gracemusic.feature.settings

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.gracemusic.core.theme.Md3MusicTheme
import com.gracemusic.core.ui.RoutePlaceholder

/**
 * 设置页占位（路由 `/settings`）。
 *
 * P0-C 仅路由占位。lite 的设置项（主题模式 / 动态取色 / OLED 纯黑 /
 * 底部导航栏文字 / 背景图等）在 P1 起逐步落地。
 */
@Composable
fun SettingsScreen(modifier: Modifier = Modifier) {
    RoutePlaceholder(route = "/settings", modifier = modifier)
}

@Preview(name = "设置页占位", showBackground = true)
@Composable
private fun SettingsScreenPreview() {
    Md3MusicTheme {
        SettingsScreen()
    }
}
