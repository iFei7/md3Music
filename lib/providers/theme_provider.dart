import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_theme.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _key = 'theme_mode';
  static const String _dynamicKey = 'use_dynamic_color';
  static const String _coverDynamicKey = 'use_cover_dynamic_color';
  static const String _manualSeedKey = 'manual_seed_color';
  static const String _oledBlackKey = 'use_oled_black';
  // 底部导航栏文字显示行为：始终显示 / 仅当前页 / 始终不显示
  static const String _navLabelBehaviorKey = 'nav_label_behavior';
  // 自定义背景图片（全局界面背景）
  static const String backgroundImageEnabledPreferenceKey =
      'use_background_image';
  static const String _bgImageEnabledKey =
      backgroundImageEnabledPreferenceKey;
  static const String _bgImagePathKey = 'background_image_path';
  static const String _bgBlurKey = 'background_blur';
  static const String _bgOpacityKey = 'background_opacity';
  // 按背景图莫奈取色开关（默认开启）
  static const String _bgMonetKey = 'use_background_monet';
  // 文字阴影开关（默认开启，仅在启用自定义背景图片时生效）
  static const String _textShadowKey = 'use_text_shadow';
  static const String _textShadowBlurKey = 'text_shadow_blur';

  ThemeMode _themeMode = ThemeMode.system;
  bool _useDynamicColor = false;
  Color? _systemSeedColor;
  // 封面动态取色：根据当前播放歌曲封面颜色动态改变全局主题色。
  // 开启且提取成功时优先级高于系统壁纸色（见 effectiveSeedColor）。
  bool _useCoverSeedColor = false;
  Color? _coverSeedColor;
  Color? _manualSeedColor;
  bool _useOledBlack = false;
  // 底部导航栏文字显示行为（默认始终不显示）
  NavigationDestinationLabelBehavior _navLabelBehavior =
      NavigationDestinationLabelBehavior.alwaysHide;
  // 自定义背景图片（全局界面背景）；默认开启，未选择图片时回落到内置默认壁纸
  bool _useBackgroundImage = true;
  String? _backgroundImagePath;
  double _backgroundBlur = 20.0;
  double _backgroundOpacity = 0.2;
  // 按背景图莫奈取色（默认开启；关闭后背景图仍显示但不参与主题色）
  bool _useBackgroundMonet = true;
  // 文字阴影（默认关闭）：给全局文字加轮廓阴影，改善背景图上的可读性。
  // 仅在 _useBackgroundImage 为 true 时生效（见 [useTextShadowEffective]）。
  bool _useTextShadow = false;
  // 文字阴影磅数（阴影模糊半径，用户可调）
  double _textShadowBlur = AppTheme.defaultTextShadowBlur;
  // 从背景图片提取的主色（运行时，作为莫奈取色种子）
  Color? _backgroundSeedColor;

  ThemeMode get themeMode => _themeMode;
  bool get useDynamicColor => _useDynamicColor;
  Color? get systemSeedColor => _systemSeedColor;
  bool get useCoverSeedColor => _useCoverSeedColor;
  Color? get coverSeedColor => _coverSeedColor;
  Color? get manualSeedColor => _manualSeedColor;
  bool get useOledBlack => _useOledBlack;
  NavigationDestinationLabelBehavior get navLabelBehavior => _navLabelBehavior;
  bool get useBackgroundImage => _useBackgroundImage;
  String? get backgroundImagePath => _backgroundImagePath;
  double get backgroundBlur => _backgroundBlur;
  double get backgroundOpacity => _backgroundOpacity;
  bool get useBackgroundMonet => _useBackgroundMonet;
  bool get useTextShadow => _useTextShadow;
  double get textShadowBlur => _textShadowBlur;
  Color? get backgroundSeedColor => _backgroundSeedColor;

  /// 文字阴影是否实际生效：开关本身开启 **且** 已启用自定义背景图片。
  /// 未启用背景图时纯色主题自带足够对比度，阴影只会让文字发虚，故不生效。
  bool get useTextShadowEffective => _useBackgroundImage && _useTextShadow;

  /// 当前生效的种子色优先级：
  /// 1. 启用封面动态取色且提取成功 → 歌曲封面主色（可叠加系统主题色，封面优先）
  /// 2. 启用自定义背景图片且开启莫奈取色并取色成功 → 背景图片主色
  /// 3. 启用系统主题色且成功取到 → 系统主色
  /// 4. 用户手动选择非 null → 手动色
  /// 5. 默认蓝色种子（[AppTheme.defaultSeedColor]）
  ///
  /// 封面取色开启但提取失败（[_coverSeedColor] 为 null，如无封面/本地图损坏）
  /// 时自然回落到后续级别，完成兜底。
  Color get effectiveSeedColor {
    if (_useCoverSeedColor && _coverSeedColor != null) {
      return _coverSeedColor!;
    }
    if (_useBackgroundImage && _useBackgroundMonet && _backgroundSeedColor != null) {
      return _backgroundSeedColor!;
    }
    if (_useDynamicColor && _systemSeedColor != null) {
      return _systemSeedColor!;
    }
    return _manualSeedColor ?? AppTheme.defaultSeedColor;
  }

  ThemeProvider({bool? initialUseBackgroundImage}) {
    if (initialUseBackgroundImage != null) {
      _useBackgroundImage = initialUseBackgroundImage;
    }
    _loadThemeMode();
    _loadDynamicColor();
    _loadUseCoverSeedColor();
    _loadManualSeedColor();
    _loadOledBlack();
    _loadNavLabelBehavior();
    _loadBackgroundImage();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIndex = prefs.getInt(_key);
    if (savedIndex != null && savedIndex >= 0 && savedIndex < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[savedIndex];
      notifyListeners();
    }
  }

  Future<void> _saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, mode.index);
  }

  /// 加载「使用系统主题色」开关持久化值，若开启则同步提取系统主色。
  Future<void> _loadDynamicColor() async {
    final prefs = await SharedPreferences.getInstance();
    _useDynamicColor = prefs.getBool(_dynamicKey) ?? false;
    if (_useDynamicColor) {
      await _loadSystemColor();
    }
    notifyListeners();
  }

  /// 优化版系统色提取（HCT 多点评分）：
  /// 1. 取系统 palette.primary 的 5 个 tone（30/35/40/45/50）作为候选
  /// 2. 用 [Score.score] 在 HCT 色彩空间评分候选，按适合度降序排列
  ///    （参考 MaterialKolor 的 Score 评分流程）
  /// 3. 选分最高者作为种子色
  /// 失败时降级为 [CorePalette.primary.get(40)]（与改造前行为一致）。
  ///
  /// 参考：https://github.com/jordond/MaterialKolor
  /// Flutter 端等价包：material_color_utilities（Google 官方 Dart 端口）
  ///
  /// 注意：MaterialKolor 原流程是 QuantizerCelebi + Score，但 QuantizerCelebi
  /// 内部基于 QuantizerWu（为图片像素设计），对 5 个候选 tone 的少量输入不稳定。
  /// 这里直接调 Score.score 评分候选 tone，更稳定且符合「HCT 评分选最佳」的核心思想。
  Future<void> _loadSystemColor() async {
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette == null) {
        _systemSeedColor = null;
        return;
      }

      // 候选 tone 列表：覆盖 M3 primary 的典型取值范围（默认 tone=40，向上下扩展）
      const candidateTones = [30, 35, 40, 45, 50];
      // 构造 population map：每个候选 tone 等权重出现 1 次
      // Score.score 内部会根据 HCT 色彩空间评分（chroma / proportion / 过滤），按适合度降序
      final colorsToPopulation = <int, int>{
        for (final tone in candidateTones) palette.primary.get(tone): 1,
      };

      // Score 评分并选最佳（返回按适合度降序排列的 ARGB 列表）
      // desired 设为候选数，确保返回尽可能多的候选；fallbackColorARGB 用默认紫色
      final scored = Score.score(
        colorsToPopulation,
        desired: candidateTones.length,
        fallbackColorARGB: AppTheme.defaultSeedColor.toARGB32(),
      );
      if (scored.isEmpty) {
        // 评分失败降级到原 get(40) 行为
        _systemSeedColor = Color(palette.primary.get(40));
        return;
      }
      _systemSeedColor = Color(scored.first);
    } catch (_) {
      _systemSeedColor = null;
    }
  }

  /// 切换「使用系统主题色」开关。
  Future<void> setUseDynamicColor(bool enabled) async {
    if (_useDynamicColor == enabled) return;
    _useDynamicColor = enabled;
    if (enabled) {
      await _loadSystemColor();
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dynamicKey, enabled);
  }

  /// 加载「封面动态取色」开关持久化值，默认关闭。
  Future<void> _loadUseCoverSeedColor() async {
    final prefs = await SharedPreferences.getInstance();
    _useCoverSeedColor = prefs.getBool(_coverDynamicKey) ?? false;
    notifyListeners();
  }

  /// 切换「封面动态取色」开关。
  ///
  /// 与「使用系统主题色」相互独立、可叠加；都开启时封面取色优先
  /// （见 [effectiveSeedColor]）。关闭时不立即清空 [_coverSeedColor]，
  /// 由优先级链天然忽略；切歌桥接仍会持续更新缓存色。
  Future<void> setUseCoverSeedColor(bool enabled) async {
    if (_useCoverSeedColor == enabled) return;
    _useCoverSeedColor = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_coverDynamicKey, enabled);
  }

  /// 更新封面提取色（由切歌桥接调用）。
  ///
  /// 仅运行时保存、不落盘（颜色随歌曲变化）；传 null 表示提取失败/无封面，
  /// effectiveSeedColor 自动回落到系统壁纸色/手动色/默认紫。
  void setCoverSeedColor(Color? color) {
    if (_coverSeedColor == color) return;
    _coverSeedColor = color;
    notifyListeners();
  }

  /// 加载用户手动选择的种子色持久化值。
  Future<void> _loadManualSeedColor() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_manualSeedKey);
    if (value != null) {
      _manualSeedColor = Color(value);
      notifyListeners();
    }
  }

  /// 设置手动种子色。传 null 清除（回退默认紫色）。
  Future<void> setManualSeedColor(Color? color) async {
    if (_manualSeedColor == color) return;
    _manualSeedColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (color != null) {
      await prefs.setInt(_manualSeedKey, color.toARGB32());
    } else {
      await prefs.remove(_manualSeedKey);
    }
  }

  /// 加载「OLED 纯黑深色模式」开关持久化值，默认关闭。
  Future<void> _loadOledBlack() async {
    final prefs = await SharedPreferences.getInstance();
    _useOledBlack = prefs.getBool(_oledBlackKey) ?? false;
    notifyListeners();
  }

  /// 切换「OLED 纯黑深色模式」开关。
  /// 开启时 darkTheme 的 surface 系列覆盖为纯黑（仅深色模式生效）。
  Future<void> setUseOledBlack(bool enabled) async {
    if (_useOledBlack == enabled) return;
    _useOledBlack = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_oledBlackKey, enabled);
  }

  /// 加载底部导航栏文字显示行为的持久化值，默认始终不显示。
  Future<void> _loadNavLabelBehavior() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_navLabelBehaviorKey);
    if (index != null &&
        index >= 0 &&
        index < NavigationDestinationLabelBehavior.values.length) {
      _navLabelBehavior = NavigationDestinationLabelBehavior.values[index];
    }
    notifyListeners();
  }

  /// 设置底部导航栏文字显示行为并持久化。
  Future<void> setNavLabelBehavior(NavigationDestinationLabelBehavior value) async {
    if (_navLabelBehavior == value) return;
    _navLabelBehavior = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_navLabelBehaviorKey, value.index);
  }

  void toggleTheme() {
    switch (_themeMode) {
      case ThemeMode.light:
        setThemeMode(ThemeMode.dark);
        break;
      case ThemeMode.dark:
        setThemeMode(ThemeMode.system);
        break;
      case ThemeMode.system:
        setThemeMode(ThemeMode.light);
        break;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await _saveThemeMode(mode);
  }

  // ============== 自定义背景图片 ==============

  /// 加载背景图片相关持久化值（开关 / 路径 / 模糊 / 透明度 / 莫奈取色 / 文字阴影），
  /// 默认开启（无用户图片时用内置默认壁纸）/ 莫奈取色默认开启 / 文字阴影默认开启。
  Future<void> _loadBackgroundImage() async {
    final prefs = await SharedPreferences.getInstance();
    _useBackgroundImage = prefs.getBool(_bgImageEnabledKey) ?? true;
    _backgroundImagePath = prefs.getString(_bgImagePathKey);
    _backgroundBlur = prefs.getDouble(_bgBlurKey) ?? 20.0;
    _backgroundOpacity = prefs.getDouble(_bgOpacityKey) ?? 0.2;
    _useBackgroundMonet = prefs.getBool(_bgMonetKey) ?? true;
    _useTextShadow = prefs.getBool(_textShadowKey) ?? false;
    _textShadowBlur =
        prefs.getDouble(_textShadowBlurKey) ?? AppTheme.defaultTextShadowBlur;
    notifyListeners();
  }

  /// 切换「自定义背景图片」开关。
  Future<void> setUseBackgroundImage(bool enabled) async {
    if (_useBackgroundImage == enabled) return;
    _useBackgroundImage = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bgImageEnabledKey, enabled);
  }

  /// 切换「按背景图莫奈取色」开关（默认开启）。
  /// 关闭后背景图仍正常显示，但不参与主题种子色（回落到系统/手动/默认色）。
  Future<void> setUseBackgroundMonet(bool enabled) async {
    if (_useBackgroundMonet == enabled) return;
    _useBackgroundMonet = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bgMonetKey, enabled);
  }

  /// 切换「文字阴影」开关（默认开启）。
  ///
  /// 开关值独立持久化，但只在启用自定义背景图片时才实际影响渲染
  /// （见 [useTextShadowEffective]）：关闭背景图时设置项保留用户选择，
  /// 重新开启背景图后沿用。
  Future<void> setUseTextShadow(bool enabled) async {
    if (_useTextShadow == enabled) return;
    _useTextShadow = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_textShadowKey, enabled);
  }

  /// 设置文字阴影磅数（阴影模糊半径，见 [AppTheme.textShadowsFor]）。
  ///
  /// 与开关一样只在启用背景图 + 阴影时影响渲染，值本身独立持久化。
  Future<void> setTextShadowBlur(double blur) async {
    final clamped = blur.clamp(
      AppTheme.minTextShadowBlur,
      AppTheme.maxTextShadowBlur,
    );
    if (_textShadowBlur == clamped) return;
    _textShadowBlur = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_textShadowBlurKey, clamped);
  }

  /// 设置背景图片路径（原生端拷贝到 filesDir 后的真实路径）。
  ///
  /// 路径变化时清空旧取色结果，由 app.dart 桥接异步重新提取并调用
  /// [setBackgroundSeedColor]。传 null 表示清除背景图。
  Future<void> setBackgroundImagePath(String? path) async {
    if (_backgroundImagePath == path) return;
    _backgroundImagePath = path;
    _backgroundSeedColor = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (path != null) {
      await prefs.setString(_bgImagePathKey, path);
    } else {
      await prefs.remove(_bgImagePathKey);
    }
  }

  /// 设置背景图片模糊程度（高斯模糊 sigma，0~30）。
  Future<void> setBackgroundBlur(double blur) async {
    final clamped = blur.clamp(0.0, 30.0);
    if (_backgroundBlur == clamped) return;
    _backgroundBlur = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_bgBlurKey, clamped);
  }

  /// 设置背景图片透明度（0.2~1.0，1.0 完全显示图片）。
  Future<void> setBackgroundOpacity(double opacity) async {
    final clamped = opacity.clamp(0.2, 1.0);
    if (_backgroundOpacity == clamped) return;
    _backgroundOpacity = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_bgOpacityKey, clamped);
  }

  /// 更新背景图片提取的主色（由 app.dart 桥接在路径变化后调用）。
  ///
  /// 仅运行时保存、不落盘（颜色随背景图变化）；传 null 表示提取失败，
  /// effectiveSeedColor 自动回落到系统壁纸色/手动色/默认色。
  void setBackgroundSeedColor(Color? color) {
    if (_backgroundSeedColor == color) return;
    _backgroundSeedColor = color;
    notifyListeners();
  }
}
