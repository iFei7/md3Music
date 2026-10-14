package com.gracemusic.ui.dock

import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color.Companion.Transparent
import androidx.compose.ui.graphics.Color.Companion.White
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp

/**
 * 液态玻璃容器（悬浮 Dock 底座），1:1 移植 lite
 * `lib/core/widgets/liquid_glass_container.dart`。
 *
 * 视觉分层（自下而上，对位 lite :8-15 类注释）：
 * 1. **模糊层**：σ18（lite `blurSigma = 18`，:34）——**偏离登记**：Flutter
 *    `BackdropFilter` 采样的是组件背后的内容，而 Compose **没有公开的
 *    backdrop-blur API**（真 backdrop 需第三方库如 Haze，ECC 红线禁新增
 *    依赖）。此处 `BlurEffect` 作用于**容器自身层**：叠色 + 顶部高光
 *    渐变被 σ18 晕开形成柔和玻璃反光，描边与内容保持锐利，近似玻璃质感。
 *    **API < 31 降级**：`RenderEffect` 不可用，直接跳过该修饰符，容器退化为
 *    半透明叠色 + 渐变描边（视觉完整、不崩溃）。
 * 2. 半透明 surface 叠色 α0.12（lite `fillAlpha = 0.12`，:35）；
 * 3. 1px 渐变描边：左上 white α0.35 → 右下 onSurface α0.06
 *    （lite `_GlassBorderPainter` :165-178）；
 * 4. 顶部内侧高光线 white α0.28 左右渐隐（lite :189-211）。
 *
 * **胶囊圆角 = 实际渲染高度 / 2**（lite `_StadiumClipper` :126-137）：用
 * 自定义 [Shape] 在布局完成后按真实 `size.height / 2` 取半径（[StadiumShape]），
 * 不用 `RoundedCornerShape(percent)`（其 x/y 半径分别按宽/高百分比计算，
 * 宽 > 高时得到椭圆角，非 Stadium）也不用约束 `maxHeight`（Dock 场景
 * Row loose 约束下高度无界，`circular(∞)` 会退化矩形裁剪——lite :56-63
 * 装机实测 bug）。
 *
 * **静态组件、零内部动画**（lite :22-23 教训）：所有动效（展开/坍缩/形变）
 * 由外层 [GlassDockPlayer] 用收敛型动画驱动，本组件只负责一次绘制。
 *
 * @param shape 外形（胶囊 / 圆形 / 圆角矩形）。
 * @param cornerRadius 仅 [GlassShape.ROUNDED_RECT] 时生效的圆角。
 * @param padding 内容内边距。
 * @param blurSigma 模糊强度（仅 API 31+ 生效）。
 * @param fillAlpha 叠色不透明度（0.10–0.15 推荐区间）。
 */
@Composable
public fun LiquidGlassContainer(
    modifier: Modifier = Modifier,
    shape: GlassShape = GlassShape.PILL,
    cornerRadius: Dp = 0.dp,
    padding: PaddingValues = PaddingValues(0.dp),
    blurSigma: Float = DEFAULT_BLUR_SIGMA,
    fillAlpha: Float = DEFAULT_FILL_ALPHA,
    content: @Composable BoxScope.() -> Unit,
) {
    val colorScheme: ColorScheme = MaterialTheme.colorScheme
    val clipShape: Shape = remember(shape, cornerRadius) { glassShapeOf(shape, cornerRadius) }

    Box(modifier = modifier.clip(clipShape)) {
        // 层 1+2：模糊层（叠色 + 顶部高光渐变，供 σ18 晕开）。
        // API < 31：RenderEffect 不可用，跳过模糊修饰符——半透明叠色 +
        // 描边仍完整呈现，降级路径不崩溃（见类 KDoc 偏离登记）。
        Box(
            modifier = Modifier
                .matchParentSize()
                .then(
                    if (Build.VERSION.SDK_INT >= 31) {
                        Modifier.graphicsLayer {
                            // compose 1.11 顶层工厂：BlurEffect(σx, σy, TileMode)，
                            // 底层即 android.graphics.RenderEffect.createBlurEffect
                            renderEffect = BlurEffect(
                                radiusX = blurSigma,
                                radiusY = blurSigma,
                                edgeTreatment = TileMode.Clamp,
                            )
                        }
                    } else {
                        Modifier
                    },
                )
                .background(colorScheme.surface.copy(alpha = fillAlpha))
                .drawTopHighlightGlow(),
        )
        // 层 3+4：1px 渐变描边 + 顶部内侧高光线（锐利，不参与模糊）。
        Canvas(modifier = Modifier.matchParentSize()) {
            drawGlassBorder(
                colorScheme = colorScheme,
                shape = shape,
                cornerRadiusPx = cornerRadius.toPx(),
            )
        }
        // 内容（决定容器尺寸的非定位层，对位 lite Stack 的 Padding child）。
        Box(modifier = Modifier.padding(padding)) {
            content()
        }
    }
}

/** 玻璃容器外形（lite `GlassShape`，liquid_glass_container.dart:122）。 */
public enum class GlassShape {
    /** 胶囊（Stadium：圆角 = 实际渲染高度 / 2）。 */
    PILL,

    /** 正圆。 */
    CIRCLE,

    /** 圆角矩形（圆角 = [LiquidGlassContainer] 的 cornerRadius）。 */
    ROUNDED_RECT,
}

/** 默认模糊强度（lite `blurSigma = 18`，liquid_glass_container.dart:34）。 */
public const val DEFAULT_BLUR_SIGMA: Float = 18f

/** 默认叠色不透明度（lite `fillAlpha = 0.12`，liquid_glass_container.dart:35）。 */
public const val DEFAULT_FILL_ALPHA: Float = 0.12f

/** 按外形产出裁剪 Shape。 */
private fun glassShapeOf(shape: GlassShape, cornerRadius: Dp): Shape = when (shape) {
    GlassShape.PILL -> StadiumShape
    GlassShape.CIRCLE -> CircleShape
    GlassShape.ROUNDED_RECT -> RoundedCornerShape(cornerRadius)
}

/**
 * Stadium 裁剪 Shape：圆角半径 = **实际渲染尺寸的高度 / 2**（lite
 * `_StadiumClipper` :126-137），按布局完成后的真实 size 计算，
 * 无界高度约束下也不退化。
 */
private object StadiumShape : Shape {
    override fun createOutline(
        size: Size,
        layoutDirection: LayoutDirection,
        density: Density,
    ): Outline = Outline.Rounded(
        RoundRect(
            0f,
            0f,
            size.width,
            size.height,
            CornerRadius(size.height / 2f),
        ),
    )
}

/**
 * 顶部高光渐变底（供模糊层晕开成玻璃反光）。这是对 lite「顶部内侧高光线」
 * 的模糊层补充：锐利的高光线由 [drawGlassBorder] 绘制，此处仅提供集中在
 * 顶部约 35% 高度内渐隐的柔和反光底。
 */
private fun Modifier.drawTopHighlightGlow(): Modifier = this.drawBehind {
    drawRect(
        brush = Brush.verticalGradient(
            colors = listOf(
                White.copy(alpha = 0.28f),
                Transparent,
            ),
            startY = 0f,
            endY = size.height * 0.35f,
        ),
    )
}

/**
 * 玻璃描边绘制器，1:1 移植 lite `_GlassBorderPainter.paint`（:158-212）：
 * - 外缘 1px 线性渐变描边（左上 white α0.35 → 右下 onSurface α0.06）；
 * - 顶部内侧高光线（上缘 1px 细线，左右向内收进后渐隐）。
 */
private fun DrawScope.drawGlassBorder(
    colorScheme: ColorScheme,
    shape: GlassShape,
    cornerRadiusPx: Float,
) {
    val cornerRadius: Float = when (shape) {
        GlassShape.PILL, GlassShape.CIRCLE -> size.height / 2f
        GlassShape.ROUNDED_RECT -> cornerRadiusPx
    }
    val strokeWidth = 1.dp.toPx()

    // 渐变描边：左上白高光 → 右下渐隐（混入 onSurface 保证暗色主题可感知）
    val borderBrush = Brush.linearGradient(
        colors = listOf(
            White.copy(alpha = 0.35f),
            colorScheme.onSurface.copy(alpha = 0.06f),
        ),
        start = Offset.Zero,
        end = Offset(size.width, size.height),
    )
    val inset = strokeWidth / 2f
    drawRoundRect(
        brush = borderBrush,
        topLeft = Offset(inset, inset),
        size = Size(size.width - strokeWidth, size.height - strokeWidth),
        cornerRadius = CornerRadius((cornerRadius - inset).coerceAtLeast(0f)),
        style = Stroke(width = strokeWidth),
    )

    // 顶部内侧高光线：上缘 1px 细线，左右向内收进后渐隐（lite :189-211）
    val highlightInset: Float = if (shape == GlassShape.CIRCLE) size.width / 4f else cornerRadius * 0.8f
    val highlightBrush = Brush.horizontalGradient(
        colors = listOf(
            Transparent,
            White.copy(alpha = 0.28f),
            Transparent,
        ),
        startX = 0f,
        endX = size.width,
    )
    drawLine(
        brush = highlightBrush,
        start = Offset(highlightInset, 1f),
        end = Offset(size.width - highlightInset, 1f),
        strokeWidth = strokeWidth,
        cap = StrokeCap.Butt,
    )
}
