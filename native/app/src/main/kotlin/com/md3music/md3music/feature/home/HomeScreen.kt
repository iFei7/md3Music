package com.md3music.md3music.feature.home

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.md3music.md3music.core.theme.Md3MusicTheme
import com.md3music.md3music.core.ui.RoutePlaceholder

/**
 * 主页占位（路由 `/`）。
 *
 * P0-C 仅路由占位。P3 对应 lite `_MainLayout`：底部 tab 壳
 * （discover/favorites/library/fm/search/recognition/settings/user，
 * 见 `_buildPageForTab`）+ 玻璃 Dock 播放控制 + 封面流等。
 */
@Composable
fun HomeScreen(modifier: Modifier = Modifier) {
    RoutePlaceholder(route = "/", modifier = modifier)
}

@Preview(name = "主页占位", showBackground = true)
@Composable
private fun HomeScreenPreview() {
    Md3MusicTheme {
        HomeScreen()
    }
}
