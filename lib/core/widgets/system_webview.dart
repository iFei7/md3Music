import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 原生系统 WebView（android.webkit.WebView）平台视图的 Dart 薄封装。
///
/// 替代 webview_flutter 插件：去掉 hybrid composition / 内核胶水层依赖，
/// 只服务于签到滑块验证码（腾讯 TCaptcha）这一唯一场景。
/// 仅 Android（lite 分支只出 Android APK）；iOS / Web 端此路径未覆盖。
///
/// 原生侧（android/.../SystemWebViewPlugin.kt）协议：
/// - viewType 固定 'system_webview'
/// - 每个实例一条 MethodChannel：'com.md3music.md3music/system_webview/<id>'
/// - Dart → 原生：loadUrl(assetKey)（原生拼 file:///android_asset/flutter_assets/
///   <assetKey>，等价 webview_flutter 的 loadFlutterAsset）/ evaluateJavascript(script)
/// - 原生 → Dart：onCaptchaMessage(String)（页面 JS 经 window.CaptchaChannel.
///   postMessage 上行，与 webview_flutter 的 JavascriptChannel API 形态一致）/
///   onPageFinished(String url) / onResourceError(Map)
class SystemWebViewController {
  SystemWebViewController._(this._channel);

  final MethodChannel _channel;

  /// 加载 Flutter assets 里的页面。
  Future<void> loadAsset(String assetKey) {
    return _channel.invokeMethod<void>(
      'loadUrl',
      <String, dynamic>{'assetKey': assetKey},
    );
  }

  /// 在页面里执行 JS（__READY__ / onPageFinished 时注入 initCaptcha 用）。
  /// 平台视图销毁后调用会抛 PlatformException，静默忽略（弹窗即将关闭）。
  Future<void> evaluateJavascript(String script) async {
    try {
      await _channel.invokeMethod<String>(
        'evaluateJavascript',
        <String, dynamic>{'script': script},
      );
    } on PlatformException {
      // ignore: 平台视图已销毁，无需处理。
    }
  }
}

class SystemWebView extends StatefulWidget {
  const SystemWebView({
    super.key,
    required this.assetKey,
    required this.onMessage,
    this.onCreated,
    this.onPageFinished,
    this.onResourceError,
  });

  /// Flutter assets 相对路径（原生侧自动拼 file:///android_asset 前缀）。
  final String assetKey;

  /// 平台视图创建完成、通道就绪后回调（用于拿到 evaluateJavascript 入口）。
  final void Function(SystemWebViewController controller)? onCreated;

  /// 页面 JS 经 'CaptchaChannel' 桥 postMessage 上来的消息。
  final ValueChanged<String> onMessage;

  final void Function(String url)? onPageFinished;

  /// 页面/子资源加载错误（与原 webview_flutter 的 onWebResourceError 对齐）。
  final void Function(Map<Object?, Object?> error)? onResourceError;

  @override
  State<SystemWebView> createState() => _SystemWebViewState();
}

class _SystemWebViewState extends State<SystemWebView> {
  static const _viewType = 'system_webview';
  static const _channelPrefix = 'com.md3music.md3music/system_webview';

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('$_channelPrefix/$id');
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onCaptchaMessage':
          final message = call.arguments as String?;
          if (message != null) widget.onMessage(message);
        case 'onPageFinished':
          widget.onPageFinished?.call(call.arguments as String? ?? '');
        case 'onResourceError':
          widget.onResourceError
              ?.call(call.arguments as Map<Object?, Object?>? ?? const {});
      }
    });
    final controller = SystemWebViewController._(channel);
    widget.onCreated?.call(controller);
    // 视图创建即加载本地验证码页（等价原 loadFlutterAsset）。
    controller.loadAsset(widget.assetKey);
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      // 非 Android 平台此路径未覆盖：显示空占位，不抛异常。
      return const SizedBox.expand();
    }
    // EagerGestureRecognizer：滑块拖动手势全部直达 WebView，
    // 与 webview_flutter 默认手势行为对齐。
    return AndroidView(
      viewType: _viewType,
      onPlatformViewCreated: _onPlatformViewCreated,
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
    );
  }
}
