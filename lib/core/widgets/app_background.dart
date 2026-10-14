import 'dart:io';
import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../utils/artwork_color_extractor.dart';

/// 内置保底壁纸：用户未选择自定义背景图（或清除后）时作为默认背景。
const String kDefaultWallpaperAsset = 'assets/images/default_wallpaper.jpg';

/// 当前背景图的共享 ImageProvider：AppBackground 主体与页面顶栏（如搜索页
/// SliverAppBar flexibleSpace）通过同一方法 + 相同 cacheWidth 得到相同 key，
/// ImageCache 命中同一解码结果，避免同一张图各自解码。
/// 路径无效（未选/已删除）时回落内置默认壁纸。
ImageProvider backgroundImageProvider(
  ThemeProvider tp, {
  required int cacheWidth,
}) {
  final path = tp.backgroundImagePath;
  final file = (path != null && path.isNotEmpty) ? File(path) : null;
  if (file != null && file.existsSync()) {
    return ResizeImage(FileImage(file), width: cacheWidth);
  }
  return ResizeImage(
    const AssetImage(kDefaultWallpaperAsset),
    width: cacheWidth,
  );
}

/// 顶栏沉浸壁纸层：用于 SliverAppBar flexibleSpace 等头部区域的背景。
///
/// 与 [AppBackground] 同层结构（surface 打底 + 模糊 + 透明度 + cover 图），
/// 但按**全屏尺寸 + topCenter 对齐**渲染：图片缩放比例与主体背景一致，
/// 头部区域显示背景图在自身位置处的切片，与页面主体视觉连续。
/// 外层需自行裁剪（Sliver 区域），避免全屏溢出覆盖下方内容。
class WallpaperHeaderBackground extends StatelessWidget {
  const WallpaperHeaderBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return OverflowBox(
      alignment: Alignment.topCenter,
      minWidth: size.width,
      maxWidth: size.width,
      minHeight: size.height,
      maxHeight: size.height,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: const AppBackground(),
      ),
    );
  }
}
/// 封面驱动背景的取色结果（UI 重设计·批次 1 预留 API）。
///
/// [base] 是压暗去饱和后的低干扰背景色（近黑，保留封面色相），
/// [accent] 是明度较高的同相强调色（进度条/高亮点等小面积点缀用），
/// [source] 是封面原始主色（供调试与更深度派生）。
class CoverDrivenPalette {
  const CoverDrivenPalette({
    required this.base,
    required this.accent,
    required this.source,
  });

  /// 低干扰背景底色：封面主色压暗到 lightness 0.10–0.20、
  /// 饱和收敛到 0.28–0.55——保留"这首歌的氛围"，但绝不与前景内容抢戏。
  final Color base;

  /// 同相强调色：饱和 0.5–0.8、明度 0.55–0.75，只允许小面积使用。
  final Color accent;

  /// 封面原始主色（[ArtworkColorExtractor.loadPalette] 的合格候选）。
  final Color source;
}

/// 「封面驱动页面背景」可选作用域（UI 重设计·批次 1 预留 API）。
///
/// **本批次默认关闭（[enabled] = false）、未接线到任何页面**，只交付 API：
/// 后续批次在页面外层包一个 [CoverDrivenBackgroundScope]（传入当前封面
/// url），页面背景层即可通过 [CoverDrivenBackgroundScope.of] 拿到
/// [CoverDrivenPalette] 做渐变底色。
///
/// 取色走 [ArtworkColorExtractor.loadPalette]：网络封面固定 512 宽解码、
/// 与播放器 UI 封面共用同一 ImageCache 键（该共享语义不可破坏，这里
/// 不做任何额外包装），本地封面走其默认 480 降采样，无新增取数路径。
///
/// 派生规则（[CoverDrivenPalette]）：从 palette 按占比降序找第一个合格
/// 候选（饱和 ≥0.15、明度 0.08–0.95），压暗去饱和得到 [CoverDrivenPalette.base]。
/// 全部不合格（纯黑白灰封面等）时 palette 为 null，页面批次应回落到
/// 主题 surface 纯色，而不是报错。
class CoverDrivenBackgroundScope extends StatefulWidget {
  const CoverDrivenBackgroundScope({
    super.key,
    required this.artworkUrl,
    this.enabled = false,
    required this.child,
  });

  /// 当前封面源（与播放器/列表封面同一个 url 语义，直接透传取色器）。
  final String? artworkUrl;

  /// 是否启用封面驱动背景；**默认 false**（批次 1 只交付 API，不改变
  /// 任何现有页面视觉）。后续批次接线时由设置项驱动此开关。
  final bool enabled;

  final Widget child;

  /// 读取最近的封面派生色；未包裹 / 未启用 / 取色失败时返回 null。
  static CoverDrivenPalette? of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_CoverDrivenBackgroundData>()
          ?.palette;

  @override
  State<CoverDrivenBackgroundScope> createState() =>
      _CoverDrivenBackgroundScopeState();
}

class _CoverDrivenBackgroundScopeState
    extends State<CoverDrivenBackgroundScope> {
  /// 派生色缓存（url → 结果，含失败 null）：同封面往返切页不重复解码取色。
  /// 上限 64 条，超出整体清空——派生色计算便宜，粗暴清空即可，不引 LRU 依赖。
  static final Map<String, CoverDrivenPalette?> _cache = {};

  CoverDrivenPalette? _palette;
  String? _loadedUrl;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CoverDrivenBackgroundScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkUrl != widget.artworkUrl ||
        oldWidget.enabled != widget.enabled) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final url = widget.artworkUrl;
    // 未启用或无封面：派生色清空，消费方回落主题 surface。
    if (!widget.enabled || url == null || url.isEmpty) {
      _update(null, null);
      return;
    }
    if (_loadedUrl == url) return;
    if (_cache.containsKey(url)) {
      _update(url, _cache[url]);
      return;
    }
    // loadPalette 内部已捕获全部异常（失败返回 null），
    // 网络分支固定 512 宽、与播放器封面共享 ImageCache 键。
    final palette = await ArtworkColorExtractor.loadPalette(url);
    final derived = palette != null ? _derive(palette) : null;
    if (_cache.length >= 64) _cache.clear();
    _cache[url] = derived;
    // 异步返回时 url 可能已被切歌替换，只有仍是当前封面才生效。
    if (mounted && widget.artworkUrl == url) {
      _update(url, derived);
    }
  }

  void _update(String? url, CoverDrivenPalette? palette) {
    if (!mounted) return;
    setState(() {
      _loadedUrl = url;
      _palette = palette;
    });
  }

  /// 从 palette 派生低干扰背景色：占比降序找第一个合格候选，
  /// 压暗去饱和出底色、提亮出强调色；全部不合格返回 null。
  static CoverDrivenPalette? _derive(PaletteGenerator palette) {
    for (final c in palette.colors) {
      final hsl = HSLColor.fromColor(c);
      if (hsl.saturation < 0.15 ||
          hsl.lightness <= 0.08 ||
          hsl.lightness >= 0.95) {
        continue;
      }
      final base = hsl
          .withSaturation(hsl.saturation.clamp(0.28, 0.55).toDouble())
          .withLightness(hsl.lightness.clamp(0.10, 0.20).toDouble())
          .toColor();
      final accent = hsl
          .withSaturation(hsl.saturation.clamp(0.5, 0.8).toDouble())
          .withLightness(hsl.lightness.clamp(0.55, 0.75).toDouble())
          .toColor();
      return CoverDrivenPalette(base: base, accent: accent, source: c);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return _CoverDrivenBackgroundData(
      palette: _palette,
      child: widget.child,
    );
  }
}

/// [CoverDrivenBackgroundScope] 的数据载体（InheritedWidget）。
class _CoverDrivenBackgroundData extends InheritedWidget {
  const _CoverDrivenBackgroundData({
    required this.palette,
    required super.child,
  });

  final CoverDrivenPalette? palette;

  @override
  bool updateShouldNotify(_CoverDrivenBackgroundData oldWidget) =>
      palette != oldWidget.palette;
}

/// 页面背景组件：模糊背景图 + 透明度调节（主题背景色打底）。
///
/// 作为页面内容的底层（页面 Scaffold 背景透明时透出），并**随页面一起位移/
/// 过渡**——路由入场动画时背景图跟着画面滑动，避免"背景固定、页面跳变"的
/// 分离感。主页与所有二级页面统一使用（移除全局固定背景层）。
///
/// 开关关闭时返回空（保持页面原样）；开关开启时优先用用户选择的图片，
/// 无有效用户图片时回落到内置默认壁纸（始终有背景，避免"无背景"状态导致
/// 浅色模式配色异常）。
class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final tp = context.watch<ThemeProvider>();
    if (!tp.useBackgroundImage) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    // 解码宽度按屏幕物理宽度限制：模糊背景无需超高分辨率，避免高分辨率
    // 照片全尺寸解码造成的内存峰值（低内存设备会闪退）。
    final screenWidth = MediaQuery.sizeOf(context).width *
        MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = screenWidth.round().clamp(540, 1440);
    // 图片源：与页面顶栏共享同一解码结果（backgroundImageProvider）
    final image = Image(
      image: backgroundImageProvider(tp, cacheWidth: cacheWidth),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 主题背景色打底：透明度调低时露出的是主题莫奈取色的背景色
          ColoredBox(color: colorScheme.surface),
          // 外层显式 Opacity 控制图片透明度（实时生效）
          Opacity(
            opacity: tp.backgroundOpacity,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: tp.backgroundBlur,
                sigmaY: tp.backgroundBlur,
              ),
              child: image,
            ),
          ),
        ],
      ),
    );
  }
}
