package com.gracemusic.feature.library

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.gracemusic.core.theme.Md3MusicTheme
import com.gracemusic.core.ui.RoutePlaceholder

/**
 * 本地乐库占位（路由 `/library`）。
 *
 * P0-C 仅路由占位。lite 的 LibraryPage 同时用作底部 tab「本地音乐」
 * 与桌面快捷方式路由；P3 落地时注意双栏判定（大屏 B 类 Tab）。
 */
@Composable
fun LibraryScreen(modifier: Modifier = Modifier) {
    RoutePlaceholder(route = "/library", modifier = modifier)
}

@Preview(name = "本地乐库占位", showBackground = true)
@Composable
private fun LibraryScreenPreview() {
    Md3MusicTheme {
        LibraryScreen()
    }
}
