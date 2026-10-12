package com.gracemusic.feature.personalfm

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.gracemusic.core.theme.Md3MusicTheme
import com.gracemusic.core.ui.RoutePlaceholder

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
