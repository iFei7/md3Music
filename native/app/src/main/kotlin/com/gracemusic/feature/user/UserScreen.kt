package com.gracemusic.feature.user

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.gracemusic.core.theme.Md3MusicTheme

/**
 * 用户中心（路由 `/user`）。
 *
 * P0-C 曾是路由占位；T-P4-11 起落地 [UserCenterScreen]（未登录/已登录两态分支 +
 * 登录页入口）。lite 的 UserCenterPage 由发现页右上角头像进入（push 独立路由，
 * 与底部 tab 中的实例并存无冲突）。
 *
 * @param onNavigateToLogin 点击「登录」按钮（调用方导航到 `/login`）。
 */
@Composable
fun UserScreen(
    onNavigateToLogin: () -> Unit,
    modifier: Modifier = Modifier,
) {
    UserCenterScreen(onNavigateToLogin = onNavigateToLogin, modifier = modifier)
}

@Preview(name = "用户中心", showBackground = true)
@Composable
private fun UserScreenPreview() {
    Md3MusicTheme {
        UserScreen(onNavigateToLogin = {})
    }
}
