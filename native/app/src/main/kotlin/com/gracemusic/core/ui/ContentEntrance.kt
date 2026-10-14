package com.gracemusic.core.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOutCubic
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer

import com.gracemusic.core.theme.Md3Motion

/**
 * 内容入场动画：上浮淡入，仅首次组合时播放（对位 lite
 * `lib/widgets/app_animation.dart:73-102` 的 `ContentEntrance`）。
 *
 * 行为语义逐项对齐：
 * - 时长 400ms（lite 默认 `Duration(milliseconds: 400)`）；
 * - 位移 (0, 0.08)：从自身高度 8% 的下方上浮（lite `offset = Offset(0, 0.08)`）；
 * - 曲线 easeOutCubic（lite 滑动曲线 `Curves.easeOutCubic`；透明度 lite 用
 *   `Curves.easeOut`，native 收敛为同一条 easeOutCubic，登记近似）；
 * - 仅首次：`remember { Animatable }` 随组合实例创建，父组件重组不重播；
 *   挂在 tab `AnimatedContent` 的子项上时，每次切 tab 产生新组合实例 →
 *   重播入场（与 lite「`ContentEntrance(child: page)` 在 `_buildPageForTab`
 *   内、切 tab 重建」的层次感一致：内容上浮 + 页面滑入叠加）。
 *
 * 常量复用 `Md3Motion.DefaultDurationMillis`（400ms）。
 */
@Composable
fun ContentEntrance(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val progress = remember { Animatable(initialValue = 0f) }
    LaunchedEffect(Unit) {
        progress.animateTo(
            targetValue = 1f,
            animationSpec = tween(durationMillis = Md3Motion.DefaultDurationMillis, easing = EaseOutCubic),
        )
    }
    Box(
        modifier = modifier.graphicsLayer {
            alpha = progress.value
            translationY = (1f - progress.value) * size.height * 0.08f
        },
    ) {
        content()
    }
}
