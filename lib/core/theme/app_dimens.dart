import 'package:material_ui/material_ui.dart';

/// 全局尺寸设计 token（间距 / 圆角 / 布局约束）。
///
/// 目标：把散落在各页面的行内魔法数字（`EdgeInsets.all(16)`、
/// `SizedBox(height: 12)`、`BorderRadius.circular(8)`…）收敛到一套**等比**尺度，
/// 让间距、圆角、留白节奏在全项目一致、可扫描、可整体调整。
///
/// 设计理念：
/// - **4dp 基准、8dp 节奏**（8pt grid，允许 4dp 半档）。所有值都落在 4 的倍数上，
///   避免 6 / 10 / 14 / 18 这类离格值造成的视觉抖动。
/// - **语义命名**（xs / sm / md / lg / xl…）而非裸数字：迁移时强制在有限档位里
///   做选择，天然收敛不一致。
/// - **纯 dp**：全局「显示大小」由 [DisplayScaleScope]（ui_density.dart）统一缩放，
///   token 一律写裸 dp，不要在这里做任何缩放。
///
/// 迁移约定：`EdgeInsets.all(16)` → `EdgeInsets.all(AppSpacing.lg)`；
/// `SizedBox(height: 12)` → `const Gap(AppSpacing.md)` 或 `SizedBox(height: AppSpacing.md)`。
class AppSpacing {
  AppSpacing._();

  /// 0dp —— 显式表达"无间距"，比裸 0 更有意图。
  static const double none = 0;

  /// 2dp —— 极小间距：图标与文字、徽标内缩等。
  static const double xxs = 2;

  /// 4dp —— 基准单位：紧凑元素间的最小呼吸。
  static const double xs = 4;

  /// 8dp —— 小间距：列表项内垂直间距、chip 间距。
  static const double sm = 8;

  /// 12dp —— 中小间距：卡片内边距、段内元素间距。
  static const double md = 12;

  /// 16dp —— 标准间距：页面左右边距、Section 内边距（默认首选值）。
  static const double lg = 16;

  /// 24dp —— 大间距：Section 之间、主要内容块的分隔。
  static const double xl = 24;

  /// 32dp —— 超大间距：页面顶部留白、主要分区之间的强分隔。
  static const double xxl = 32;

  /// 48dp —— 巨大间距：空状态居中留白、大屏分区。
  static const double xxxl = 48;
}

/// 圆角 token，对齐 Material 3 shape scale（extra-small 4 → extra-large 28）。
///
/// 迁移约定：`BorderRadius.circular(8)` → `AppRadius.smAll`（或 `AppRadius.sm`
/// 在需要 double 的场景）。
class AppRadius {
  AppRadius._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 28;

  // —— 语义档位（UI 重设计·批次 1 新增）——
  // 命名对应具体容器，收敛各页面漂移的圆角值；现有组件硬编码值（如卡片 16、
  // 底部弹层 28）保持不变，页面批次再逐个替换到这里的 token。

  /// 20dp —— 卡片圆角：专辑卡、歌单卡、设置分组卡等封面驱动内容卡。
  /// 比 MD3 extra-large(28) 低一档，让封面图占比更大、卡片更"贴"内容。
  static const double card = 20;

  /// 28dp —— 弹层圆角：底部弹层 / 抽屉类浮层（与 MD3 extra-large 对齐，
  /// 现有 bottomSheetTheme 已是 28，收编为 token 语义）。
  static const double sheet = 28;

  /// 32dp —— Dock 圆角：悬浮播放 Dock 的圆角矩形外形（比弹层更圆润一档，
  /// 悬浮元素圆角略大于其依附的容器，符合视觉"内小外大"的嵌套惯例）。
  static const double dock = 32;

  /// 胶囊 / 全圆角（配合 [StadiumBorder] 或极大半径）。
  static const double full = 999;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));

  /// 卡片圆角（[card]）。
  static const BorderRadius cardAll = BorderRadius.all(Radius.circular(card));

  /// 弹层圆角（[sheet]）。
  static const BorderRadius sheetAll = BorderRadius.all(Radius.circular(sheet));

  /// Dock 圆角（[dock]）。
  static const BorderRadius dockAll = BorderRadius.all(Radius.circular(dock));
}

/// 轻玻璃质感参数 token（UI 重设计·批次 1 新增）。
///
/// 设计方向：**低干扰的轻玻璃**——适度透明度 + 轻模糊 + 1px 高光描边，
/// 玻璃只做"底座"而非视觉主角，让封面与内容走在前面。
///
/// 收编来源：`lib/core/widgets/liquid_glass_container.dart` 原本内联的
/// 魔法数字（blur 18 / fill 0.12 / 左上高光 0.35 / 顶部高光 0.28 /
/// 右下渐隐 0.06）。收编时**数值逐项保持等价**，现有 Dock 渲染零变化；
/// 深浅色各给一组参数（当前两组取值相同，等价基线），页面批次可在此基础上
/// 按亮度微调而不再碰组件内部。
///
/// 约束：模糊只允许作用于容器自身区域，**禁止新增全屏 BackdropFilter**；
/// [blurSigmaMax] 是本项目的模糊上限参考，超过它的实时模糊一律视为滥用。
///
/// 注意：[LiquidGlassContainer] 的构造默认值须是常量字面量（Dart 构造默认
/// 值无法引用另一常量对象的实例字段），当前写作 18 / 0.12，与本组
/// [AppGlass.dark] 逐项相等——后续调整参数时两处必须同步。
class AppGlass {
  AppGlass._();

  /// 描边线宽：1px 高光描边（更宽会变成"描框"，玻璃感变塑料感）。
  static const double borderStrokeWidth = 1;

  /// 模糊上限参考（sigma）：收编值 18 之外的上限，任何玻璃容器不得超过。
  /// 取 30 与背景图模糊设置上限（ThemeProvider._backgroundBlur clamp 0~30）
  /// 对齐，全项目共用同一条模糊天花板。
  static const double blurSigmaMax = 30;

  /// 深色玻璃参数组（当前与浅色组等价，作为收编基线）。
  static const GlassParams dark = GlassParams(
    blurSigma: 18,
    fillAlpha: 0.12,
    borderHighlightAlpha: 0.35,
    topHighlightAlpha: 0.28,
    borderFadeAlpha: 0.06,
  );

  /// 浅色玻璃参数组（当前与深色组等价，作为收编基线；
  /// 后续批次若要在浅色下加强高光可读性，只调这里）。
  static const GlassParams light = GlassParams(
    blurSigma: 18,
    fillAlpha: 0.12,
    borderHighlightAlpha: 0.35,
    topHighlightAlpha: 0.28,
    borderFadeAlpha: 0.06,
  );

  /// 按亮度取玻璃参数组。
  static GlassParams of(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;
}

/// 单组玻璃渲染参数（不可变，字段均为 const 构造可用的字面量）。
class GlassParams {
  const GlassParams({
    required this.blurSigma,
    required this.fillAlpha,
    required this.borderHighlightAlpha,
    required this.topHighlightAlpha,
    required this.borderFadeAlpha,
  });

  /// 背景模糊强度（sigma），只作用于玻璃容器自身区域。
  final double blurSigma;

  /// 玻璃"体色"叠色的不透明度（surface 色 × 此 alpha），
  /// 保证玻璃上的内容可读。
  final double fillAlpha;

  /// 1px 渐变描边的左上高光不透明度（白色起点，模拟受光面）。
  final double borderHighlightAlpha;

  /// 顶部内侧高光线的峰值不透明度（上缘细亮线，左右渐隐）。
  final double topHighlightAlpha;

  /// 描边渐变的右下渐隐端不透明度（混入 onSurface，暗色下仍可感知轮廓）。
  final double borderFadeAlpha;
}

/// 大屏 / 平板布局约束 token。
///
/// 「重组而非拉伸」原则：宽屏下不让内容行 / 文本无脑撑满，而是约束到一个
/// 可读宽度并居中，多出来的宽度用于分栏或留白。
class AppLayout {
  AppLayout._();

  /// 单栏内容的最大宽度：超过它就居中留白，而不是继续拉长（如设置项、表单、
  /// 单列列表在平板上的表现）。约等于 MD3 body pane 上限。
  static const double maxContentWidth = 840;

  /// 正文文本的舒适阅读宽度上限（歌词、长段描述），约 60–75 字符行长。
  static const double readableMaxWidth = 640;

  /// 网格每列的目标宽度（配合 [gridColumnsForWidth]）。
  static const double gridTargetExtent = 200;

  /// 双列（列表-详情）左列固定宽度。M3 list-detail master pane 推荐 280–300dp。
  static const double twoPaneMasterWidth = 300;

  /// 双列右列内容的最大宽度：超过就居中留白，与 [maxContentWidth] 同一
  /// 「重组而非拉伸」原则（约等于 MD3 body pane 在双列下的舒适上限）。
  static const double twoPaneDetailMaxWidth = 720;
}

/// 等距方形间隔组件，替代裸 `SizedBox(height: x)` / `SizedBox(width: x)`。
///
/// 同时设置宽高为 [extent]，在 [Column] 与 [Row] 中都能正确撑出间距
/// （Flex 交叉轴方向的固定尺寸无副作用）。需要非方形间隔时仍直接用 `SizedBox`。
class Gap extends StatelessWidget {
  const Gap(this.extent, {super.key});

  final double extent;

  @override
  Widget build(BuildContext context) => SizedBox(width: extent, height: extent);
}
