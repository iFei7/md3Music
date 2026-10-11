package com.md3music.md3music

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 系统 android.webkit.WebView 平台视图（替代 webview_flutter 插件）。
 *
 * lite 分支唯一的 WebView 消费点是签到日历的腾讯 TCaptcha 滑块验证码页
 * （assets/web/verify_captcha.html）。webview_flutter 连同其 hybrid
 * composition / 内核胶水层只为此一处服务，故直接用系统 WebView +
 * PlatformView 注册，参照 Sonify 的做法去掉整条插件依赖。
 *
 * 协议约定（与 lib/core/widgets/system_webview.dart 对应）：
 * - viewType 固定 'system_webview'
 * - 每个实例一条 MethodChannel：'com.md3music.md3music/system_webview/<viewId>'
 * - Dart → 原生方法：loadUrl(assetKey) / evaluateJavascript(script)
 * - 原生 → Dart 回调：onCaptchaMessage(String) / onPageFinished(String url) /
 *   onResourceError(Map{errorCode, description, isForMainFrame})
 * - 页面 JS 侧通过 window.CaptchaChannel.postMessage(msg) 上行消息
 *   （addJavascriptInterface 注册的同名桥对象，与 webview_flutter 的
 *   JavascriptChannel 页面侧 API 形态天然一致，verify_captcha.html 无需改动）。
 *
 * 仅 Android；iOS/Web 端此路径未覆盖（lite 只出 Android APK）。
 */
object SystemWebViewPlugin {
    const val VIEW_TYPE = "system_webview"
    const val JS_BRIDGE_NAME = "CaptchaChannel"
    internal const val CHANNEL_PREFIX = "com.md3music.md3music/system_webview"
    internal const val FLUTTER_ASSET_URL_PREFIX = "file:///android_asset/flutter_assets/"

    /**
     * 在 MainActivity.configureFlutterEngine 中调用。引擎复用路径下
     * configureFlutterEngine 可能重复执行，registerViewFactory 对同一
     * viewType 是覆盖语义，重复注册幂等安全。
     */
    fun register(engine: FlutterEngine) {
        val factory = SystemWebViewFactory(engine.dartExecutor.binaryMessenger)
        engine.platformViewsController.registry.registerViewFactory(VIEW_TYPE, factory)
    }
}

/** PlatformViewFactory：create 时新建系统 WebView 实例。 */
class SystemWebViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return SystemWebViewPlatformView(context, viewId, messenger)
    }
}

/**
 * 单个 WebView 平台视图实例。生命周期与 Flutter 侧 AndroidView 绑定，
 * dispose 时销毁 WebView 防止泄漏。
 */
class SystemWebViewPlatformView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(
        messenger,
        "${SystemWebViewPlugin.CHANNEL_PREFIX}/$viewId",
    )
    private val disposed = AtomicBoolean(false)

    @SuppressLint("SetJavaScriptEnabled", "AddJavascriptInterface")
    private val webView: WebView = WebView(context).apply {
        // TCaptcha 需要：JS、DOM storage（滑块组件存状态）、文件访问
        // （本地 asset 页）、自动媒体播放（与原 webview_flutter 配置对齐）。
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.allowFileAccess = true
        settings.mediaPlaybackRequiresUserGesture = false
        // 默认 WebChromeClient：保证 alert/弹层类能力不因缺 client 而静默失效。
        webChromeClient = WebChromeClient()
        webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                notifyDart("onPageFinished", url)
            }

            // API 23+：主框架与子资源错误都会回调（与 webview_flutter 的
            // onWebResourceError 行为一致），由 Dart 侧决定取消验证 + 关弹窗。
            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                notifyDart(
                    "onResourceError",
                    mapOf(
                        "errorCode" to error.errorCode,
                        "description" to (error.description?.toString() ?: ""),
                        "isForMainFrame" to request.isForMainFrame,
                    ),
                )
            }

            // API < 23 的老签名兜底（仅主框架错误）。
            @Deprecated("Deprecated in Java")
            override fun onReceivedError(
                view: WebView,
                errorCode: Int,
                description: String?,
                failingUrl: String?,
            ) {
                notifyDart(
                    "onResourceError",
                    mapOf(
                        "errorCode" to errorCode,
                        "description" to (description ?: ""),
                        "isForMainFrame" to true,
                    ),
                )
            }
        }
        addJavascriptInterface(CaptchaJsBridge(::onBridgeMessage), SystemWebViewPlugin.JS_BRIDGE_NAME)
    }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun getView(): View = webView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadUrl" -> {
                val assetKey = call.argument<String>("assetKey")
                if (assetKey.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENT", "assetKey 必填", null)
                    return
                }
                // 带 scheme 的直接用；否则视为 Flutter assets 相对路径，
                // 原生拼 file:///android_asset/flutter_assets/<assetKey>
                // （等价 webview_flutter 的 loadFlutterAsset）。
                val url = if (assetKey.startsWith("http://") ||
                    assetKey.startsWith("https://") ||
                    assetKey.startsWith("file://")
                ) {
                    assetKey
                } else {
                    "${SystemWebViewPlugin.FLUTTER_ASSET_URL_PREFIX}$assetKey"
                }
                webView.loadUrl(url)
                result.success(true)
            }
            "evaluateJavascript" -> {
                val script = call.argument<String>("script")
                if (script == null) {
                    result.error("INVALID_ARGUMENT", "script 必填", null)
                    return
                }
                // 回调在 UI 线程，直接把页面求值结果字符串回传 Dart。
                webView.evaluateJavascript(script) { value -> result.success(value) }
            }
            else -> result.notImplemented()
        }
    }

    /** JS 桥线程（JavaBridge 线程）入口：统一切到主线程再回传 Dart。 */
    private fun onBridgeMessage(message: String) {
        notifyDart("onCaptchaMessage", message)
    }

    /** 原生 → Dart 回调统一走主线程；视图已销毁则丢弃，防泄漏后误回调。 */
    private fun notifyDart(method: String, argument: Any?) {
        mainHandler.post {
            if (!disposed.get()) {
                channel.invokeMethod(method, argument)
            }
        }
    }

    override fun dispose() {
        disposed.set(true)
        channel.setMethodCallHandler(null)
        // 先摘除 JS 桥与 client、加载空白页停掉页面活动，再销毁实例防泄漏。
        runCatching { webView.removeJavascriptInterface(SystemWebViewPlugin.JS_BRIDGE_NAME) }
        webView.webViewClient = WebViewClient()
        webView.loadUrl("about:blank")
        (webView.parent as? ViewGroup)?.removeView(webView)
        webView.destroy()
    }
}

/**
 * 注入页面的 JS 桥对象（window.CaptchaChannel）。
 *
 * 页面侧调用形态 `CaptchaChannel.postMessage(msg)` 与 webview_flutter 的
 * JavascriptChannel 完全一致，verify_captcha.html 无需任何改动。
 * postMessage 在 WebView 的 JavaBridge 线程回调，须切主线程后回传 Dart。
 * 类与 postMessage 方法都必须是 public（WebView JS 桥的反射要求）。
 */
class CaptchaJsBridge(private val onMessage: (String) -> Unit) {
    @JavascriptInterface
    fun postMessage(message: String?) {
        if (message != null) onMessage(message)
    }
}
