package com.md3music.md3music

import android.animation.ValueAnimator
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 悬浮窗听歌识曲服务。
 *
 * 悬浮窗按钮点击「识别」→ 回调 Dart 发起 MediaProjection 授权（MainActivity）→
 * 授权成功后本服务用 AudioPlaybackCapture 采集系统音频（8000Hz/16bit/mono），
 * 每 8s 一段把 PCM 回调 Dart → Dart 复用酷狗指纹识曲链路识别 → 命中后回传
 * 结果在此悬浮窗显示封面/歌名/歌手 + 播放按钮。
 *
 * 采集循环由 Dart 侧控制：每段完成后本服务阻塞等待 `continueCapture` /
 * `stopCapture`，避免原生侧自行决定重试次数。
 *
 * 视觉：透明玻璃材质 —— 磨砂模糊由独立的 [RecognitionGlassBackdrop] 窗口提供
 * （`Window#setBackgroundBlurRadius` 的窗口内局部模糊，σ 对齐 dock 栏
 * `LiquidGlassSurface` 的 18），内容窗口只叠加低 α 莫奈 token 叠色 + 描边 +
 * elevation 投影；模糊不可用的机型自动回退到实心档叠色。
 * 折叠态为应用图标玻璃圆钮，聆听/识别中带波纹扩散，结果态为胶囊玻璃面板。
 */
class FloatingRecognitionService : Service() {

    companion object {
        const val TAG = "FloatingRecognition"
        const val CHANNEL_ID = "floating_recognition_channel"
        const val NOTIFICATION_ID = 2001
        const val ACTION_START = "com.md3music.md3music.RECOG_START"
        const val ACTION_STOP = "com.md3music.md3music.RECOG_STOP"
        const val ACTION_CONTINUE = "com.md3music.md3music.RECOG_CONTINUE"
        const val ACTION_STOP_CAPTURE = "com.md3music.md3music.RECOG_STOP_CAPTURE"
        const val ACTION_SET_RESULT = "com.md3music.md3music.RECOG_SET_RESULT"
        const val ACTION_SET_STATUS = "com.md3music.md3music.RECOG_SET_STATUS"
        const val ACTION_SET_THEME = "com.md3music.md3music.RECOG_SET_THEME"
        const val EXTRA_RESULT = "result"
        const val EXTRA_STATUS = "status"
        const val EXTRA_THEME_COLORS = "themeColors"
        const val DART_CHANNEL = "com.md3music.md3music/floating_recognition"

        // 采集参数：8000Hz / 16bit / mono，6s = 96KB（首响延迟：8s→6s）
        const val SAMPLE_RATE = 8000
        const val SEGMENT_BYTES = SAMPLE_RATE * 2 * 6

        // 静音段提前中断（与 Dart 侧 kSilenceAmplitudeThreshold=30 同口径，
        // 16-bit PCM 峰值振幅）：连续 2s 峰值 <30 即提前结束当前段。
        // 至少采集满 2s 后才开始累计判定，避免把起播瞬间静音误判。
        private const val SILENCE_AMPLITUDE_THRESHOLD = 30
        private const val SILENCE_WINDOW_BYTES = SAMPLE_RATE * 2 * 2   // 连续静音 2s
        private const val SILENCE_GRACE_BYTES = SAMPLE_RATE * 2 * 2    // 段首豁免 2s

        // 波纹扩散：1200~1600ms 循环，取 1400ms
        private const val RIPPLE_DURATION_MS = 1400L
        // 识别中图标呼吸缩放：0.94 ↔ 1.06，单程 700ms（全程 1400ms）
        private const val BREATHE_DURATION_MS = 700L

        // 玻璃叠色 α（模糊可用时）：对齐 dock 玻璃 LiquidGlassSurface 的
        // fillAlpha 0.12——模糊负责消解背景细节，叠色只做主题着色。
        // 圆钮 0x1F（12%）、结果面板 0x2E（18%，承载文字读性略高）。
        private const val GLASS_ALPHA_BLUR = 0x1F
        private const val GLASS_ALPHA_PANEL_BLUR = 0x2E
        // 模糊不可用时的实心档 α（原视觉，保证无模糊机型可读）
        private const val GLASS_ALPHA_SOLID_DARK = 0xB3
        private const val GLASS_ALPHA_SOLID_LIGHT = 0x99

        // 面板歌名/歌手最大宽度：130dp（批次 57 口径；18sp 实验档的 150dp 随
        // 字号回退一并撤销，恢复紧凑面板宽度）。
        private const val TEXT_MAX_WIDTH_DP = 130

        // 状态
        const val STATE_IDLE = 0
        const val STATE_LISTENING = 1
        const val STATE_RECOGNIZING = 2
        const val STATE_RESULT = 3

        @Volatile
        private var instance: FloatingRecognitionService? = null

        /** 服务是否正在运行（MainActivity 用于避免误 startService 复活已停止的服务） */
        fun isRunning(): Boolean = instance != null

        /** MainActivity 授权完成后注入 MediaProjection token（静态转发到服务实例） */
        fun onProjectionResult(resultCode: Int, data: Intent?) {
            instance?.handleProjectionResult(resultCode, data)
        }
    }

    private var windowManager: WindowManager? = null
    private var rootView: LinearLayout? = null

    // 折叠态：玻璃圆钮 + 波纹层 + 应用图标
    private var micWrap: FrameLayout? = null
    private var micButton: FrameLayout? = null
    private var appIcon: ImageView? = null
    private var rippleView: RippleRingView? = null

    // 结果态：胶囊玻璃面板（封面 + 歌名/歌手 + 播放/关闭）
    private var resultPanel: LinearLayout? = null
    private var coverImage: ImageView? = null
    private var songNameText: TextView? = null
    private var artistText: TextView? = null
    private var params: WindowManager.LayoutParams? = null

    // 玻璃背板（窗口内局部模糊）：圆钮一块、结果面板一块，各自形状固定，
    // 均在内容窗口之前加入（同 type 下先加入者在下层）。
    private var micPlate: RecognitionGlassBackdrop? = null
    private var panelPlate: RecognitionGlassBackdrop? = null
    /** 跨窗口模糊当前是否可用（API 31+ 且系统未因省电/GPU 限制关闭）。 */
    private var blurActive = false
    private var blurListener: java.util.function.Consumer<Boolean>? = null
    // 目标视图相对窗口原点的偏移（px）：由布局回调测量，拖动时用 params + 偏移
    // 直接摆位，避免 getLocationOnScreen 在窗口移动后滞后一帧导致背板抖动。
    private var micPlateDx = 0
    private var micPlateDy = 0
    private var panelPlateDx = 0
    private var panelPlateDy = 0
    private var lastLoggedPlateOffsets = ""

    // 底部"拖到这里关闭"区域（独立 overlay，不可触摸）
    private var closeZoneView: View? = null
    private var closeZoneIcon: ImageView? = null
    private var closeZoneParams: WindowManager.LayoutParams? = null
    private var isOverCloseZone = false

    // touch/drag — 全方向拖动
    private var initialX = 0
    private var initialY = 0
    private var initialTouchX = 0f
    private var initialTouchY = 0f
    private var isDragging = false
    private var dragStartTime = 0L

    // 状态机
    private var state = STATE_IDLE
    private var pendingCapture = false // 等待投影授权

    // 采集资源
    private var projectionResultCode = 0
    private var projectionData: Intent? = null
    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    @Volatile
    private var captureThread: Thread? = null
    private val captureLock = Object()
    @Volatile
    private var stopRequested = false
    private var continueAllowed = false

    // 聆听/识别中动效：波纹扩散 + 图标呼吸缩放（替代原音符旋转）
    private var rippleAnimator: ValueAnimator? = null
    private var breatheAnimator: ValueAnimator? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var captureReleased = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        // 先以 specialUse 类型启动前台服务（仅悬浮窗，不要求 MediaProjection 授权）。
        // Android 14+ 若在授权前就以 mediaProjection 类型 startForeground，系统会检查
        // PROJECT_MEDIA 权限——该权限须经 createScreenCaptureIntent 授权后才授予，
        // 未授权时 Android 15+ 直接抛 SecurityException（"Starting FGS with type
        // mediaProjection ... requires permissions ... PROJECT_MEDIA"）。
        // 授权成功后由 promoteToMediaProjectionType() 切换为 mediaProjection 类型。
        // Android 10~13 无此检查，可直接以 mediaProjection 类型启动。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                createNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                createNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, createNotification())
        }
        // 背板必须先于内容窗口建立：同 type 下先加入的窗口在下层，
        // 否则模糊背板会压在内容（文字/图标）之上。
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        setupGlassBackdrop()
        createFloatingView()
        createCloseZone()
    }

    // ===================== 玻璃背板（窗口内局部模糊） =====================

    /// 建立磨砂玻璃背板窗口 + 订阅系统跨窗口模糊开关。
    ///
    /// 只在 API 31+ 且系统当前允许跨窗口模糊时建立；建立失败或模糊被
    /// 系统关闭（省电模式/GPU 限制/开发者选项）时不建窗口，玻璃自动
    /// 回退到实心档叠色（见 [defaultGlassAlpha]），不会出现「透明但没模糊」。
    private fun setupGlassBackdrop() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val wm = windowManager ?: return
        blurActive = wm.isCrossWindowBlurEnabled
        if (!blurActive) return
        val mic = RecognitionGlassBackdrop(this)
        if (!mic.ensure()) return
        val panel = RecognitionGlassBackdrop(this)
        if (!panel.ensure()) {
            mic.release()
            return
        }
        micPlate = mic
        panelPlate = panel
        // 系统可在运行时开关模糊（省电模式等）：跟随切换叠色档位与背板显隐
        try {
            val listener = java.util.function.Consumer<Boolean> { enabled ->
                onCrossWindowBlurChanged(enabled)
            }
            blurListener = listener
            wm.addCrossWindowBlurEnabledListener(listener)
        } catch (e: Exception) {
            Log.w(TAG, "addCrossWindowBlurEnabledListener failed", e)
        }
    }

    private fun onCrossWindowBlurChanged(enabled: Boolean) {
        if (blurActive == enabled) return
        blurActive = enabled
        Log.i(TAG, "cross-window blur enabled=$enabled")
        updateUi()
        syncBackdrop()
    }

    /// 背板跟随内容窗口：位置 = 内容窗口 params + 视图在窗口内的偏移，
    /// 形状/叠色按当前状态刷新。模糊不可用或目标视图未测量时收敛隐藏。
    private fun syncBackdrop() {
        val p = params
        val btn = micButton
        val panel = resultPanel
        val mic = micPlate
        val pan = panelPlate
        if (p == null || !blurActive) {
            mic?.collapse()
            pan?.collapse()
            return
        }
        if (mic != null && btn != null && btn.width > 0 && btn.height > 0) {
            mic.setPlate(RecognitionGlassBackdrop.plateTint(stateGlassBase()), oval = true, cornerPx = 0)
            mic.place(p.x + micPlateDx, p.y + micPlateDy, btn.width, btn.height)
        } else {
            mic?.collapse()
        }
        if (pan != null && panel != null && state == STATE_RESULT &&
            panel.visibility == View.VISIBLE && panel.width > 0 && panel.height > 0
        ) {
            pan.setPlate(
                RecognitionGlassBackdrop.plateTint(cPanelBg),
                oval = false,
                cornerPx = dp(24)
            )
            pan.place(p.x + panelPlateDx, p.y + panelPlateDy, panel.width, panel.height)
        } else {
            pan?.collapse()
        }
    }

    /// 测量目标视图相对窗口原点的偏移（布局完成后调用）。
    private fun captureBackdropOffsets() {
        val p = params ?: return
        val loc = IntArray(2)
        micButton?.let {
            if (it.width > 0) {
                it.getLocationOnScreen(loc)
                micPlateDx = loc[0] - p.x
                micPlateDy = loc[1] - p.y
            }
        }
        resultPanel?.let {
            if (it.width > 0) {
                it.getLocationOnScreen(loc)
                panelPlateDx = loc[0] - p.x
                panelPlateDy = loc[1] - p.y
            }
        }
        // 诊断：偏移 = 视图在窗口内的位置（内容窗口与背板同基准时为正的小值）。
        // 若某 ROM 对 overlay 施加额外内缩，这里的值会明显异常，可据此判断背板错位原因。
        val sig = "$micPlateDx,$micPlateDy/$panelPlateDx,$panelPlateDy"
        if (sig != lastLoggedPlateOffsets) {
            lastLoggedPlateOffsets = sig
            Log.i(TAG, "backdrop offsets (mic/panel) = $sig")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> requestRecognition()
            ACTION_CONTINUE -> requestContinueCapture()
            ACTION_STOP_CAPTURE -> stopCapture()
            ACTION_SET_RESULT -> showResult(intent.getStringExtra(EXTRA_RESULT) ?: "")
            ACTION_SET_STATUS -> showStatus(intent.getStringExtra(EXTRA_STATUS) ?: "")
            ACTION_SET_THEME -> setThemeColors(intent)
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_STICKY
    }

    // ===================== 悬浮窗 UI（MD3E 玻璃设计语言） =====================
    //
    // 玻璃材质：磨砂模糊来自独立的 [RecognitionGlassBackdrop] 窗口（窗口内局部
    // 背景模糊，σ=18dp 对齐 dock 玻璃），本窗口只叠加低 α 莫奈取色底（模糊可用
    // 12%~18%，不可用回实心 60%~70%）+ 1dp 主题主色 α60% 细描边 + 7dp elevation
    // 投影；**不使用 FLAG_BLUR_BEHIND**（该标志会模糊整块屏幕）。
    // 玻璃底色全部从 Dart 推送的 11 色 token（setThemeColors）派生 α 变体，
    // 按亮度自适应深/浅玻璃，不写死与主题无关的固定色。
    // 折叠态：52dp 圆形玻璃钮，内部为应用 launcher 图标（monochrome 资源 + tint）。
    // 聆听/识别中：外圈波纹扩散（主题主色 α 渐隐），识别中加图标呼吸缩放。
    // 结果态：24dp 圆角胶囊玻璃面板（封面 + 歌名/歌手 + 播放/关闭）。
    // 关闭区：玻璃底，拖入反馈为淡红底 + 红描边。

    // 主题色：默认 MD3E 深色 token，Dart 侧推送设置页莫奈/动态取色（setThemeColors）后覆盖。
    // 悬浮窗 UI 全部使用以下字段派生玻璃配色，保证与 App 主题一致。
    private var cBtnIdleBg = 0xFF26242B.toInt()
    private var cOnSurface = 0xFFE6E0E9.toInt()
    private var cOnSurfaceVariant = 0xFFCAC4D0.toInt()
    private var cListeningBg = 0xFFD0BCFF.toInt()   // token: primary
    private var cListeningIcon = 0xFF381E72.toInt() // token: onPrimary
    private var cRecognizingBg = 0xFFEFB8C8.toInt()   // token: tertiary
    private var cRecognizingIcon = 0xFF492532.toInt() // token: onTertiary
    private var cResultBg = 0xFFEADDFF.toInt()           // token: primaryContainer
    private var cResultIcon = 0xFF21005D.toInt()         // token: onPrimaryContainer
    private var cPanelBg = 0xFF1D1B20.toInt()          // token: surfaceContainer
    private var cPanelStroke = 0x4049454F.toInt()      // token: outlineVariant（保留字段，兼容旧契约）

    // 关闭区危险反馈：MD3E error token（仅关闭区使用，垃圾桶图标保持红色）
    private val cErrorIcon = 0xFFFFB4AB.toInt()
    private val cErrorDeep = 0xFFB3261E.toInt()

    // 面板/按钮背景引用：setThemeColors 时刷新
    private var micBtnGd: GradientDrawable? = null
    private var panelGd: GradientDrawable? = null
    private var coverBgGd: GradientDrawable? = null
    private var playBtnBgGd: GradientDrawable? = null
    private var closeZoneGd: GradientDrawable? = null

    private fun createFloatingView() {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        rootView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        val root = rootView as LinearLayout

        // 折叠态容器：波纹层 + 52dp 玻璃圆钮（对齐应用内悬浮播放器球，波纹在钮外圈扩散）
        micWrap = FrameLayout(this).apply {
            val s = dp(76)
            layoutParams = LinearLayout.LayoutParams(s, s)
        }
        val wrap = micWrap as FrameLayout

        rippleView = RippleRingView(this).apply {
            layoutParams = FrameLayout.LayoutParams(dp(76), dp(76))
            visibility = View.GONE
        }
        wrap.addView(rippleView)

        micButton = FrameLayout(this).apply {
            val size = dp(52)
            layoutParams = FrameLayout.LayoutParams(size, size, Gravity.CENTER)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(glassColor(cBtnIdleBg))
                setStroke(dp(1), primaryStroke())
            }.also { micBtnGd = it }
            elevation = dp(7).toFloat()
        }
        val btn = micButton as FrameLayout

        appIcon = ImageView(this).apply {
            // 应用 launcher 图标（monochrome 资源：纯黑图案+全透明背景），
            // tint 按玻璃底亮度取黑/白保证可见
            setImageResource(R.drawable.ic_launcher_monochrome)
            setColorFilter(idleIconTint())
            layoutParams = FrameLayout.LayoutParams(dp(23), dp(23), Gravity.CENTER)
        }
        btn.addView(appIcon)
        wrap.addView(btn)
        root.addView(micWrap)

        // 结果态：24dp 圆角胶囊玻璃面板（封面 + 歌名/歌手 + 播放/关闭圆钮）
        resultPanel = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            visibility = View.GONE
            alpha = 0f
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24).toFloat()
                setColor(glassColor(cPanelBg, panelGlassAlpha()))
                setStroke(dp(1), primaryStroke())
            }.also { panelGd = it }
            setPadding(dp(10), dp(8), dp(8), dp(8))
            elevation = dp(7).toFloat()
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(10) }
        }
        val panel = resultPanel as LinearLayout

        // 歌曲封面：imgurl 异步加载，无 url / 加载失败时用应用图标占位
        coverImage = ImageView(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(40), dp(40))
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(9).toFloat()
                setColor(glassColor(cBtnIdleBg))
            }.also { coverBgGd = it }
            clipToOutline = true
            visibility = View.GONE
        }
        panel.addView(coverImage)

        // 歌名/歌手：点击文字直接播放（不触发 rootView 的收起/拖动逻辑）
        val textCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(dp(8), 0, dp(4), 0) }
        }
        // 歌名/歌手字号（批次58 修正）：播放页 18sp 标题是全屏大封面排版口径，
        // 搬进悬浮胶囊会因 maxWidth 截断到 7~8 字而不可读（真机反馈）。
        // 回退到批次 57 口径：歌名 sp11 粗体 / 歌手 sp9.5，宽 130dp——
        // 该档用户未提出过可读性问题；磨砂模糊与玻璃配色改动全部保留。
        songNameText = TextView(this).apply {
            setTextColor(cOnSurface)
            textSize = sp(11f)
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            maxWidth = dp(TEXT_MAX_WIDTH_DP)
            gravity = Gravity.CENTER_VERTICAL
            setOnClickListener { sendToDart("onFloatingAction", "play") }
        }
        artistText = TextView(this).apply {
            setTextColor(cOnSurfaceVariant)
            textSize = sp(9.5f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            maxWidth = dp(TEXT_MAX_WIDTH_DP)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(2), 0, 0)
            setOnClickListener { sendToDart("onFloatingAction", "play") }
        }
        textCol.addView(songNameText)
        textCol.addView(artistText)
        panel.addView(textCol)

        // 播放/关闭：36dp 玻璃圆钮（makeCircleIconButton 仅结果面板两枚钮使用）
        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(dp(6), 0, 0, 0) }
        }
        val playBtn = makeCircleIconButton(android.R.drawable.ic_media_play, glassColor(cResultBg), cResultIcon) {
            sendToDart("onFloatingAction", "play")
        }
        (playBtn.background as? GradientDrawable)?.let { playBtnBgGd = it }
        val closeBtn = makeCircleIconButton(
            android.R.drawable.ic_menu_close_clear_cancel,
            glassColor(cBtnIdleBg),
            cOnSurfaceVariant
        ) {
            dismissResult()
        }
        val rowLp = LinearLayout.LayoutParams(dp(36), dp(36))
        rowLp.setMargins(dp(6), 0, dp(6), 0)
        buttonRow.addView(playBtn, rowLp)
        buttonRow.addView(closeBtn, LinearLayout.LayoutParams(dp(36), dp(36)))
        panel.addView(buttonRow)

        root.addView(resultPanel)

        setupTouchListener(root)

        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            layoutType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    // 与玻璃背板窗口同基准（整屏原点）：背板位置 = params + 视图偏移，
                    // 两者都按 FLAG_LAYOUT_IN_SCREEN 定位，避免状态栏内缩造成错位。
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = dp(120)
            applyGlassBlur(this)
        }

        // 布局完成后测量背板偏移并摆位：面板显示/隐藏、内容变化都会触发重排。
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            captureBackdropOffsets()
            syncBackdrop()
        }

        windowManager?.addView(rootView, params)
    }

    /// MD3E 圆形图标按钮（全圆玻璃形状，可配置底色/图标色/尺寸）
    private fun makeCircleIconButton(
        resId: Int,
        bgColor: Int,
        iconColor: Int,
        onClick: () -> Unit
    ): ImageView {
        return ImageView(this).apply {
            setImageResource(resId)
            setColorFilter(iconColor)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(bgColor)
            }
            setPadding(dp(9), dp(9), dp(9), dp(9))
            setOnClickListener { onClick() }
        }
    }

    // ===================== 玻璃材质 helper =====================

    /// 玻璃底色：保留 token RGB，α 分两档——
    /// - 模糊可用（[blurActive]，背板窗口提供 dock 同档磨砂）：低 α（圆钮 12%），
    ///   细节由模糊消解，叠色只做主题着色；
    /// - 模糊不可用：回实心档，深色玻璃 70%（0xB3）/ 浅色玻璃 60%（0x99），
    ///   保证透明底上的文字/图标可读（AOSP 对「模糊被关闭时提高底色 α」的建议）。
    /// 必须由 Dart 推送的主题 token 派生，不写死与主题无关的固定色。
    private fun glassColor(base: Int, alpha: Int = defaultGlassAlpha(base)): Int =
        (alpha shl 24) or (base and 0x00FFFFFF)

    private fun defaultGlassAlpha(base: Int): Int = when {
        blurActive -> GLASS_ALPHA_BLUR
        isDarkColor(base) -> GLASS_ALPHA_SOLID_DARK
        else -> GLASS_ALPHA_SOLID_LIGHT
    }

    /// 结果面板叠色 α：承载文字，模糊档比圆钮上浮到 18%（0x2E）保证读性。
    private fun panelGlassAlpha(): Int = when {
        blurActive -> GLASS_ALPHA_PANEL_BLUR
        isDarkColor(cPanelBg) -> GLASS_ALPHA_SOLID_DARK
        else -> GLASS_ALPHA_SOLID_LIGHT
    }

    /// 主题主色（token: primary → cListeningBg）α60% 细描边
    private fun primaryStroke(): Int = (0x99 shl 24) or (cListeningBg and 0x00FFFFFF)

    /// 玻璃底亮度判断（0~255 加权亮度）
    private fun isDarkColor(c: Int): Boolean {
        val r = (c shr 16) and 0xFF
        val g = (c shr 8) and 0xFF
        val b = c and 0xFF
        return (0.299 * r + 0.587 * g + 0.114 * b) < 128.0
    }

    /// 折叠钮图标 tint：按玻璃底亮度取黑/白（玻璃底为 surface token 派生半透明）
    private fun idleIconTint(): Int =
        if (isDarkColor(glassColor(cBtnIdleBg))) Color.WHITE else Color.BLACK

    /// 显式清除 FLAG_BLUR_BEHIND：该标志等价于「模糊版 FLAG_DIM_BEHIND」，
    /// 无论窗口多小都会模糊**整块屏幕**（批次 55 用它 → 用户反馈「全屏模糊」）。
    /// 磨砂效果改由 [RecognitionGlassBackdrop] 提供（窗口内局部背景模糊，
    /// 按玻璃轮廓裁剪），因此所有 addView 窗口一律不带该标志。
    private fun applyGlassBlur(lp: WindowManager.LayoutParams) {
        lp.flags = lp.flags and WindowManager.LayoutParams.FLAG_BLUR_BEHIND.inv()
    }

    // ===================== 底部拖拽关闭区域 =====================

    /// 屏幕底部"拖到这里关闭"提示条（独立 overlay，点击穿透）。
    /// 玻璃底 + 红色垃圾桶图标居中；拖动悬浮窗过程中显示；
    /// 拖入区域收敛为「淡红底 + 红描边」玻璃语言，松手即关闭服务。
    private fun createCloseZone() {
        val wm = windowManager ?: return
        val zone = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                // 玻璃深底 α85%，保证提示可读
                setColor(glassColor(cPanelBg, 0xD9))
                setStroke(dp(1), primaryStroke())
                // 顶部大圆角，底部贴边
                cornerRadii = floatArrayOf(
                    dp(24).toFloat(), dp(24).toFloat(),
                    dp(24).toFloat(), dp(24).toFloat(),
                    0f, 0f, 0f, 0f
                )
            }.also { closeZoneGd = it }
            setPadding(0, dp(8), 0, 0)
            elevation = dp(6).toFloat()
        }
        closeZoneIcon = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_menu_delete)
            // 常驻 error 红（MD3E 深色主题 error #FFB4AB）
            setColorFilter(cErrorIcon)
            val s = dp(40)
            layoutParams = LinearLayout.LayoutParams(s, s)
        }
        zone.addView(closeZoneIcon)
        closeZoneView = zone

        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        closeZoneParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            dp(110),
            layoutType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM
            x = 0
            y = 0
            applyGlassBlur(this)
        }
        wm.addView(zone, closeZoneParams)
        zone.visibility = View.GONE
    }

    private fun showCloseZone() {
        closeZoneView?.let { z ->
            if (z.visibility != View.VISIBLE) {
                z.visibility = View.VISIBLE
                z.alpha = 0f
                z.animate().alpha(1f).setDuration(160).start()
            }
        }
    }

    private fun hideCloseZone() {
        closeZoneView?.let { z ->
            z.animate().cancel()
            z.visibility = View.GONE
            resetCloseZoneHighlight()
        }
    }

    private fun setCloseZoneHighlight(on: Boolean) {
        if (isOverCloseZone == on) return
        isOverCloseZone = on
        val gd = closeZoneGd ?: return
        if (on) {
            // 拖入：淡红底 + 红描边（红色收敛为玻璃语言）
            gd.setColor(0x66B3261E.toInt())
            gd.setStroke(dp(2), cErrorDeep)
            // 拖入关闭区域：轻微震动提示即将删除
            vibrate(40, 120)
        } else {
            restoreCloseZoneGlass(gd)
        }
    }

    private fun resetCloseZoneHighlight() {
        isOverCloseZone = false
        restoreCloseZoneGlass(closeZoneGd)
    }

    private fun restoreCloseZoneGlass(gd: GradientDrawable?) {
        gd?.setColor(glassColor(cPanelBg, 0xD9))
        gd?.setStroke(dp(1), primaryStroke())
    }

    /// 震动反馈（API 26+ 用振幅，低版本回退 vibrate）。
    private fun vibrate(durationMs: Long, amplitude: Int) {
        val vibrator = getSystemService(VIBRATOR_SERVICE) as? Vibrator ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(durationMs, amplitude))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(durationMs)
        }
    }

    /// 悬浮窗拖动中：判断悬浮窗底部是否进入关闭区域 → 高亮
    private fun updateCloseZoneHighlight() {
        val zone = closeZoneView ?: return
        val root = rootView ?: return
        val zoneLoc = IntArray(2)
        val rootLoc = IntArray(2)
        zone.getLocationOnScreen(zoneLoc)
        root.getLocationOnScreen(rootLoc)
        val rootBottom = rootLoc[1] + root.height
        setCloseZoneHighlight(rootBottom >= zoneLoc[1])
    }

    /// 拖动 + 点击判定（结果面板按钮区域触摸被按钮自身拦截，不触发拖动）
    private fun setupTouchListener(view: View) {
        view.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = params?.x ?: 0
                    initialY = params?.y ?: 0
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    isDragging = false
                    dragStartTime = System.currentTimeMillis()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - initialTouchX
                    val dy = event.rawY - initialTouchY
                    if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
                        isDragging = true
                    }
                    if (isDragging) {
                        // 拖动时显示底部关闭区域并检测是否拖入
                        showCloseZone()
                        params?.x = initialX + dx.toInt()
                        params?.y = initialY + dy.toInt()
                        windowManager?.updateViewLayout(rootView, params)
                        // 背板跟手（用缓存偏移 + params 直接摆位，不依赖布局回调节奏）
                        syncBackdrop()
                        updateCloseZoneHighlight()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val shouldClose = isOverCloseZone
                    hideCloseZone()
                    if (shouldClose) {
                        // 拖入底部关闭区域：震动反馈后关闭悬浮窗服务
                        vibrate(120, 220)
                        stopSelf()
                        return@setOnTouchListener true
                    }
                    if (!isDragging && System.currentTimeMillis() - dragStartTime < 300) {
                        view.performClick()
                        onMicClick()
                    }
                    isDragging = false
                    true
                }
                else -> false
            }
        }
    }

    // ===================== 状态与交互 =====================

    private fun onMicClick() {
        when (state) {
            STATE_IDLE -> requestRecognition()
            STATE_RESULT -> dismissResult()
            else -> stopRecognition() // LISTENING / RECOGNIZING 时再次点击即停止
        }
    }

    /// 聆听/识别中再次点击：立即停止本轮识别（复用 ACTION_STOP_CAPTURE 的
    /// stopCapture 清理路径），悬浮窗保留、回到按钮态；Dart 侧同步作废本轮。
    private fun stopRecognition() {
        pendingCapture = false
        stopCapture()
        setState(STATE_IDLE)
        sendToDart("onFloatingAction", "stop")
    }

    /// 请求开始一轮识别：悬浮窗按钮点击 → 先通知 Dart 重置计数/状态文案，
    /// 再启动透明 trampoline activity 承接 MediaProjection 授权弹窗
    /// （授权前后用户都停留在外部页面，不再拉起主应用）。
    private fun requestRecognition() {
        if (Build.VERSION.SDK_INT < 29) {
            toast("仅支持 Android 10 及以上")
            return
        }
        if (pendingCapture || captureThread != null) return
        pendingCapture = true
        setState(STATE_LISTENING)
        sendToDart("onFloatingAction", "start")
        // service 无 UI 必须 NEW_TASK；activity 侧 taskAffinity="" 保证不并入主 task
        try {
            startActivity(
                Intent(this, RecognitionConsentActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (e: Exception) {
            // 各 ROM 对 FGS 启动 activity（BAL）限制不一：启动失败则本轮作废回 IDLE
            Log.e(TAG, "start RecognitionConsentActivity failed", e)
            pendingCapture = false
            setState(STATE_IDLE)
            sendToDart("onFloatingAction", "stop")
        }
    }

    /// 收起结果面板，回到按钮态（可再次识别）
    private fun dismissResult() {
        setState(STATE_IDLE)
    }

    private fun handleProjectionResult(resultCode: Int, data: Intent?) {
        // 用户在授权弹窗期间已点击停止（stopRecognition 已置 pendingCapture=false
        // 且无采集线程）：本轮作废，静默回 IDLE——不开始采集、不弹「未授权」提示、
        // 不通知 Dart。系统弹窗无法被程序关闭，用户按返回键关闭即可。
        if (!pendingCapture && captureThread == null) {
            setState(STATE_IDLE)
            return
        }
        if (resultCode != android.app.Activity.RESULT_OK || data == null) {
            pendingCapture = false
            setState(STATE_IDLE)
            toast("未授权，无法捕获系统音频")
            sendToDart("onProjectionResult", false)
            return
        }
        projectionResultCode = resultCode
        projectionData = data
        // 授权成功后把前台服务类型切换到 mediaProjection：Android 14+ 要求
        // getMediaProjection 前 FGS 运行时类型包含 mediaProjection，且此时
        // PROJECT_MEDIA 已由 createScreenCaptureIntent 授权授予，startForeground
        // 才能通过校验（Android 15+ 必须在授权后切换，否则 SecurityException）。
        promoteToMediaProjectionType()
        sendToDart("onProjectionResult", true)
        beginCaptureIfReady()
    }

    /// 把前台服务运行时类型从 specialUse 切换为 mediaProjection（授权成功后调用）。
    private fun promoteToMediaProjectionType() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        try {
            startForeground(
                NOTIFICATION_ID,
                createNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
            Log.i(TAG, "promoteToMediaProjectionType: OK")
        } catch (e: Exception) {
            Log.e(TAG, "promoteToMediaProjectionType failed", e)
        }
    }

    /// 授权就绪后开始采集（首次）；已采集时跳过
    @Synchronized
    private fun beginCaptureIfReady() {
        if (!pendingCapture || projectionData == null) return
        if (captureThread != null) return
        pendingCapture = false
        captureReleased = false
        if (!createCapture()) {
            setState(STATE_IDLE)
            toast("无法捕获该音频，请重试")
            return
        }
        setState(STATE_LISTENING)
        captureThread = Thread { captureLoop() }.apply { start() }
    }

    @Synchronized
    private fun createCapture(): Boolean {
        if (Build.VERSION.SDK_INT < 29) {
            Log.e(TAG, "createCapture: SDK < 29")
            return false
        }
        try {
            val pm = getSystemService(MediaProjectionManager::class.java)
            val data = projectionData ?: run {
                Log.e(TAG, "createCapture: projectionData null")
                return false
            }
            val mp = pm.getMediaProjection(projectionResultCode, data) ?: run {
                Log.e(TAG, "createCapture: getMediaProjection null")
                return false
            }
            // Android 14+（API 34+）硬性要求：MediaProjection.start() 前必须注册
            // Callback，否则 AudioRecord.startRecording() 触发 start() 时抛
            // RemoteException（"MediaProjectionCallback must be registered"）。
            mp.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.i(TAG, "MediaProjection onStop")
                }
            }, mainHandler)
            mediaProjection = mp

            val config = AudioPlaybackCaptureConfiguration.Builder(mp)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            val rec = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(config)
                .setAudioFormat(format)
                .setBufferSizeInBytes(maxOf(minBuf, SEGMENT_BYTES))
                .build()
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "createCapture: AudioRecord state=${rec.state} (expected INITIALIZED)")
                return false
            }
            audioRecord = rec
            try {
                rec.startRecording()
            } catch (e: Exception) {
                Log.e(TAG, "createCapture: startRecording failed", e)
                return false
            }
            Log.i(TAG, "createCapture: OK, ${SAMPLE_RATE}Hz, buffer=${maxOf(minBuf, SEGMENT_BYTES)}")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "createCapture: exception", e)
            return false
        }
    }

    /// 采集线程：每 6s 一段回调 Dart，然后阻塞等待 continue/stop。
    /// 实时振幅统计：采集满 2s 后若连续 2s 峰值振幅低于阈值（静音环境），
    /// 提前结束当前段（段字节数可 <SEGMENT_BYTES），把实际字节透传 Dart；
    /// 提前中断仅跳过「继续采集」，仍走同一等待 Dart 判定的路径。
    private fun captureLoop() {
        val recorder = audioRecord ?: return
        val buf = ByteArray(SEGMENT_BYTES)
        stopRequested = false
        while (!stopRequested) {
            var offset = 0
            var silentBytes = 0
            var earlySilenceStop = false
            while (offset < buf.size && !stopRequested) {
                val n = recorder.read(buf, offset, buf.size - offset)
                if (n > 0) {
                    // 静音提前中断：段首豁免 2s，之后连续 2s 静音则提前收段
                    if (offset >= SILENCE_GRACE_BYTES) {
                        val peak = bufferPeakAmplitude(buf, offset, n)
                        if (peak < SILENCE_AMPLITUDE_THRESHOLD) {
                            silentBytes += n
                            if (silentBytes >= SILENCE_WINDOW_BYTES) {
                                Log.i(TAG, "captureLoop: early silence stop at offset=$offset (peak<$SILENCE_AMPLITUDE_THRESHOLD for ${silentBytes / 16}ms)")
                                earlySilenceStop = true
                                break
                            }
                        } else {
                            silentBytes = 0
                        }
                    }
                    offset += n
                } else if (n < 0) {
                    Log.e(TAG, "captureLoop: read error n=$n at offset=$offset")
                    break
                }
            }
            if (stopRequested) break
            if (!earlySilenceStop && offset < buf.size) {
                Log.e(TAG, "captureLoop: short read offset=$offset (expected ${buf.size}), stopping")
                break
            }

            // 一段采集完成（满段或静音提前中断），交给 Dart 识别
            Log.i(TAG, "captureLoop: segment ready, sending onSegmentCaptured bytes=$offset")
            setState(STATE_RECOGNIZING)
            // 提前中断段按实际字节透传（Dart 端前处理与 audioMatch 均按实际字节处理）
            sendToDart("onSegmentCaptured", if (offset == buf.size) buf else buf.copyOf(offset))

            // 等待 Dart 决定：continueCapture 继续 / stopCapture 停止
            synchronized(captureLock) {
                while (!stopRequested && !continueAllowed) {
                    try {
                        captureLock.wait()
                    } catch (_: InterruptedException) {
                        break
                    }
                }
                Log.i(TAG, "captureLoop: resumed stop=$stopRequested continue=$continueAllowed")
                continueAllowed = false
            }
        }
        Log.i(TAG, "captureLoop: exit, releasing")
        releaseCapture()
    }

    /// 16-bit 小端 PCM 逐采样峰值振幅（max(abs(sample))），与 Dart 侧
    /// computeMaxAmplitude / kSilenceAmplitudeThreshold 同口径。
    private fun bufferPeakAmplitude(buf: ByteArray, offset: Int, len: Int): Int {
        var peak = 0
        var i = offset
        val end = offset + len - 1
        while (i < end) {
            val sample = ((buf[i].toInt() and 0xFF) or ((buf[i + 1].toInt() and 0xFF) shl 8)).toShort()
            val abs = kotlin.math.abs(sample.toInt())
            if (abs > peak) peak = abs
            i += 2
        }
        return peak
    }

    @Synchronized
    private fun requestContinueCapture() {
        // 采集线程已退出（用户点击停止后 Dart 在途段返回 continueCapture）：
        // 忽略，避免错误地把 UI 拉回 LISTENING 态
        if (captureThread == null) return
        synchronized(captureLock) {
            continueAllowed = true
            captureLock.notifyAll()
        }
        setState(STATE_LISTENING)
    }

    @Synchronized
    private fun stopCapture() {
        synchronized(captureLock) {
            stopRequested = true
            captureLock.notifyAll()
        }
    }

    @Synchronized
    private fun releaseCapture() {
        if (captureReleased) return
        captureReleased = true
        try { audioRecord?.stop() } catch (_: Exception) {}
        try { audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
        try { mediaProjection?.stop() } catch (_: Exception) {}
        mediaProjection = null
        projectionData = null
        projectionResultCode = 0
        captureThread = null
        stopRequested = false
        continueAllowed = false
        // 命中结果后 stopCapture 也会走到这里：保持 RESULT 面板显示，
        // 只有未命中/空闲时才回按钮态
        if (state != STATE_RESULT) {
            setState(STATE_IDLE)
        }
    }

    /// Dart 识别命中：显示封面/歌名/歌手 + 播放按钮
    /// 在 onStartCommand（主线程）同步更新状态：setState 立即写 state 字段，
    /// 避免与 releaseCapture 的 IDLE 重置竞态（若走 post 可能先 RESULT 后 IDLE）
    private fun showResult(resultJson: String) {
        try {
            val obj = JSONObject(resultJson)
            val name = obj.optString("songName", "").ifEmpty { "未知歌曲" }
            val artist = obj.optString("artist", "")
            songNameText?.text = name
            artistText?.text = artist
            artistText?.visibility = if (artist.isEmpty()) View.GONE else View.VISIBLE
            loadCover(obj.optString("imgurl", ""))
            setState(STATE_RESULT)
        } catch (_: Exception) {}
    }

    /// 异步加载歌曲封面（imgurl 已有），失败/无 url 时用应用图标占位
    private fun loadCover(url: String) {
        if (url.isEmpty()) {
            coverUrl = ""
            coverImage?.visibility = View.GONE
            return
        }
        coverUrl = url
        val img = coverImage ?: return
        img.visibility = View.VISIBLE
        // 占位：应用图标（按玻璃底亮度 tint）
        img.setImageResource(R.drawable.ic_launcher_monochrome)
        img.setColorFilter(idleIconTint())
        Thread {
            val bmp = try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 4000
                conn.readTimeout = 6000
                conn.inputStream.use { BitmapFactory.decodeStream(it) }
            } catch (_: Exception) {
                null
            }
            mainHandler.post {
                if (coverUrl == url && bmp != null) {
                    coverImage?.setImageBitmap(bmp)
                    coverImage?.setColorFilter(null)
                }
            }
        }.start()
    }

    private var coverUrl: String? = null

    /// Dart 状态提示（未识别/失败等），Toast 展示
    private fun showStatus(status: String) {
        if (status.isNotEmpty()) toast(status)
    }

    /// 接收 Dart 推送的主题色（设置页莫奈/动态取色），刷新悬浮窗玻璃配色
    /// 注意：Dart int（64 位）经 MethodChannel 到 Android 解码为 Long，
    /// 这里用 Number 接收并 toInt()，避免 Long→Integer ClassCastException
    private fun setThemeColors(intent: Intent) {
        @Suppress("UNCHECKED_CAST")
        val map = intent.getSerializableExtra(EXTRA_THEME_COLORS) as? HashMap<String, Number> ?: return
        map["surfaceContainerHighest"]?.toInt()?.let { cBtnIdleBg = it }
        map["onSurface"]?.toInt()?.let { cOnSurface = it }
        map["onSurfaceVariant"]?.toInt()?.let { cOnSurfaceVariant = it }
        map["primary"]?.toInt()?.let { cListeningBg = it }
        map["onPrimary"]?.toInt()?.let { cListeningIcon = it }
        map["tertiary"]?.toInt()?.let { cRecognizingBg = it }
        map["onTertiary"]?.toInt()?.let { cRecognizingIcon = it }
        map["primaryContainer"]?.toInt()?.let { cResultBg = it }
        map["onPrimaryContainer"]?.toInt()?.let { cResultIcon = it }
        map["surfaceContainer"]?.toInt()?.let { cPanelBg = it }
        map["outlineVariant"]?.toInt()?.let { cPanelStroke = it }
        mainHandler.post {
            // 刷新玻璃底/描边/文本静态配色（按钮动态配色由 updateUi 按状态刷新）
            micBtnGd?.setColor(glassColor(stateGlassBase()))
            micBtnGd?.setStroke(dp(1), primaryStroke())
            panelGd?.setColor(glassColor(cPanelBg, panelGlassAlpha()))
            panelGd?.setStroke(dp(1), primaryStroke())
            coverBgGd?.setColor(glassColor(cBtnIdleBg))
            playBtnBgGd?.setColor(glassColor(cResultBg))
            songNameText?.setTextColor(cOnSurface)
            artistText?.setTextColor(cOnSurfaceVariant)
            restoreCloseZoneGlass(closeZoneGd)
            closeZoneIcon?.setColorFilter(cErrorIcon)
            rippleView?.setRingColor(stateRippleColor())
            appIcon?.setColorFilter(stateIconTint())
            // 刷新按钮/图标动态配色
            updateUi()
            // 背板叠色随主题 token 刷新
            syncBackdrop()
        }
    }

    /// 当前状态的玻璃底 token 来源
    private fun stateGlassBase(): Int = when (state) {
        STATE_LISTENING -> cListeningBg
        STATE_RECOGNIZING -> cRecognizingBg
        STATE_RESULT -> cResultBg
        else -> cBtnIdleBg
    }

    /// 当前状态波纹颜色（聆听: primary / 识别: tertiary）
    private fun stateRippleColor(): Int = when (state) {
        STATE_RECOGNIZING -> cRecognizingBg
        else -> cListeningBg
    }

    /// 当前状态图标 tint（主题 onXxx token 保证与玻璃底对比度）
    private fun stateIconTint(): Int = when (state) {
        STATE_LISTENING -> cListeningIcon
        STATE_RECOGNIZING -> cRecognizingIcon
        STATE_RESULT -> cResultIcon
        else -> idleIconTint()
    }

    private fun setState(newState: Int) {
        if (state == newState) return
        state = newState
        mainHandler.post { updateUi() }
    }

    private fun updateUi() {
        val panel = resultPanel ?: return
        val gd = micBtnGd ?: return
        val icon = appIcon ?: return
        when (state) {
            STATE_IDLE -> {
                gd.setColor(glassColor(cBtnIdleBg))
                gd.setStroke(dp(1), primaryStroke())
                icon.setColorFilter(idleIconTint())
                panel.visibility = View.GONE
                stopListeningFx()
            }
            STATE_LISTENING -> {
                gd.setColor(glassColor(cListeningBg))
                gd.setStroke(dp(1), primaryStroke())
                icon.setColorFilter(cListeningIcon)
                panel.visibility = View.GONE
                startListeningFx(breathing = false)
            }
            STATE_RECOGNIZING -> {
                gd.setColor(glassColor(cRecognizingBg))
                gd.setStroke(dp(1), primaryStroke())
                icon.setColorFilter(cRecognizingIcon)
                panel.visibility = View.GONE
                startListeningFx(breathing = true)
            }
            STATE_RESULT -> {
                gd.setColor(glassColor(cResultBg))
                gd.setStroke(dp(1), primaryStroke())
                icon.setColorFilter(cResultIcon)
                showResultPanel()
                stopListeningFx()
            }
        }
        // 状态切换后同步背板形状/位置（面板显隐本身还会触发一次布局回调兜底）
        syncBackdrop()
    }

    /// 结果面板玻璃淡入上滑动效（MD3E expressive，260ms 保留）
    private fun showResultPanel() {
        val panel = resultPanel ?: return
        // 已在位（模糊开关/主题切换仅重绘配色时会再进本函数）不再重播入场动画
        if (panel.visibility == View.VISIBLE && panel.alpha == 1f && panel.translationY == 0f) return
        panel.visibility = View.VISIBLE
        panel.alpha = 0f
        panel.translationY = dp(10).toFloat()
        panel.animate()
            .alpha(1f)
            .translationY(0f)
            .setDuration(260)
            .setInterpolator(DecelerateInterpolator())
            .start()
    }

    /// 聆听/识别中：外圈波纹扩散（主题主色 α 渐隐，1400ms 循环）；
    /// 识别中额外加图标 0.94 ↔ 1.06 呼吸缩放。
    private fun startListeningFx(breathing: Boolean) {
        stopListeningFx()
        val ripple = rippleView ?: return
        ripple.setRingColor(stateRippleColor())
        ripple.visibility = View.VISIBLE
        rippleAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = RIPPLE_DURATION_MS
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener { ripple.setProgress(it.animatedValue as Float) }
            start()
        }
        if (breathing) {
            val icon = appIcon ?: return
            breatheAnimator = ValueAnimator.ofFloat(0.94f, 1.06f).apply {
                duration = BREATHE_DURATION_MS
                repeatCount = ValueAnimator.INFINITE
                repeatMode = ValueAnimator.REVERSE
                addUpdateListener {
                    icon.scaleX = it.animatedValue as Float
                    icon.scaleY = it.animatedValue as Float
                }
                start()
            }
        }
    }

    private fun stopListeningFx() {
        rippleAnimator?.cancel()
        rippleAnimator = null
        breatheAnimator?.cancel()
        breatheAnimator = null
        appIcon?.scaleX = 1f
        appIcon?.scaleY = 1f
        rippleView?.setProgress(0f)
        rippleView?.visibility = View.GONE
    }

    // ===================== 通知 =====================

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "悬浮窗识曲",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "悬浮窗听歌识曲"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val startIntent = Intent(this, FloatingRecognitionService::class.java).apply { action = ACTION_START }
        val startPendingIntent = PendingIntent.getService(
            this, 0, startIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = Intent(this, FloatingRecognitionService::class.java).apply { action = ACTION_STOP }
        val stopPendingIntent = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Grace Music 悬浮窗识曲")
            .setContentText("点击悬浮窗按钮识别正在播放的音乐")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_play, "开始识别", startPendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "关闭", stopPendingIntent)
            .build()
    }

    // ===================== 工具 =====================

    private fun sendToDart(method: String, args: Any?) {
        // MethodChannel.invokeMethod 必须主线程执行（@UiThread），采集线程需切主线程
        mainHandler.post {
            val engine = FlutterEngineCache.getInstance().get("md3music_engine")
            if (engine != null) {
                try {
                    MethodChannel(engine.dartExecutor.binaryMessenger, DART_CHANNEL)
                        .invokeMethod(method, args)
                } catch (e: Exception) {
                    Log.e(TAG, "sendToDart($method) failed: $e")
                }
            } else {
                Log.e(TAG, "sendToDart($method): FlutterEngineCache has no md3music_engine")
            }
        }
    }

    private fun toast(msg: String) {
        mainHandler.post {
            Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun sp(v: Float): Float = v * resources.displayMetrics.scaledDensity

    override fun onDestroy() {
        super.onDestroy()
        // 停止动效与采集线程并回收资源
        stopListeningFx()
        synchronized(captureLock) {
            stopRequested = true
            captureLock.notifyAll()
        }
        releaseCapture()
        rootView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {}
        }
        closeZoneView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {}
        }
        // 玻璃背板窗口与系统模糊开关监听一并回收（避免窗口泄漏 / 回调泄漏）
        try {
            blurListener?.let { l -> windowManager?.removeCrossWindowBlurEnabledListener(l) }
        } catch (_: Exception) {}
        blurListener = null
        micPlate?.release()
        panelPlate?.release()
        micPlate = null
        panelPlate = null
        blurActive = false
        // 通知 Dart 服务已停止，同步悬浮窗开关状态（避免 Dart 误以为仍在运行）
        sendToDart("onServiceStopped", null)
        instance = null
    }
}

/// 波纹扩散层（玻璃钮外圈）：3 圈主题主色圆环，α 随扩散渐隐，由外部
/// ValueAnimator 驱动 progress 循环；仅在 LISTENING / RECOGNIZING 状态显示。
class RippleRingView(context: android.content.Context) : View(context) {
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private var progress = 0f
    private var ringColor = Color.WHITE

    fun setRingColor(color: Int) {
        if (ringColor != color) {
            ringColor = color
            invalidate()
        }
    }

    fun setProgress(p: Float) {
        progress = p
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0 || h <= 0 || visibility != VISIBLE) return
        val cx = w / 2f
        val cy = h / 2f
        // 76dp 容器：内半径贴 52dp 玻璃钮边缘（26dp），扩散到容器边缘（38dp）
        val rMin = w * 0.34f
        val rMax = w * 0.5f
        ringPaint.strokeWidth = resources.displayMetrics.density * 2f
        for (i in 0 until RING_COUNT) {
            val t = (progress + i.toFloat() / RING_COUNT) % 1f
            val r = rMin + (rMax - rMin) * t
            ringPaint.color = ringColor
            ringPaint.alpha = ((1f - t) * 140).toInt()
            canvas.drawCircle(cx, cy, r, ringPaint)
        }
    }

    companion object {
        private const val RING_COUNT = 3
    }
}
