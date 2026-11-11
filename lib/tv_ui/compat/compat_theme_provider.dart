// 批次50：TV 命名空间兼容层——上游（rust-local-force）ThemeProvider 新增成员降级适配。
//
// lite ThemeProvider 无上游新增的「播放器风格 / 歌手写真 / 字体 / 显示大小」等
// 设置体系（上游为内存字段 + notifyListeners + SharedPreferences 持久化）。
// extension 无法访问上游私有字段，这里以模块级缓存 + 同名 prefs 键复刻上游
// 持久化语义：键值与上游完全一致（上游 _xxxKey 常量原样搬运），TV 设置页
// 写入后立即生效并可持久化；重启后经 [tvThemeCompatEnsureLoaded] 恢复。
// prefs 加载前的短暂窗口内 getter 返回上游默认值。
//
// notifyListeners 属 @protected，compat 层调用处统一 ignore。
// ignore_for_file: invalid_use_of_protected_member


import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/tv_ui/core/layout/ui_density.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/tv_ui/core/services/windows_default_font.dart';
import 'package:md3music/tv_ui/core/services/custom_font_loader.dart' show FontSource;

// —— 上游 prefs 键（原样搬运，保证与上游写入的持久化空间兼容）——
const String _tvAmStylePlayerKey = 'use_am_style_player';
const String _tvArtistPhotoBgKey = 'use_artist_photo_background';
const String _tvArtistPhotoIntervalKey = 'artist_photo_interval';
const String _tvArtistPhotoOpacityKey = 'artist_photo_opacity';
const String _tvAmPlayerBlurKey = 'am_player_blur';
const String _tvLyricDoubleTapToJumpKey = 'lyric_double_tap_to_jump';
const String _tvFontSourceKey = 'font_source';
const String _tvCustomFontPathKey = 'custom_font_path';
const String _tvCustomTextColorKey = 'custom_text_color';
const String _tvDisplayScaleKey = 'ui_display_scale';

// —— 模块级缓存（上游私有字段的等价物；TV 命名空间内共享）——
bool _tvUseAmStylePlayer = false;
bool _tvUseArtistPhotoBackground = false;
int _tvArtistPhotoInterval = 15;
double _tvArtistPhotoOpacity = 0.55;
double _tvAmPlayerBlur = 30.0;
bool _tvLyricDoubleTapToJump = false;
bool _tvEmphasizedTypography = false;
FontSource _tvFontSource = FontSource.system;
String? _tvCustomFontPath;
Color? _tvCustomTextColor;
bool _tvLoaded = false;

/// 恢复持久化值到模块缓存（TV 壳层启动后调用；未调用时 getter 返回默认值）。
Future<void> tvThemeCompatEnsureLoaded() async {
  if (_tvLoaded) return;
  final prefs = await SharedPreferences.getInstance();
  _tvUseAmStylePlayer = prefs.getBool(_tvAmStylePlayerKey) ?? false;
  _tvUseArtistPhotoBackground = prefs.getBool(_tvArtistPhotoBgKey) ?? false;
  _tvArtistPhotoInterval = prefs.getInt(_tvArtistPhotoIntervalKey) ?? 15;
  _tvArtistPhotoOpacity = prefs.getDouble(_tvArtistPhotoOpacityKey) ?? 0.55;
  _tvAmPlayerBlur = prefs.getDouble(_tvAmPlayerBlurKey) ?? 30.0;
  _tvLyricDoubleTapToJump = prefs.getBool(_tvLyricDoubleTapToJumpKey) ?? false;
  _tvEmphasizedTypography = prefs.getBool('use_emphasized_typography') ?? false;
  final fs = prefs.getString(_tvFontSourceKey);
  _tvFontSource = fs == null
      ? FontSource.system
      : FontSource.values.firstWhere((e) => e.name == fs, orElse: () => FontSource.system);
  _tvCustomFontPath = prefs.getString(_tvCustomFontPathKey);
  final tc = prefs.getString(_tvCustomTextColorKey);
  _tvCustomTextColor = tc == null ? null : Color(int.parse(tc));
  _tvLoaded = true;
}

/// 通用写回：内存缓存 + prefs + 通知。
void _tvApply(ThemeProvider provider, Future<void> Function(SharedPreferences) persist) {
  SharedPreferences.getInstance().then(persist);
  // 批次50 适配：lite 该成员为 visibleForTesting，TV 兼容层需跨层通知。
  // ignore: invalid_use_of_visible_for_testing_member
  provider.notifyListeners();
}

extension ThemeProviderTvCompat on ThemeProvider {
  // —— AM 风格播放器 ——
  bool get useAmStylePlayer => _tvUseAmStylePlayer;
  Future<void> get amStylePlayerReady => tvThemeCompatEnsureLoaded();

  Future<void> setUseAmStylePlayer(bool enabled) async {
    _tvUseAmStylePlayer = enabled;
    _tvApply(this, (prefs) => prefs.setBool(_tvAmStylePlayerKey, enabled));
  }

  // —— 歌手写真背景 ——
  bool get useArtistPhotoBackground => _tvUseArtistPhotoBackground;

  Future<void> setUseArtistPhotoBackground(bool enabled) async {
    _tvUseArtistPhotoBackground = enabled;
    _tvApply(this, (prefs) => prefs.setBool(_tvArtistPhotoBgKey, enabled));
  }

  int get artistPhotoInterval => _tvArtistPhotoInterval;

  Future<void> setArtistPhotoInterval(int seconds) async {
    final clamped = seconds.clamp(5, 60);
    _tvArtistPhotoInterval = clamped;
    _tvApply(this, (prefs) => prefs.setInt(_tvArtistPhotoIntervalKey, clamped));
  }

  double get artistPhotoOpacity => _tvArtistPhotoOpacity;

  Future<void> setArtistPhotoOpacity(double opacity) async {
    final clamped = opacity.clamp(0.0, 0.95);
    _tvArtistPhotoOpacity = clamped;
    _tvApply(this, (prefs) => prefs.setDouble(_tvArtistPhotoOpacityKey, clamped));
  }

  // —— AM 播放器模糊 ——
  double get amPlayerBlur => _tvAmPlayerBlur;

  Future<void> setAmPlayerBlur(double blur) async {
    _tvAmPlayerBlur = blur;
    _tvApply(this, (prefs) => prefs.setDouble(_tvAmPlayerBlurKey, blur));
  }

  // —— 歌词双击跳转 ——
  bool get lyricDoubleTapToJump => _tvLyricDoubleTapToJump;

  Future<void> setLyricDoubleTapToJump(bool enabled) async {
    _tvLyricDoubleTapToJump = enabled;
    _tvApply(this, (prefs) => prefs.setBool(_tvLyricDoubleTapToJumpKey, enabled));
  }

  // —— 强调排版 ——
  bool get emphasizedTypographyEnabled => _tvEmphasizedTypography;

  Future<void> setEmphasizedTypographyEnabled(bool enabled) async {
    _tvEmphasizedTypography = enabled;
    _tvApply(this, (prefs) => prefs.setBool('use_emphasized_typography', enabled));
  }

  // —— 字体 ——
  FontSource get fontSource => _tvFontSource;

  Future<void> setFontSource(FontSource source) async {
    _tvFontSource = source;
    _tvApply(this, (prefs) => prefs.setString(_tvFontSourceKey, source.name));
  }

  String? get customFontPath => _tvCustomFontPath;

  Future<void> setCustomFontPath(String? path) async {
    _tvCustomFontPath = path;
    _tvApply(this, (prefs) => path == null ? prefs.remove(_tvCustomFontPathKey) : prefs.setString(_tvCustomFontPathKey, path));
  }

  Color? get customTextColor => _tvCustomTextColor;

  Future<void> setCustomTextColor(Color? color) async {
    _tvCustomTextColor = color;
    _tvApply(this, (prefs) => color == null
        ? prefs.remove(_tvCustomTextColorKey)
        : prefs.setString(_tvCustomTextColorKey, color.toARGB32().toString()));
  }

  /// 上游实现读 Windows 内置思源黑体 / 自定义字体；TV（Android）降级为系统字体链。
  String? get effectiveFontFamily => WindowsDefaultFont.loadedFamily;

  // —— 显示大小 ——
  Future<void> setDisplayScale(double scale) async {
    final clamped = scale.clamp(kMinDisplayScale, kMaxDisplayScale);
    _tvApply(this, (prefs) => prefs.setDouble(_tvDisplayScaleKey, clamped));
  }

  /// 上游语义：开关开启且背景图文件存在。lite 实例无背景图路径私有字段，
  /// 降级为 lite 公开的 useBackgroundImage 开关 + 默认壁纸视为有效。
  bool get isBackgroundImageEffective => useBackgroundImage;

  /// 上游为 Windows 设置加载流程信号；lite 无该流程，立即就绪。
  Future<void> reloadWindowsSettings() async {}

  /// 批次50 适配：上游 Windows 设置加载完成信号；lite 无该流程，立即就绪。
  Future<void> get windowsSettingsReady => Future.value();
}
