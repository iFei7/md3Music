package com.md3music.md3music.feature.search

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.md3music.md3music.core.theme.Md3MusicTheme
import com.md3music.md3music.core.ui.RoutePlaceholder

/**
 * 搜索页占位（路由 `/search`）。
 *
 * P0-C 仅路由占位。lite 的 SearchPage 自包悬浮宿主、播放控制由底部
 * 玻璃 Dock 承载；P3 落地时需接 Dock 避让（`Modifier.dockPadding`）。
 */
@Composable
fun SearchScreen(modifier: Modifier = Modifier) {
    RoutePlaceholder(route = "/search", modifier = modifier)
}

@Preview(name = "搜索页占位", showBackground = true)
@Composable
private fun SearchScreenPreview() {
    Md3MusicTheme {
        SearchScreen()
    }
}
