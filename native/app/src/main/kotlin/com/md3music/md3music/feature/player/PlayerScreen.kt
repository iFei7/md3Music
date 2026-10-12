package com.md3music.md3music.feature.player

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.md3music.md3music.core.theme.Md3MusicTheme
import com.md3music.md3music.core.ui.RoutePlaceholder

/**
 * 全屏播放器占位（路由 `/player`）。
 *
 * P0-C 仅路由占位。lite 的 FullPlayer push 时主页向上偏移 15% + 淡出
 * （`_UpFadeMainRoute`，playerExpansion > 0.5 时生效），转场细节 P3 补齐。
 */
@Composable
fun PlayerScreen(modifier: Modifier = Modifier) {
    RoutePlaceholder(route = "/player", modifier = modifier)
}

@Preview(name = "全屏播放器占位", showBackground = true)
@Composable
private fun PlayerScreenPreview() {
    Md3MusicTheme {
        PlayerScreen()
    }
}
