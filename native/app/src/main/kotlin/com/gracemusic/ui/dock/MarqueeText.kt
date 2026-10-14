package com.gracemusic.ui.dock

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text

/**
 * 单行跑马灯文字，1:1 移植 lite `glass_dock_player.dart:767-898`（`_MarqueeText`）。
 *
 * 规格（逐常量对位）：
 * - **仅溢出且播放中才滚动**（lite :845-852）；未溢出 / 暂停时静态显示；
 * - 速度 24px/s（lite `_speed` :799；lite 逻辑像素与 Compose dp 数值等价，
 *   用 [DockLogic.MARQUEE_SPEED_DP_PER_SEC]）；
 * - 双文本间隔 32px 无缝循环（lite `_gap` :796，回卷算术见
 *   [DockLogic.marqueeLoopOffset]）；
 * - 暂停时偏移**归零**（lite :851：`if (!widget.playing && _offset.value != 0)
 *   _offset.value = 0`——注意 lite 类注释 :769 写「保留当前偏移」，但代码
 *   实际是暂停归零，本实现以代码为准；归零发生在停止订阅的效果启动时）。
 *
 * **高频纪律**：滚动偏移由 [PlayerFrameDriver] 帧回调直接写
 * `mutableFloatStateOf`，唯一读取点是 `graphicsLayer` 的 draw 阶段块
 * （`translationX`）——帧步进只失效该层变换、零重组、零重测量。
 *
 * **偏离登记（边缘渐隐）**：任务允许「绘制内 alpha 渐变或简化为无渐变并
 * 登记」；lite :854-885 本就只做 `ClipRect` 硬裁剪、无边缘渐隐，故保持
 * 1:1 采用 `clipToBounds`，不另造渐隐。
 *
 * @param text 展示文本（单行）。
 * @param style 文本样式（Dock 内为 bodyMedium，见 GlassDockPlayer）。
 * @param width 视口宽度（lite :781 `width`，dp）。
 * @param playing 仅 true 且文本溢出时滚动。
 */
@Composable
public fun MarqueeText(
    text: String,
    style: TextStyle,
    width: Dp,
    playing: Boolean,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val textMeasurer: TextMeasurer = rememberTextMeasurer()

    // 文本像素宽（低频测量：仅在 text / style 变化时重测，lite :837 教训同源）
    val textLayoutResult = remember(text, style) {
        textMeasurer.measure(
            text = AnnotatedString(text),
            style = style,
            maxLines = 1,
            softWrap = false,
            overflow = TextOverflow.Visible,
        )
    }
    val textWidthPx: Float = textLayoutResult.size.width.toFloat()
    val viewportPx: Float = with(density) { width.toPx() }
    val overflow: Boolean = textWidthPx > viewportPx

    // 24px/s → px/ms（lite :799 的速度语义；lite 逻辑像素 ≈ Compose dp）
    val speedPxPerMillis: Float = with(density) {
        DockLogic.MARQUEE_SPEED_DP_PER_SEC.dp.toPx() / 1000f
    }

    val driver: PlayerFrameDriver = rememberPlayerFrameDriver()
    var offsetPx by remember { mutableFloatStateOf(0f) }

    DisposableEffect(text, overflow, playing, speedPxPerMillis, textWidthPx) {
        if (overflow && playing) {
            // 帧回调直接写 State，不 setState / 不触发重组（lite :792-793 等价）
            val subscription: Subscription = driver.subscribe { dtMillis ->
                offsetPx = DockLogic.marqueeLoopOffset(offsetPx, dtMillis * speedPxPerMillis, textWidthPx)
            }
            onDispose { subscription.dispose() }
        } else {
            // lite :846-852：解绑节拍；暂停（!playing）时偏移归零
            if (!playing) offsetPx = 0f
            onDispose { }
        }
    }

    if (!overflow) {
        Box(modifier.width(width)) {
            Text(
                text = text,
                style = style,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Ellipsis,
            )
        }
    } else {
        Box(modifier.width(width).clipToBounds()) {
            // wrapContentWidth(unbounded) 让双文本无界测量（不受视口宽约束被压缩），
            // graphicsLayer 的 translationX 在 draw 阶段读 State：帧步进仅失效
            // 该层变换，不重组（见类 KDoc 高频纪律）。
            Row(
                Modifier
                    .wrapContentWidth(align = Alignment.Start, unbounded = true)
                    .graphicsLayer { translationX = -offsetPx },
            ) {
                Text(
                    text = text,
                    style = style,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Visible,
                )
                Spacer(Modifier.width(DockLogic.MARQUEE_GAP_PX.dp))
                Text(
                    text = text,
                    style = style,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Visible,
                )
            }
        }
    }
}
