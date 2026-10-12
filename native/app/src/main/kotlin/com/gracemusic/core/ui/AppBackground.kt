package com.gracemusic.core.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import com.gracemusic.core.theme.Md3MusicTheme

/**
 * 全局页面背景占位（P0-C）。
 *
 * 对应 lite `lib/core/widgets/app_background.dart` 的 `AppBackground`：
 * 主题背景色打底 + 模糊背景图 + 透明度调节。lite 的层级是
 * `ColoredBox(surface) → Opacity(backgroundOpacity) → ImageFiltered(blur) → Image`，
 * 并随页面路由过渡一起位移（`_BgSafeFadeForwardsBuilder` 内嵌背景）。
 *
 * P0-C 仅落地 surface 纯色打底层；作为页面内容的底层存在，
 * 为 P3 的背景图/取色体系预留挂点。
 */
@Composable
fun AppBackground(
    modifier: Modifier = Modifier,
    background: Color = MaterialTheme.colorScheme.surface,
    content: @Composable () -> Unit = {},
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(background),
    ) {
        content()
        // TODO(P3): 背景图层（对应 lite AppBackground 的图片层）：
        //   1. 用户背景图 / 内置默认壁纸（Coil AsyncImage，BoxFit.cover）；
        //   2. ImageFilter 高斯模糊（backgroundBlur，0~30 sigma）+ Opacity（0.2~1.0）；
        //   3. 按背景图莫奈取色 → 注入 seed 链（见 SeedColors 优先级注释）；
        //   4. 背景图启用时页面主要表面改透明（_applyBackgroundOverrides 的 native 对应）。
    }
}

/**
 * 路由占位屏：Box + 路由名文本，`fillMaxSize` + surface 底色，便于走查。
 *
 * P0-C 所有 9 条路由共用；P3 各 feature 页面就位后逐一替换。
 */
@Composable
fun RoutePlaceholder(
    route: String,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surface),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = route,
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
        )
    }
}

@Preview(name = "背景层 · 浅色", showBackground = true)
@Composable
private fun AppBackgroundLightPreview() {
    Md3MusicTheme(darkTheme = false) {
        AppBackground()
    }
}

@Preview(name = "路由占位 · 深色", showBackground = true)
@Composable
private fun RoutePlaceholderDarkPreview() {
    Md3MusicTheme(darkTheme = true) {
        RoutePlaceholder(route = "/")
    }
}
