package com.gracemusic.feature.user

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gracemusic.core.theme.Md3MusicTheme
import com.gracemusic.data.account.AuthState

/** 「我的」页根节点的测试标签（androidTest tab 切换断言用）。 */
internal const val UserCenterScreenTestTag = "user_center_page"

/** 「我的」页登录按钮测试标签。 */
internal const val UserCenterLoginButtonTag = "user_center_login_button"

/**
 * 「我的」页（T-P4-11 / F-STAT-007 登录态分支）。
 *
 * 对位 lite `lib/modules/user/user_center_page.dart` 的未登录/已登录两态分支：
 * - **未登录**（[AuthState.LoggedOut]）：头像占位 + 「登录后同步收藏」文案 + 登录按钮
 *   （对位 lite `_buildNotLoggedIn`）；
 * - **已登录**（[AuthState.LoggedIn]）：显示 userid / 昵称 + 退出登录按钮
 *   （lite 已登录态另有会员卡/听歌数据/操作网格，属 P4 后续，未实现）。
 *
 * @param onNavigateToLogin 点击登录按钮（调用方导航到 `/login`）。
 */
@Composable
fun UserCenterScreen(
    onNavigateToLogin: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: UserCenterViewModel = hiltViewModel(),
) {
    val authState by viewModel.authState.collectAsStateWithLifecycle()

    // 冷启动恢复登录态（一次性；AccountRepository.restoreSession 内部有幂等守卫）。
    LaunchedEffect(Unit) { viewModel.restoreSession() }

    Box(
        modifier = modifier
            .fillMaxSize()
            .testTag(UserCenterScreenTestTag),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.padding(all = 24.dp),
        ) {
            // 头像占位：圆形 surface + 人物图标（lite 未登录头像占位语义）。
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.surfaceVariant,
                modifier = Modifier.size(size = 72.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Filled.Person,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(size = 36.dp),
                    )
                }
            }

            when (val state = authState) {
                is AuthState.LoggedOut -> {
                    Text(
                        text = "登录后同步收藏",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Button(
                        onClick = onNavigateToLogin,
                        modifier = Modifier.testTag(UserCenterLoginButtonTag),
                    ) {
                        Text("登录")
                    }
                }

                is AuthState.LoggedIn -> {
                    Text(
                        text = state.nickname ?: "已登录",
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        text = "ID：${state.userid}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedButton(onClick = viewModel::logout) {
                        Text("退出登录")
                    }
                }

                // 刷新中：不额外渲染（lite 无对应 UI）。
                is AuthState.Refreshing -> Unit
            }
        }
    }
}

@Preview(name = "我的页 · 未登录", showBackground = true)
@Composable
private fun UserCenterScreenLoggedOutPreview() {
    Md3MusicTheme {
        UserCenterScreen(onNavigateToLogin = {})
    }
}
