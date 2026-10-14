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
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.gracemusic.core.theme.Md3MusicTheme

/** 「我的」页根节点的测试标签（androidTest tab 切换断言用）。 */
internal const val UserCenterScreenTestTag = "user_center_page"

/**
 * 「我的」tab 页骨架（P3-A 未登录态占位）。
 *
 * 对位 lite `lib/modules/user/` 的 `UserCenterPage`（未登录态）：头像占位 +
 * 登录引导文案。native 无会话层（登记偏离台本 §2「在线起播无登录拦截」同源），
 * P3-A 仅落「头像占位 + 登录后同步收藏」文案占位；收藏区独立为
 * [FavoritesScreen]（对位 lite `_buildPageForTab` 的 favorites 独立页）。
 */
@Composable
fun UserCenterScreen(modifier: Modifier = Modifier) {
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
            Text(
                text = "登录后同步收藏",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Preview(name = "我的页骨架", showBackground = true)
@Composable
private fun UserCenterScreenPreview() {
    Md3MusicTheme {
        UserCenterScreen()
    }
}
