package com.gracemusic.core.theme

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp

/**
 * 主题 Preview 样例（P0-C）。
 *
 * 展示 [Md3MusicTheme] 在浅色 / 深色 / OLED 纯黑 / 深色无动态取色四种配置下的
 * 配色落地，搭配一个占位屏内容（[ThemePreviewContent]）便于走查。
 * AS 预览渲染运行在宿主 JVM，dynamicColor 恒为 false（低版本静态 scheme 路径）。
 */

@Composable
private fun ThemePreviewContent() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(text = "MD3Music Native", style = MaterialTheme.typography.headlineSmall)
        Card(
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
            ),
        ) {
            Text(
                text = "primaryContainer 卡片（surface 系列见背景）",
                modifier = Modifier.padding(16.dp),
            )
        }
        Card {
            Text(
                text = "surfaceContainer 卡片（OLED 下为纯黑/极深灰）",
                modifier = Modifier.padding(16.dp),
            )
        }
    }
}

@Preview(name = "主题 · 浅色", showBackground = true)
@Composable
private fun Md3MusicThemeLightPreview() {
    Md3MusicTheme(darkTheme = false) {
        ThemePreviewContent()
    }
}

@Preview(name = "主题 · 深色", showBackground = true)
@Composable
private fun Md3MusicThemeDarkPreview() {
    Md3MusicTheme(darkTheme = true) {
        ThemePreviewContent()
    }
}

@Preview(name = "主题 · 深色 OLED 纯黑", showBackground = true)
@Composable
private fun Md3MusicThemeDarkOledPreview() {
    Md3MusicTheme(darkTheme = true, oledBlack = true) {
        ThemePreviewContent()
    }
}
