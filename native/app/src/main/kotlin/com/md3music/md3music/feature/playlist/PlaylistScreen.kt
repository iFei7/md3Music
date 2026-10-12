package com.md3music.md3music.feature.playlist

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.md3music.md3music.core.theme.Md3MusicTheme
import com.md3music.md3music.core.ui.RoutePlaceholder

/**
 * 歌单详情占位（路由 `/playlist`）。
 *
 * lite 的 `/playlist` 经 onGenerateRoute 接收 `Playlist` 对象参数
 * （fade 转场）；native 侧 P0-C 用可空字符串 id 占位
 * （见 `Routes.ARG_PLAYLIST_ID`），P3 接 DataSource 后按 id 加载。
 */
@Composable
fun PlaylistScreen(modifier: Modifier = Modifier) {
    RoutePlaceholder(route = "/playlist", modifier = modifier)
}

@Preview(name = "歌单详情占位", showBackground = true)
@Composable
private fun PlaylistScreenPreview() {
    Md3MusicTheme {
        PlaylistScreen()
    }
}
