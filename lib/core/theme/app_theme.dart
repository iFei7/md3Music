import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../widgets/app_background.dart';

/// 路由过渡：M3 FadeForwards 动效 + 页面自带背景。
///
/// 启用全局背景图时页面背景透明，路由过渡中新旧页面内容会叠加重叠。
/// 本 builder 给每个 MaterialPageRoute 的过渡 child **内嵌 [AppBackground]**，
/// 使背景图作为页面的一部分一起滑动入场（随画面位移，无跳变），且背景图
/// 不透明盖住下层旧页面（无重叠）。对所有 MaterialPageRoute 全局生效。
class _BgSafeFadeForwardsBuilder extends PageTransitionsBuilder {
  const _BgSafeFadeForwardsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 背景作为页面底层，随 FadeForwards 一起滑动/淡入
    final withBg = Stack(
      fit: StackFit.expand,
      children: [
        const AppBackground(),
        child,
      ],
    );
    // FadeForwards 基础动效：新页面右侧滑入 + 淡入（无白色屏障层）
    return FadeForwardsPageTransitionsBuilder().buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      withBg,
    );
  }
}

class AppTheme {
  AppTheme._();

  /// 预设种子色（sonify 红 + Material 3 官方 Theme Builder 的 key tone 40）。
  ///
  /// sonify 重设计（批次 0，方案 §0.2/§9.1）：sonify 红 #F54047 置于索引 0
  /// 作为新默认（对应深色模式 #E64366 由 [sonifyPrimaryDark] 承载），原默认蓝
  /// #0061A4 降为备选；其余 7 色保持原有顺序不变。
  ///
  /// **兼容性说明**：手动种子色以 ARGB 整数持久化（theme_provider.dart
  /// `manual_seed_color`），不存索引——重排预设色后，已显式选择过颜色的用户
  /// 主题不受任何影响；仅"从未手动选过色"的用户默认观感从蓝变为 sonify 红。
  static const List<Color> presetSeedColors = [
    Color(0xFFF54047), // sonify 红（新默认，索引 0）
    Color(0xFF0061A4), // 蓝（原默认，降为备选）
    Color(0xFF6750A4), // 紫（M3 默认）
    Color(0xFF006A6A), // 青绿
    Color(0xFF386A20), // 绿
    Color(0xFF7E5700), // 黄
    Color(0xFF8C4A00), // 橙
    Color(0xFFB3261E), // 红
    Color(0xFF984061), // 粉
  ];

  /// 默认种子色（sonify 红 #F54047，方案 §0.2 色板表 colorPrimary 浅色值，
  /// 出处 ref-sonify `ui/theme/Color.kt:8`）。
  /// 用于未启用系统主题色且未手动选择时的兜底。
  /// 必须独立定义为 const，不能引用 [presetSeedColors] 的索引（非常量表达式）。
  static const Color defaultSeedColor = Color(0xFFF54047);

  /// sonify 主色深色模式取值 #E64366（Color.kt:9）。
  ///
  /// 浅/深模式的种子色是同一个（种子色经 ColorScheme.fromSeed 按亮度各自展开
  /// tonal 色阶），此常量供未来按亮度区分"品牌原色"的直用场景（如播放页
  /// 强调色徽章）按需取用；本批次全局主色仍统一走 ColorScheme.primary。
  static const Color sonifyPrimaryDark = Color(0xFFE64366);

  // CJK 字体回退链 - 按平台优先级排序:
  // 1) Web 浏览器(Windows + Edge) 优先用系统自带的 "Microsoft YaHei" (无需下载)
  // 2) macOS / iOS: PingFang SC
  // 3) Linux: WenQuanYi Micro Hei
  // 4) 通用 sans-serif（Android 上解析为系统默认字体，含系统 CJK 支持）
  // 注意：不把任何打包字体放入全局回退链——否则「系统默认」模式下 CJK 也会
  // 回退到打包字体，导致与字体选项显示不一致（用户反馈过此问题）。
  // （内置 SimHei 已移除；自定义字体由「自定义字体」模式按需 FontLoader 注册。）
  static const List<String> _cjkFontFallback = [
    'Microsoft YaHei',
    'Microsoft YaHei UI',
    'PingFang SC',
    'Hiragino Sans GB',
    'WenQuanYi Micro Hei',
    'Source Han Sans CN',
    'Source Han Sans SC',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'sans-serif',
  ];

  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: defaultSeedColor,
      brightness: Brightness.light,
    );
    return _buildTheme(colorScheme, Brightness.light);
  }

  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: defaultSeedColor,
      brightness: Brightness.dark,
    );
    return _buildTheme(colorScheme, Brightness.dark);
  }

  /// 根据传入的种子色构建浅色主题。
  ///
  /// 用于「莫奈色」开关启用时，由 ThemeProvider 传入系统提取的主色。
  ///
  /// [fontFamily] 控制全局字体：
  /// - null：使用系统字体优先（让 Flutter 走系统字体链）
  /// - 'UserCustomFont'：使用用户通过 SAF 选择并加载的自定义字体
  static ThemeData lightThemeFromSeed(
    Color seedColor, {
    String? fontFamily,
    bool emphasized = true,
    NavigationDestinationLabelBehavior labelBehavior =
        NavigationDestinationLabelBehavior.alwaysHide,
  }) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    );
    return _buildTheme(
      colorScheme,
      Brightness.light,
      fontFamily: fontFamily,
      emphasized: emphasized,
      labelBehavior: labelBehavior,
    );
  }

  /// 根据传入的种子色构建深色主题。
  ///
  /// [useOledBlack] 为 true 时启用 OLED 纯黑变体：
  /// 将 [ColorScheme] 的 surface 系列覆盖为 [Colors.black] / 极深灰，
  /// 保留 onSurface 等前景色不变（保证对比度），
  /// surfaceContainerHigh/Highest 用极深灰保留卡片层级感。
  ///
  /// [fontFamily] 控制全局字体，参见 [lightThemeFromSeed]。
  static ThemeData darkThemeFromSeed(
    Color seedColor, {
    bool useOledBlack = false,
    String? fontFamily,
    bool emphasized = true,
    NavigationDestinationLabelBehavior labelBehavior =
        NavigationDestinationLabelBehavior.alwaysHide,
  }) {
    var colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
    if (useOledBlack) {
      colorScheme = colorScheme.copyWith(
        surface: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: Colors.black,
        surfaceContainer: Colors.black,
        // High/Highest 保留极深灰，让卡片/底栏仍有微妙层级感
        surfaceContainerHigh: const Color(0xFF111111),
        surfaceContainerHighest: const Color(0xFF1A1A1A),
        // onSurface 等前景色保持不变，确保文字对比度
        // inverseSurface 保持不变，确保 Snackbar 反色正常
      );
    }
    return _buildTheme(
      colorScheme,
      Brightness.dark,
      fontFamily: fontFamily,
      emphasized: emphasized,
      labelBehavior: labelBehavior,
    );
  }

  static ThemeData _buildTheme(
    ColorScheme colorScheme,
    Brightness brightness, {
    String? fontFamily,
    bool emphasized = true,
    NavigationDestinationLabelBehavior labelBehavior =
        NavigationDestinationLabelBehavior.alwaysHide,
  }) {
    final isLight = brightness == Brightness.light;

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: brightness,
      // 全局路由过渡：Android 用 FadeForwards（滑动 + 淡入）+ 过渡期间
      // 背景遮罩（避免透明页面过渡重叠，完成后再露出背景图）。
      // 其余平台（iOS/macOS）保留系统默认 Cupertino 过渡。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _BgSafeFadeForwardsBuilder(),
        },
      ),
      // fontFamily 为 null 时，Flutter 会走系统字体链（Android 上是 Roboto +
      // Noto Sans CJK），符合"优先展示用户手机字体"需求。
      // fontFamilyFallback 兜底链保证系统字体缺字符时仍能命中候选。
      fontFamily: fontFamily,
      fontFamilyFallback: _cjkFontFallback,
      scaffoldBackgroundColor: colorScheme.surface,
      cardTheme: CardThemeData(
        elevation: isLight ? 1 : 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: colorScheme.surfaceContainer,
        surfaceTintColor: colorScheme.surfaceTint,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: isLight ? 3 : 1,
        surfaceTintColor: colorScheme.surfaceTint,
        centerTitle: true,
        // 显式设置状态栏样式，避免 ScrollAwareAppBar 透明背景时
        // Flutter 根据 Colors.transparent（luminance=0）误判为深色背景，
        // 导致浅色主题下状态栏图标变白看不清。
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              isLight ? Brightness.dark : Brightness.light,
          statusBarBrightness:
              isLight ? Brightness.light : Brightness.dark,
        ),
        // 显式传 fontFamily，确保 AppBar 标题在切换自定义字体时立即生效
        // （ThemeData.fontFamily 不会自动注入到 *ThemeData 中独立设置的 TextStyle）
        titleTextStyle: _buildTextStyle(
          colorScheme.onSurface,
          22,
          FontWeight.w400,
          fontFamily: fontFamily,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 80,
        backgroundColor: colorScheme.surface,
        // 关闭原生 NavigationIndicator：胶囊由 responsive_layout 的
        // _CapsuleBounce 自定义绘制（外观与原一致），以支持点击后胶囊
        // 水平超出回弹动画；背景图模式下 _CapsuleBounce 隐藏胶囊。
        indicatorColor: Colors.transparent,
        surfaceTintColor: colorScheme.surfaceTint,
        elevation: 0,
        // 底栏文字行为：由用户设置控制（始终显示 / 仅当前页 / 始终不显示）。
        // NavigationDestination.label 仍需传（API 必填），作为无障碍朗读文本。
        labelBehavior: labelBehavior,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.onSecondaryContainer);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant);
        }),
        // 显式传 fontFamily：NavigationBar 的 labelTextStyle 走 WidgetStateProperty，
        // 不会自动合并 ThemeData.fontFamily，必须显式指定才能让 tab 栏文字跟随自定义字体
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return _buildTextStyle(
              colorScheme.onSecondaryContainer,
              12,
              FontWeight.w600,
              fontFamily: fontFamily,
            );
          }
          return _buildTextStyle(
            colorScheme.onSurfaceVariant,
            12,
            FontWeight.w500,
            fontFamily: fontFamily,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colorScheme.surface,
        // 关闭原生 indicator：胶囊由 _CapsuleBounce 自定义绘制（同 navigationBar）
        indicatorColor: Colors.transparent,
        elevation: 0,
        minWidth: 80,
        minExtendedWidth: 256,
        labelType: NavigationRailLabelType.all,
        selectedIconTheme: IconThemeData(
          color: colorScheme.onSecondaryContainer,
        ),
        unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
        selectedLabelTextStyle: _buildTextStyle(
          colorScheme.onSecondaryContainer,
          12,
          FontWeight.w600,
          fontFamily: fontFamily,
        ),
        unselectedLabelTextStyle: _buildTextStyle(
          colorScheme.onSurfaceVariant,
          12,
          FontWeight.w500,
          fontFamily: fontFamily,
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        surfaceTintColor: colorScheme.surfaceTint,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primaryContainer,
        foregroundColor: colorScheme.onPrimaryContainer,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        selectedColor: colorScheme.secondaryContainer,
        // 显式传 fontFamily：搜索历史/热门搜索 chip 的 label 走这里，
        // 不指定的话不会跟随 ThemeData.fontFamily
        labelStyle: _buildTextStyle(
          colorScheme.onSurface,
          14,
          FontWeight.w500,
          fontFamily: fontFamily,
        ),
        secondaryLabelStyle: _buildTextStyle(
          colorScheme.onSecondaryContainer,
          14,
          FontWeight.w500,
          fontFamily: fontFamily,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.surfaceContainerHighest,
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: colorScheme.surfaceContainerHighest,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colorScheme.onSurfaceVariant,
        textColor: colorScheme.onSurface,
        selectedColor: colorScheme.primary,
        selectedTileColor: colorScheme.secondaryContainer,
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 1,
      ),
      // 显式把 fontFamily 注入 textTheme：发现页"每日推荐"标题、搜索页"搜索历史"/"热门搜索"标题
      // 都用 Theme.of(context).textTheme.titleLarge/titleMedium，必须显式 apply 才能跟随自定义字体
      textTheme: _buildTextTheme(
        colorScheme,
        fontFamily: fontFamily,
        emphasized: emphasized,
      ),
      primaryTextTheme: _buildTextTheme(
        colorScheme,
        fontFamily: fontFamily,
        emphasized: emphasized,
      ),
      // 全局 M3E 弹层主题：背景跟随 colorScheme（OLED 纯黑等覆盖自动生效），
      // 并把默认 24px 内边距置零，避免各弹层被内缩。
      // 97% 不透明度与公开版 `_applyBackgroundOverrides` 里的 bottomSheetTheme
      // 保持一致（让背景图透出）；若在此处写死为全不透明，弹层会比其它 surface 更实。
      extensions: <ThemeExtension<dynamic>>[
        M3EBottomSheetThemeData(
          style: M3EBottomSheetStyle(
            backgroundColor: colorScheme.surfaceContainerLow.withValues(
              alpha: 0.97,
            ),
            borderRadius: 28,
            padding: EdgeInsets.zero,
          ),
        ),
        // sonify 语义色槽位（批次 0 新增，纯增量注册，不影响既有视觉）。
        SonifyColors.fromScheme(colorScheme, isLight: isLight),
      ],
    );
  }

  /// 文字阴影磅数（阴影模糊半径）的默认值与可调范围：设置页滑块与
  /// [textShadowsFor] 共用，0 表示不模糊（只剩 1dp 偏移的硬阴影）。
  static const double defaultTextShadowBlur = 4.0;
  static const double minTextShadowBlur = 0.0;
  static const double maxTextShadowBlur = 50.0;

  /// 文字阴影：仅在启用自定义背景图片时使用（见 `_applyBackgroundOverrides`）。
  ///
  /// 取与文字色相反的柔和光晕，保证文字在模糊壁纸上仍有足够对比度：
  /// - 浅色主题（深色文字）→ 白色光晕
  /// - 深色主题（浅色文字）→ 黑色投影
  ///
  /// [blurRadius] 是用户在设置里调的「阴影磅数」，范围见
  /// [minTextShadowBlur] / [maxTextShadowBlur]。
  ///
  /// 高斯模糊会把同一份「墨水」摊到越来越大的面积上：只加大 blurRadius 的话，
  /// 单层阴影的峰值不透明度反而随磅数下降，10 磅往上肉眼几乎看不出变化。
  /// 所以磅数越高就同步补偿浓度：不透明度 0.6 → 0.95，并叠加同一层阴影
  /// （n 层叠上去的覆盖率是 1-(1-a)^n），让整个滑块行程都有可见差别。
  /// 默认磅数及以下仍是原来的单层 0.6，观感与绘制开销都不变。
  static List<Shadow> textShadowsFor(
    Brightness brightness, {
    double blurRadius = defaultTextShadowBlur,
  }) {
    final isLight = brightness == Brightness.light;
    final blur = blurRadius.clamp(minTextShadowBlur, maxTextShadowBlur);
    final t =
        ((blur - defaultTextShadowBlur) /
                (maxTextShadowBlur - defaultTextShadowBlur))
            .clamp(0.0, 1.0);
    final shadow = Shadow(
      color: (isLight ? Colors.white : Colors.black).withValues(
        alpha: 0.6 + 0.35 * t,
      ),
      blurRadius: blur,
      offset: const Offset(0, 1),
    );
    return List<Shadow>.filled(1 + (3 * t).round(), shadow);
  }

  /// 给 [base] 的所有文字层级统一附加 [shadows]
  /// （TextTheme.apply 不支持 shadows，只能逐级 copyWith）。
  static TextTheme applyTextShadows(TextTheme base, List<Shadow> shadows) {
    TextStyle? withShadows(TextStyle? style) => style?.copyWith(shadows: shadows);
    return base.copyWith(
      displayLarge: withShadows(base.displayLarge),
      displayMedium: withShadows(base.displayMedium),
      displaySmall: withShadows(base.displaySmall),
      headlineLarge: withShadows(base.headlineLarge),
      headlineMedium: withShadows(base.headlineMedium),
      headlineSmall: withShadows(base.headlineSmall),
      titleLarge: withShadows(base.titleLarge),
      titleMedium: withShadows(base.titleMedium),
      titleSmall: withShadows(base.titleSmall),
      bodyLarge: withShadows(base.bodyLarge),
      bodyMedium: withShadows(base.bodyMedium),
      bodySmall: withShadows(base.bodySmall),
      labelLarge: withShadows(base.labelLarge),
      labelMedium: withShadows(base.labelMedium),
      labelSmall: withShadows(base.labelSmall),
    );
  }

  /// 去掉 [base] 各文字层级上的阴影。
  ///
  /// 文字背景是实色时壁纸被完全盖住，阴影没有可读性收益，只会让文字发虚，
  /// 所以实色表面上的文字一律不带阴影（见 `NoTextShadow`）。
  /// 全局没开阴影时是无操作（空阴影列表与无阴影渲染一致）。
  static TextTheme stripTextShadows(TextTheme base) =>
      applyTextShadows(base, const <Shadow>[]);

  /// 单个 [TextStyle] 版的 [stripTextShadows]。
  static TextStyle? withoutTextShadow(TextStyle? style) =>
      style?.copyWith(shadows: const <Shadow>[]);

  static TextStyle _buildTextStyle(
    Color color,
    double size,
    FontWeight weight, {
    String? fontFamily,
  }) {
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      // 显式指定 fontFamily：未指定时 Flutter 不会自动从 ThemeData.fontFamily 继承
      // （仅在 DefaultTextStyle 合并路径下继承；*ThemeData 中独立设置的 TextStyle 不走该路径）
      fontFamily: fontFamily,
      letterSpacing: size >= 20 ? 0 : 0.25,
      height: size >= 20 ? 1.3 : 1.4,
    );
  }

  static TextTheme _buildTextTheme(
    ColorScheme colorScheme, {
    String? fontFamily,
    bool emphasized = true,
  }) {
    final base = TextTheme(
      displayLarge: TextStyle(
        fontSize: 57,
        fontWeight: FontWeight.w400,
        height: 1.12,
        letterSpacing: -0.25,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      displayMedium: TextStyle(
        fontSize: 45,
        fontWeight: FontWeight.w400,
        height: 1.16,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        height: 1.22,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w400,
        height: 1.25,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w400,
        height: 1.29,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        height: 1.33,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.27,
        letterSpacing: 0,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.5,
        letterSpacing: 0.15,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.43,
        letterSpacing: 0.1,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.5,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.43,
        letterSpacing: 0.25,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.33,
        letterSpacing: 0.4,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.43,
        letterSpacing: 0.1,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.33,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.45,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
        fontFamily: fontFamily,
      ),
    );
    // M3E 强调排版：统一提升字重并写入 wght/opsz 字轴。
    // rond 固定 0：不引入圆角字轴，避免改变字形。
    return emphasized ? M3ETypography.emphasized(base, rond: 0) : base;
  }
}

/// sonify 语义色槽位（UI 重设计批次 0，方案 §0.2/§0.3 色板表）。
///
/// 设计模型与 sonify 一致（`ui/theme/Color.kt:8-18`、`Theme.kt:20-38`）：
/// **只有主色随主题（种子色）变化，中性槽位固定为白/黑两极**——用户自定义
/// 种子色时全 app 继续生效（等价于 sonify 换主色的假设场景）。
///
/// 槽位与 sonify 取值对照：
/// | 槽位 | 浅色 | 深色 | sonify 出处 |
/// |---|---|---|---|
/// | [primary] | 种子色派生（默认 #F54047） | 种子色派生（深色阶，源值 #E64366） | Color.kt:8-9 |
/// | [background] | #FFFFFF | #000000 | Color.kt:12-13 |
/// | [onBackground] | #000000 | #FFFFFF | Theme.kt:23/33 反色映射 |
/// | [textSecondary] | #88878E | #8E8D93 | Color.kt:10-11（headline） |
/// | [surfaceGroup] | #F2F1F6 | #000002 | Color.kt:15-16（settingBack） |
/// | [surfaceCard] | #FFFFFF | #1C1C1E | Color.kt:17-18（settingContainerBack） |
/// | [scrim] | 黑 α0.5 | 白 α0.5 | Title.kt:1145（subTitle alpha 0.5） |
///
/// 注意：本批次（0）纯新增，不改变任何既有页面的取色路径——既有页面继续用
/// `ColorScheme`；后续批次把页面逐个切到这些槽位。
class SonifyColors extends ThemeExtension<SonifyColors> {
  const SonifyColors({
    required this.primary,
    required this.background,
    required this.onBackground,
    required this.textSecondary,
    required this.surfaceGroup,
    required this.surfaceCard,
    required this.scrim,
  });

  /// 主色：跟随种子色（保证 lite 的种子色/莫奈/封面取色/手动选择全链路继续生效）。
  /// 默认种子色即 sonify 红 #F54047（见 [AppTheme.defaultSeedColor]）。
  final Color primary;

  /// 页面底色：纯白 / 纯黑（sonify 白黑两极模型，区别于 M3 灰阶多档）。
  final Color background;

  /// 页面底色上的文字/图标色（onBackground 反色映射）。
  final Color onBackground;

  /// 次级文字/占位/辅助说明色。
  final Color textSecondary;

  /// 分组页底色（设置系整页背景，iOS 分组风）。
  final Color surfaceGroup;

  /// 分组卡底色（设置白卡 / 播放页内嵌卡）。
  ///
  /// OLED 纯黑模式下（lite 特色，保留共存）：后续批次消费此槽位时应回退到
  /// `surfaceContainerHigh #111111 / Highest #1A1A1A`（app_theme.dart OLED
  /// 覆盖值），与 sonify #1C1C1E 同语义（差 1 个灰阶，取 lite 现值避免回归）。
  final Color surfaceCard;

  /// 玻璃下内容淡出用的蒙层色（Title.kt:1145 alpha 0.5 语义）。
  final Color scrim;

  /// 由 [ColorScheme] 构建：primary 派生自种子色，中性槽位按亮度取 sonify 固定值。
  factory SonifyColors.fromScheme(ColorScheme scheme, {required bool isLight}) {
    return SonifyColors(
      primary: scheme.primary,
      background: isLight ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
      onBackground: isLight ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
      textSecondary:
          isLight ? const Color(0xFF88878E) : const Color(0xFF8E8D93),
      surfaceGroup:
          isLight ? const Color(0xFFF2F1F6) : const Color(0xFF000002),
      surfaceCard:
          isLight ? const Color(0xFFFFFFFF) : const Color(0xFF1C1C1E),
      scrim: isLight
          ? Colors.black.withValues(alpha: 0.5)
          : Colors.white.withValues(alpha: 0.5),
    );
  }

  /// 从上下文取槽位；未注册（如测试用裸 MaterialApp）时按当前亮度兜底构造。
  static SonifyColors of(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<SonifyColors>();
    if (ext != null) return ext;
    return SonifyColors.fromScheme(
      theme.colorScheme,
      isLight: theme.brightness == Brightness.light,
    );
  }

  @override
  SonifyColors lerp(SonifyColors other, double t) {
    if (identical(this, other)) return this;
    return SonifyColors(
      primary: Color.lerp(primary, other.primary, t)!,
      background: Color.lerp(background, other.background, t)!,
      onBackground: Color.lerp(onBackground, other.onBackground, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      surfaceGroup: Color.lerp(surfaceGroup, other.surfaceGroup, t)!,
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }

  @override
  SonifyColors copyWith({
    Color? primary,
    Color? background,
    Color? onBackground,
    Color? textSecondary,
    Color? surfaceGroup,
    Color? surfaceCard,
    Color? scrim,
  }) {
    return SonifyColors(
      primary: primary ?? this.primary,
      background: background ?? this.background,
      onBackground: onBackground ?? this.onBackground,
      textSecondary: textSecondary ?? this.textSecondary,
      surfaceGroup: surfaceGroup ?? this.surfaceGroup,
      surfaceCard: surfaceCard ?? this.surfaceCard,
      scrim: scrim ?? this.scrim,
    );
  }
}

/// sonify 字体排印 token（方案 §0.3 排印表）。
///
/// 与 lite 既有 `_buildTextTheme`（M3 梯度 + M3E 可变字体强调）**并行共存**：
/// 一级页大标题等 sonify 形态的文本直接取本类的独立样式，不走 M3 display
/// 梯度；M3E 强调排版继续用于播放页歌名（lite 特色，不回退）。
///
/// 颜色不写死：调用处用 `copyWith(color:)` 绑定 [SonifyColors] /
/// `ColorScheme.onSurface`，保证背景图/深浅色模式全兼容。
///
/// 字重规则（方案 §0.3）：Medium 为主、Bold 用于标题、禁用 w600 以上。
/// 字体族不指定：跟随全局 ThemeData.fontFamily（含用户自定义字体切换）。
abstract final class SonifyTextStyles {
  /// 页面大标题（一级页列表首 item）：35sp Bold，lineHeight 40。
  /// 出处：Title.kt:1135-1140。
  static const TextStyle largeTitle = TextStyle(
    fontSize: 35,
    fontWeight: FontWeight.w700,
    height: 40 / 35,
    letterSpacing: 0,
  );

  /// 折叠后顶栏小标题：18.5sp Bold。
  /// 出处：Title.kt:1063-1067。
  static const TextStyle barTitle = TextStyle(
    fontSize: 18.5,
    fontWeight: FontWeight.w700,
  );

  /// 正文基准：16sp，lineHeight 21，letterSpacing 0.0618sp。
  /// 出处：Type.kt:9-14。
  static const TextStyle body = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 21 / 16,
    letterSpacing: 0.0618,
  );

  /// 列表次级文本：13sp（全应用最高频字号，sonify 全仓 31 处）。
  static const TextStyle listItem = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
  );

  /// 卡片标题：16sp Medium（字重统计 Medium 26 处最多）。
  static const TextStyle cardTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
  );

  /// 分区标题：18sp Bold（统计 18 处，Bold 17 处）。
  static const TextStyle sectionTitle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
  );
}

/// sonify 间距 / 布局 token（方案 §0.3 间距表）。
abstract final class SonifySpacing {
  /// 卡片水平外边距：16.5dp。出处：YosRoundColumn.kt:22（defaultPadding）。
  static const double cardMargin = 16.5;

  /// 大标题/内容水平边距：20dp。出处：Title.kt:203（titleHorizontalPadding）。
  static const double titleMargin = 20;

  /// 设置/资料库分组标题边距：32dp。出处：Title.kt:202 注释。
  static const double groupMargin = 32;

  /// 网格列间距：15dp。出处：Title.kt:416-417。
  static const double gridH = 15;

  /// 网格行间距：20dp。出处：Title.kt:416-417。
  static const double gridV = 20;

  /// 网格边缘内边距：18dp。出处：Title.kt:419-420。
  static const double gridEdge = 18;

  /// 顶栏高度：54dp。出处：Title.kt:989。
  static const double topBar = 54;

  /// 自适应网格最小图尺寸：150dp。出处：AdaptiveImageLayout.kt:9。
  static const double coverRailMin = 150;

  /// 列表底部避让（迷你条+导航）：sonify 134dp（Title.kt:197）。
  /// **lite 实际避让以 app.dart 的 MediaQuery padding 注入为准（现值更高），
  /// 消费时以注入值优先，此 token 仅作 sonify 参照，勿直接硬编码进列表。**
  static const double bottomClearanceReference = 134;
}

/// sonify 动效 token（方案 §0.3 动效表）。
abstract final class SonifyMotion {
  /// 大标题折叠吸附：180ms EaseOutCubic。出处：Title.kt:745-753。
  static const Duration collapseSnap = Duration(milliseconds: 180);
  static const Curve collapseSnapCurve = Curves.easeOutCubic;

  /// 顶栏背景/小标题淡入出：120ms。出处：Title.kt:952-953, 1050-1060。
  static const Duration barFade = Duration(milliseconds: 120);

  /// 玻璃圆钮材质切换：150ms。出处：Title.kt:940-941。
  static const Duration glassAlpha = Duration(milliseconds: 150);

  /// 折叠大标题透明度公式增益：`1 + offset/height × 1.8`，clamp 0~1。
  /// 出处：Title.kt:588-589。
  static const double collapseAlphaGain = 1.8;
}
