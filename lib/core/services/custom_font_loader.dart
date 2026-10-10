import 'package:flutter/services.dart';

/// 字体文件选择服务。
///
/// 仅保留 [CustomFontLoader.pickFontFile]：通过 Android 原生 SAF 文件选择器
/// 选择字体文件，原生端会把文件拷贝到 filesDir/fonts/user_custom.ttf 后返回路径。
/// 消费方：播放页歌词字体面板（md3_lyric_preferences_panel.dart）。
/// （原全局字体链 fontSource / loadIfAvailable / fromName 已随「字体与显示」
/// 设置项一并移除。）
class CustomFontLoader {
  static const String _channel = 'com.md3music.md3music/font_picker';

  /// 打开 Android 原生文件选择器，让用户选择 TTF/OTF 字体文件。
  ///
  /// 原生端会通过 SAF 拿到 content URI，将文件流拷贝到
  /// `filesDir/fonts/user_custom.ttf`，返回该文件绝对路径。
  /// 用户取消返回 null。
  static Future<String?> pickFontFile() async {
    try {
      final channel = MethodChannel(_channel);
      return await channel.invokeMethod<String>('pickFontFile');
    } catch (_) {
      return null;
    }
  }
}
