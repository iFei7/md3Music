package com.gracemusic.feature.user

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Favorite
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.gracemusic.core.theme.Md3MusicTheme

/** 「收藏」页根节点的测试标签（androidTest tab 切换断言用）。 */
internal const val FavoritesScreenTestTag = "favorites_page"

/**
 * 「收藏」tab 页骨架（P3-A 空态）。
 *
 * 对位 lite `lib/modules/user/favorites_page.dart`：lite 的收藏是用户中心
 * 内的完整页面（歌单/专辑/歌手分组，:1416「还没有收藏专辑」等分组空态）。
 * P3-A 无收藏仓库（T-P2 数据层），落整页空态「还没有收藏」；收藏数据接入
 * 与分组结构归 P3-D（登记简化）。
 */
@Composable
fun FavoritesScreen(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .testTag(FavoritesScreenTestTag),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(all = 24.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Favorite,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                modifier = Modifier.size(size = 48.dp),
            )
            Text(
                text = "还没有收藏",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Preview(name = "收藏页骨架", showBackground = true)
@Composable
private fun FavoritesScreenPreview() {
    Md3MusicTheme {
        FavoritesScreen()
    }
}
