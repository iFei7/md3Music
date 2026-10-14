package com.gracemusic.feature.discover

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.FilledTonalButton
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

/** 「发现」页根节点的测试标签（androidTest tab 切换断言用）。 */
internal const val DiscoverScreenTestTag = "discover_page"

/**
 * 「发现」tab 页骨架（P3-A 空态）。
 *
 * 对位 lite `lib/modules/discover/discover_page.dart:276` 的 `_buildError`：
 * lite 为「加载失败 + 错误详情 + 重试」（FilledButton.tonal）。P3-A 无数据
 * 链路（KugouApi.search 归 P3-B），**简化为空态**：图标 + 「内容即将上线」 +
 * 重试按钮样式（视觉对齐、onPress 为 no-op），登记偏离于台本 §3.2。
 *
 * 图标偏离：lite 用 `Icons.cloud_off`，material-icons 默认集无该图标，
 * 以 `Icons.Outlined.Info` 近似替代；**待补 `material-icons-extended`
 * 依赖后换回 CloudOff**（登记遗留）。
 */
@Composable
fun DiscoverScreen(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .testTag(DiscoverScreenTestTag),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(all = 24.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Info,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                modifier = Modifier.size(size = 48.dp),
            )
            Text(
                text = "内容即将上线",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            // TODO(P3-B): 接 KugouApi.search 数据链路后改为「加载失败 + 重试」
            //   真实错误态（对位 discover_page.dart:276 _buildError + _loadAllData）。
            FilledTonalButton(onClick = { /* 空态无重试动作，样式占位 */ }) {
                Text(text = "重试")
            }
        }
    }
}

@Preview(name = "发现页骨架", showBackground = true)
@Composable
private fun DiscoverScreenPreview() {
    Md3MusicTheme {
        DiscoverScreen()
    }
}
