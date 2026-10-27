import 'dart:io';
import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';

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
///
/// 批次 40 取证说明：二级详情页头部与路由过渡内嵌的主体 [AppBackground]
/// 同图同切片，头部切片的 opaque surface 打底会把主体层在头部区域盖住，
/// 头部可见壁纸仍恒为 1 层（渐变 tint 只叠一次），视觉等价单层——保留
/// 头部切片（头部沉浸设计，保证头部壁纸不依赖页面主体层）。
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
/// 页面背景组件：模糊背景图 + 透明度调节（主题背景色打底）。
///
/// 作为页面内容的底层（页面 Scaffold 背景透明时透出），并**随页面一起位移/
/// 过渡**——路由入场动画时背景图跟着画面滑动，避免"背景固定、页面跳变"的
/// 分离感。
///
/// 挂载点有两处（双层架构，批次 40 取证确认，任意页面可见壁纸恒 1 层）：
/// - **tab 页**：app.dart MaterialApp.builder Stack 的全局壁纸层（tab 页
///   不走 MaterialPageRoute，没有路由过渡内嵌层，全局层是唯一壁纸来源）；
/// - **MaterialPageRoute 二级页**：app_theme.dart `_BgSafeFadeForwardsBuilder`
///   给每条路由的过渡 child 内嵌一层，随页面位移入场。
/// 过渡叠放期间新页内嵌层的 opaque surface 打底盖住下层旧页背景，且两层
/// 同图同 cacheWidth 共享 ImageCache 同一解码结果——无双壁纸叠乘、无
/// 双份解码内存。（批次 40 曾核对「移除全局固定背景层」的旧说法：全局层
/// 实际保留，旧说法与实现矛盾，已随本批次修正。）
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
