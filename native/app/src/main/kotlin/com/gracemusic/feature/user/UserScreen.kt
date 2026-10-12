package com.gracemusic.feature.user

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.gracemusic.core.theme.Md3MusicTheme
import com.gracemusic.core.ui.RoutePlaceholder

/**
 * 用户中心占位（路由 `/user`）。
 *
 * P0-C 仅路由占位。lite 的 UserCenterPage 由发现页右上角头像进入
 * （push 独立路由，与底部 tab 中的实例并存无冲突）。
 */
@Composable
fun UserScreen(modifier: Modifier = Modifier) {
    RoutePlaceholder(route = "/user", modifier = modifier)
}

@Preview(name = "用户中心占位", showBackground = true)
@Composable
private fun UserScreenPreview() {
    Md3MusicTheme {
        UserScreen()
    }
}
