package com.md3music.md3music

import android.app.Dialog
import android.content.Context
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/**
 * 悬浮识曲「玻璃背板」：一块独立的、不可触摸的透明窗口，只负责
 * **窗口内局部背景模糊**（磨砂玻璃），视觉配方对齐应用内
 * `LiquidGlassSurface`（dock 栏玻璃：BackdropFilter sigma 18 + 叠色 + 描边）。
 *
 * ## 为什么不用 FLAG_BLUR_BEHIND
 *
 * `FLAG_BLUR_BEHIND` 是 `FLAG_DIM_BEHIND` 的模糊版：**无论窗口多小，都会模糊
 * 整块屏幕**（AOSP 文档原文「模糊处理后方屏幕会对窗口后方的整个屏幕进行模糊
 * 处理」）。批次 55 曾用它，用户反馈即「显示悬浮窗时全屏模糊」——这正是该
 * 标志的既定语义，不是配置问题。批次 57 因此移除。
 *
 * 想要「只在玻璃形状内模糊」（与 Dock 的 BackdropFilter 等价），只能用
 * `Window#setBackgroundBlurRadius(int)`：它只模糊窗口边界内的背景，且模糊区
 * 按窗口背景 drawable 的椭圆/圆角轮廓裁剪。而 `WindowManager#addView` 直接
 * 添加的 overlay 视图没有 `Window` 对象，所以借一个 `Dialog` 的 Window。
 *
 * ## 层次
 *
 * 本背板必须在内容窗口**之前** addView：同 type 下先加入者在下层。背板自身
 * 叠色近乎全透明（[PLATE_TINT_ALPHA]），即使个别 ROM 反序把背板压到内容之上，
 * 也不会影响内容可读性。
 *
 * ## 坐标系
 *
 * 背板窗口与内容窗口同为 `TYPE_APPLICATION_OVERLAY` + `FLAG_LAYOUT_IN_SCREEN`
 * + `Gravity.TOP|START`，两者的 x/y 基准一致，因此背板位置 = 内容窗口
 * `params.x/y` + 目标视图在窗口内的偏移（由调用方测量后传入）。
 */
internal class RecognitionGlassBackdrop(private val context: Context) {

    companion object {
        private const val TAG = "RecognitionBackdrop"

        /** 模糊强度：dock 玻璃 BackdropFilter sigma = 18（逻辑像素），此处按 dp 折算。 */
        const val BLUR_SIGMA_DP = 18

        /** 背板叠色 α（≈3%）：仅作模糊区极淡 token 着色，玻璃主色由内容窗口承担。 */
        const val PLATE_TINT_ALPHA = 0x08

        fun plateTint(base: Int): Int = (PLATE_TINT_ALPHA shl 24) or (base and 0x00FFFFFF)
    }

    private var dialog: Dialog? = null
    private var plate: GradientDrawable? = null

    private var oval = true
    private var cornerPx = 0
    private var tintColor = Int.MIN_VALUE

    private val density = context.resources.displayMetrics.density

    private fun dp(v: Int): Int = (v * density).toInt()

    /**
     * 建立并显示背板窗口（**必须早于内容窗口 addView**）。
     *
     * 初始为 1×1 的空窗口：窗口一旦加入就不再移除/重加（重加会跑到内容之上），
     * 之后只通过 [place] 改尺寸与位置、[collapse] 收敛到 1×1 隐藏。
     *
     * @return 是否可用（API < 31 或该 ROM 拒绝跨窗口模糊时 false）
     */
    fun ensure(): Boolean {
        if (dialog != null) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            val d = Dialog(context, R.style.RecognitionBackdropTheme)
            val w = d.window ?: return false
            w.setType(overlayWindowType())

            val lp = w.attributes
            lp.gravity = Gravity.TOP or Gravity.START
            lp.format = PixelFormat.TRANSLUCENT
            lp.dimAmount = 0f
            lp.width = 1
            lp.height = 1
            lp.x = 0
            lp.y = 0
            // 只保留「不可触摸 / 不可聚焦」与「按整屏基准布局」（与内容窗口同基准），
            // 清掉主题可能带入的 dim / blur-behind / 浮动定位标志。
            val drop = WindowManager.LayoutParams.FLAG_DIM_BEHIND or
                    WindowManager.LayoutParams.FLAG_BLUR_BEHIND or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                    WindowManager.LayoutParams.FLAG_LAYOUT_INSET_DECOR
            lp.flags = (lp.flags and drop.inv()) or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
            w.attributes = lp

            val gd = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0)
            }
            plate = gd
            w.setBackgroundDrawable(gd)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                w.setBackgroundBlurRadius(dp(BLUR_SIGMA_DP))
            }

            d.setContentView(View(context))
            d.setCancelable(false)
            d.setCanceledOnTouchOutside(false)
            d.show()

            // show() 后部分 ROM 会重写 layout params，这里再压一次 1×1
            val after = w.attributes
            after.width = 1
            after.height = 1
            w.attributes = after

            dialog = d
            Log.i(TAG, "backdrop ready, blurRadius=${dp(BLUR_SIGMA_DP)}px")
            true
        } catch (e: Exception) {
            Log.e(TAG, "ensure failed", e)
            try {
                dialog?.dismiss()
            } catch (_: Exception) {
            }
            dialog = null
            plate = null
            false
        }
    }

    /**
     * 形状 + 叠色。仅在参数变化时重挂背景 drawable——模糊区域跟随背景轮廓裁剪，
     * 变形必须重挂才能让模糊区同步变形。
     */
    fun setPlate(tint: Int, oval: Boolean, cornerPx: Int) {
        val w = dialog?.window ?: return
        val gd = plate ?: return
        if (this.oval == oval && this.cornerPx == cornerPx && tintColor == tint) return
        this.oval = oval
        this.cornerPx = cornerPx
        tintColor = tint
        gd.shape = if (oval) GradientDrawable.OVAL else GradientDrawable.RECTANGLE
        gd.cornerRadius = if (oval) 0f else cornerPx.toFloat()
        gd.setColor(tint)
        w.setBackgroundDrawable(gd)
    }

    /** 摆放背板（屏幕坐标，px），宽高为目标玻璃形状的实测尺寸。 */
    fun place(x: Int, y: Int, width: Int, height: Int) {
        val w = dialog?.window ?: return
        if (width <= 0 || height <= 0) return
        val lp = w.attributes
        if (lp.x == x && lp.y == y && lp.width == width && lp.height == height) return
        lp.x = x
        lp.y = y
        lp.width = width
        lp.height = height
        w.attributes = lp
    }

    /** 收敛为 1×1（不可见），窗口保留以维持层次。 */
    fun collapse() {
        val w = dialog?.window ?: return
        val lp = w.attributes
        if (lp.width == 1 && lp.height == 1) return
        lp.width = 1
        lp.height = 1
        w.attributes = lp
    }

    fun release() {
        try {
            dialog?.dismiss()
        } catch (_: Exception) {
        }
        dialog = null
        plate = null
        tintColor = Int.MIN_VALUE
    }

    private fun overlayWindowType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
}
