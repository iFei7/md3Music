package com.md3music.md3music.feature.personalfm

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.md3music.md3music.core.theme.Md3MusicTheme
import com.md3music.md3music.core.ui.RoutePlaceholder

/**
 * 私人 FM 占位（路由 `/personal_fm`）。
 *
 * P0-C 仅路由占位。lite 的 PersonalFmPage 同时用作底部 tab「fm」。
 */
@Composable
fun PersonalFmScreen(modifier: Modifier = Modifier) {
    RoutePlaceholder(route = "/personal_fm", modifier = modifier)
}

@Preview(name = "私人 FM 占位", showBackground = true)
@Composable
private fun PersonalFmScreenPreview() {
    Md3MusicTheme {
        PersonalFmScreen()
    }
}
