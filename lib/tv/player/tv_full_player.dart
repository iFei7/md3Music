// 批次43：TV 全屏播放页（Z1/Z2/Z3 三层结构）。
//
// 层级（规范终版）：
// - Z1 动态环境背景：封面主色全屏拉伸 + 高斯模糊（σ=90×scale，经 tvBlurSigma
//   钳制——90px 高斯在 TV 弱 GPU 上必卡，TV 构建钳到 12，正常构建满血；
//   这正是 tvBlurSigma 的设计意图）+ 45% 黑遮罩 + 基底 #08090C 打底；
//   切歌 600ms 溶解（AnimatedSwitcher）；封面缺失/加载失败降级为基底纯色渐变。
// - Z2 核心内容：左右 4:6——左栏黑胶唱片（设计中心 (316,460)，33.3RPM
//   18s/圈匀速旋转，暂停平滑减速）+ 文字组 (96,760)；右栏歌词视口
//   （X=860 Y=96 W=864 H=888，复用 AppleMusicLyricsView）。无歌词时右栏
//   隐藏、左栏黑胶水平居中补偿（规范降级策略）。
// - Z3 呼出控制条：默认透明，任意按键唤醒（Back 除外），3.5s 无操作
//   600ms 淡出；玻璃背板（用户口径：控制条不用规范实色 #14161D，
//   用 LiquidGlassSurface 与手机端同设计语言）。
//
// 按键映射（页级 Focus.onKeyEvent，与 dpad 焦点层分工）：
// - OK/Select → 播放/暂停（最高优先级盲操）；焦点落在控制条控件上时
//   由 DpadFocusable 先消费，不会重复触达本层
// - ←/→：控制条隐藏时快退/快进 10s 直接 seek；显示时交 dpad 焦点层
//   （进度条 stepper / 焦点移动）
// - ↑ 唤醒控制条并锁定喜欢钮（wakeStamp 触发控制条重挂载 → 喜欢钮
//   DpadFocusable autofocus 接管焦点）
// - ↓ 直接下一首；Menu（contextMenu）快捷浮窗；Back → pop
//   （音乐后台持续：Flutter 默认不杀后台音频服务，无需特殊处理）
//
// 歌词视图自带 Ticker 自驱动内插——**测试与生产均不能对整页 pumpAndSettle**。
import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../data/models/song.dart';
import '../../modules/player/apple_music_lyrics_view.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../widgets/player_artwork_image.dart';
import '../design/tv_design.dart';
import 'tv_control_bar.dart';

/// TV 全屏播放页（批次43）。
///
/// 独立可渲染：内部自取 PlayerProvider / KugouProvider / ThemeProvider /
/// LocalFavoritesProvider（app.dart MultiProvider 均已注册），const 无必需
/// 参数构造，由主控以 `'/' → '/player'` 路由挂载（本批次不接路由）。
class TvFullPlayer extends StatefulWidget {
  const TvFullPlayer({super.key});

  @override
  State<TvFullPlayer> createState() => _TvFullPlayerState();
}

class _TvFullPlayerState extends State<TvFullPlayer>
    with TickerProviderStateMixin {
  /// Z3 显示态（默认隐藏）。
  final ValueNotifier<bool> _barVisible = ValueNotifier(false);

  /// 3.5s 无操作自动隐藏计时。
  Timer? _hideTimer;

  /// 进度 seek 步进器（挂在页面 State，控制条重挂载不丢 pending）。
  late final TvSeekStepper _stepper = TvSeekStepper(onCommit: _commitSeek);

  /// 黑胶旋转控制器：18s/圈（33.3RPM）播放匀速。
  late final AnimationController _vinylController = AnimationController(
    vsync: this,
    duration: TvMotion.vinylRevolution,
  );
  bool _spinning = false;

  /// ↑ 唤醒自增戳：控制条以含戳的 key 重挂载，让喜欢钮 autofocus 接管焦点。
  int _wakeStamp = 0;

  /// 歌词缓存（按 songId，切歌重载）。
  String? _lyricSongId;
  bool _lyricLoading = false;
  List<LyricLine> _lyricLines = const [];

  @override
  void dispose() {
    _hideTimer?.cancel();
    _barVisible.dispose();
    _stepper.dispose();
    _vinylController.dispose();
    super.dispose();
  }

  PlayerProvider get _player => context.read<PlayerProvider>();

  // ===== Z3：唤醒 / 隐藏 =====

  /// 任意按键唤醒控制条并重置 3.5s 计时（Back 除外，调用方过滤）。
  void _wake({bool focusLike = false}) {
    _hideTimer?.cancel();
    _barVisible.value = true;
    if (focusLike) _wakeStamp++;
    _hideTimer = Timer(TvMotion.controlBarAutoHide, _hideBar);
  }

  void _hideBar() {
    _barVisible.value = false;
    _stepper.reset(); // 隐藏时丢弃未落定的步进
    // 焦点若还停在已隐藏的控制条内，按键会被不可见控件消费——主动让出
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _commitSeek(Duration target) {
    _player.seek(target);
  }

  // ===== 按键映射（页级） =====

  // LogicalKeyboardKey 重载了 ==，不能做 const set 元素
  static final Set<LogicalKeyboardKey> _selectKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // 只处理按下与连发；抬起忽略
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    // Back：pop 页面。音乐后台持续——Flutter 应用层退栈不杀后台音频，
    // PlayerProvider/AudioService 生命周期独立于页面，无需特殊处理。
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }

    // Menu 键：快捷浮窗（面板自身 3.5s 无操作淡出，见 TvQuickMenu）
    if (key == LogicalKeyboardKey.contextMenu) {
      TvQuickMenu.show(context, player: _player, onUserInteraction: _wake);
      return KeyEventResult.handled;
    }

    // 其余任意按键唤醒控制条（↑ 额外锁定喜欢钮）
    _wake(focusLike: key == LogicalKeyboardKey.arrowUp);

    // OK/Select → 播放/暂停盲操。控制条可见且焦点在控件上时，
    // DpadFocusable 已消费 select，不会到达这里。
    if (_selectKeys.contains(key)) {
      _togglePlayPause();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.handled; // 已唤醒 + 焦点锁定喜欢钮
    }

    // ↓ 直接下一首
    if (key == LogicalKeyboardKey.arrowDown) {
      _player.next();
      return KeyEventResult.handled;
    }

    // ←/→：直接快退/快进 10s seek（盲操连续按可连续跳转）。
    // 焦点在控制条上时由 DpadFocusable 先行消费（进度条=步进、按钮=焦点
    // 移动），到不了这里，不会双重响应；控制条可见但无 dpad 焦点时仍走
    // 页级直 seek，避免首键唤醒后连续快进断档。
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final sign = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      final current = _player.positionNotifier.value;
      final total = _player.currentSong?.duration ?? const Duration(hours: 1);
      var target = current + const Duration(seconds: 10) * sign;
      if (target < Duration.zero) target = Duration.zero;
      if (target > total) target = total;
      _player.seek(target);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _togglePlayPause() {
    final player = _player;
    if (player.isPlaying) {
      player.pause();
    } else {
      player.resume();
    }
  }

  // ===== 黑胶旋转（18s/圈；暂停平滑减速） =====

  void _setSpinning(bool playing) {
    _spinning = playing;
    if (playing) {
      // 匀速：repeat 每圈 TvMotion.vinylRevolution（18s，33.3RPM）
      _vinylController.repeat();
    } else {
      // 平滑减速（简化实现，规范允许）：从当前角度 animateTo 当前值+0.08 圈，
      // decelerate 曲线滑行 ~900ms 自然停住；非物理精确的角速度积分衰减，
      // 但视觉上连续无跳变，且恢复播放 repeat() 从停驻角度继续。
      final current = _vinylController.value;
      _vinylController.animateTo(
        current + 0.08,
        duration: TvMotion.vinylCoastDown,
        curve: Curves.decelerate,
      );
    }
  }

  // ===== 歌词加载（song.id → KugouProvider → LyricParserChain.parse） =====

  Future<void> _loadLyricsForSong(Song song) async {
    _lyricLoading = true;
    _lyricSongId = song.id;
    try {
      final kugou = context.read<KugouProvider>();
      // 本地歌曲的 songId 是 'local_<path>'，不是酷狗 hash；
      // 传空 hash 让酷狗 API 完全基于歌名搜索（与 full_player.dart 同口径）。
      // 注：TV 端暂不读本地内嵌歌词（LocalLyricLoader 分支），批次44 视需要补。
      final hash = song.isOnline ? song.id : '';
      final searchName = (song.artist != '未知艺术家')
          ? '${song.title} ${song.artist}'
          : song.title;
      await kugou.getLyric(hash, songName: searchName);
      final lyric = kugou.lyric;
      final lyricText =
          lyric?.displayKrcLyric ?? lyric?.displayLrcLyric ?? lyric?.displayLyric ?? '';
      final translationText = lyric?.translatedContent;
      final romaText = lyric?.romaContent;
      final parsed = lyricText.trim().isEmpty
          ? const <LyricLine>[]
          : LyricParserChain.parse(
              lyricText,
              translationText: translationText,
              romaText: romaText,
            );
      if (mounted && _lyricSongId == song.id) {
        setState(() {
          _lyricLines = parsed;
          _lyricLoading = false;
        });
      }
    } catch (_) {
      // 网络失败等：按无歌词降级（右栏隐藏、黑胶居中）
      if (mounted && _lyricSongId == song.id) {
        setState(() {
          _lyricLines = const [];
          _lyricLoading = false;
        });
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = context.watch<PlayerProvider>();
    // 黑胶旋转与播放态同步（含切歌后状态变化）
    if (player.isPlaying != _spinning) {
      _setSpinning(player.isPlaying);
    }
    final song = player.currentSong;
    if (song == null) {
      // 无歌态：清空歌词
      if (_lyricSongId != null || _lyricLines.isNotEmpty) {
        _lyricSongId = null;
        _lyricLines = const [];
        _lyricLoading = false;
      }
      return;
    }
    if (!_lyricLoading && song.id != _lyricSongId) {
      // 先同步占位防重复触发；实际加载延后到 post-frame——getLyric 链路会
      // 同步 notifyListeners（_beginLoading），在 didChangeDependencies/build
      // 期间直接跑会触发 "markNeedsBuild during build"。
      _lyricLoading = true;
      _lyricSongId = song.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadLyricsForSong(song);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final brand = context.watch<ThemeProvider>().effectiveSeedColor;
    final song = player.currentSong;

    final hasLyrics = _lyricLines.isNotEmpty;

    return Scaffold(
      backgroundColor: TvColors.base,
      body: Focus(
        autofocus: true,
        onKeyEvent: _handleKey,
        child: TvLayoutScale(
          // scale 必须从作用域**内**取：本 build 的 context 在 TvLayoutScale
          // 之上，直接 of(context) 会兜底 1.0。
          child: Builder(
            builder: (context) {
              final scale = TvLayoutScale.of(context);
              double px(double v) => v * scale;
              return Stack(
            children: [
              // ===== Z1 动态环境背景 =====
              const Positioned.fill(child: _TvAmbientBackground()),

              // ===== Z2 左栏：黑胶唱片（中心 (316,460) 设计位；无歌词时水平居中补偿 → 960） =====
              Positioned(
                key: const ValueKey('tv43_vinyl'),
                left: px(hasLyrics ? 316 - 260 : 960 - 260),
                top: px(200),
                width: px(520),
                height: px(520),
                child: _TvVinyl(
                  controller: _vinylController,
                  artworkUri: song?.artworkUri,
                ),
              ),

              // ===== Z2 左栏：文字组 (96,760) =====
              Positioned(
                left: px(96),
                top: px(760),
                width: px(440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song?.displayName ?? '',
                      key: const ValueKey('tv43_title'),
                      style: TvType.songTitle(scale),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: px(16)),
                    Text(
                      song == null
                          ? ''
                          : '${song.artist} - ${song.album}',
                      style: TvType.subtitle(scale),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // ===== Z2 右栏：歌词视口（X=860 Y=96 W=864 H=888；无歌词时隐藏） =====
              if (hasLyrics)
                Positioned(
                  left: px(860),
                  top: px(96),
                  width: px(864),
                  height: px(888),
                  child: DpadRegion(
                    memoryKey: 'tv43/lyrics',
                    child: AppleMusicLyricsView(
                      lyricLines: _lyricLines,
                      positionListenable: player.positionNotifier,
                      onSeek: (d) => player.seek(d),
                      isPlaying: player.isPlaying,
                    ),
                  ),
                ),

              // ===== Z3 呼出控制条（默认透明，600ms 淡入淡出） =====
              ValueListenableBuilder<bool>(
                valueListenable: _barVisible,
                builder: (context, visible, _) => Positioned(
                  left: px(96),
                  bottom: px(96), // Y=880 + 高 104 = 底部安全区上沿
                  width: px(1728),
                  height: px(104),
                  child: IgnorePointer(
                    key: const ValueKey('tv43_bar_ignore'),
                    ignoring: !visible,
                    child: AnimatedOpacity(
                      key: const ValueKey('tv43_bar_opacity'),
                      opacity: visible ? 1 : 0,
                      duration: TvMotion.controlBarFade,
                      child: DpadRegion(
                        memoryKey: 'tv43/control-bar',
                        enter: DpadEnterBehavior.entry,
                        // 焦点在控制条内移动也算交互（重置隐藏计时）
                        onFocusChange: (inside) {
                          if (inside) _wake();
                        },
                        child: TvControlBar(
                          // wakeStamp 入 key：↑ 唤醒时重挂载 → 喜欢钮
                          // DpadFocusable(autofocus) 接管焦点（焦点锁定）
                          key: ValueKey('tv43_bar-$_wakeStamp'),
                          player: player,
                          stepper: _stepper,
                          brandColor: brand,
                          onUserInteraction: _wake,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
            },
          ),
        ),
      ),
    );
  }
}

/// Z1 动态环境背景（批次43）。
///
/// 封面全屏拉伸 + 高斯模糊（σ=90×scale，tvBlurSigma 钳制）+ 45% 黑遮罩 +
/// 基底打底；切歌（artworkUri 变化）AnimatedSwitcher 600ms 溶解；
/// 封面 null 降级为基底纯色渐变（规范异常策略）。
class _TvAmbientBackground extends StatelessWidget {
  const _TvAmbientBackground();

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final uri = player.currentSong?.artworkUri;
    final scale = TvLayoutScale.of(context);
    // 90px 全屏高斯在 TV 弱 GPU 上必卡：tvBlurSigma 在 TV 构建钳到 12，
    // 正常构建满血 90×scale（这正是钳制函数的设计意图）。
    final sigma = tvBlurSigma(90 * scale);

    final Widget layer;
    if (uri == null || uri.isEmpty) {
      // 降级：无封面 → 基底纯色渐变（#08090C → 略亮的 #14161D，非纯黑体系）
      layer = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [TvColors.base, const Color(0xFF14161D)],
          ),
        ),
      );
    } else {
      layer = Stack(
        fit: StackFit.expand,
        children: [
          // 基底打底：封面解码/网络未就绪时不露白
          const ColoredBox(color: TvColors.base),
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: PlayerArtworkImage(
              artworkUri: uri,
              isFill: true,
              fit: BoxFit.cover,
              decodeCap: 512, // 背景用途 512 解码上限足够，省内存
            ),
          ),
          // 45% 黑遮罩：保证前景文字/黑胶对比度
          ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
        ],
      );
    }

    // 切歌溶解：artworkUri 变化 → 新层 600ms 淡入旧层淡出
    return AnimatedSwitcher(
      duration: TvMotion.bgSwitch,
      child: KeyedSubtree(key: ValueKey(uri), child: layer),
    );
  }
}

/// 黑胶唱片：外圈同心圆纹理（CustomPainter）+ 内嵌封面 260px 居中；
/// 播放时由外层 [AnimationController]（18s/圈）驱动 [RotationTransition]。
class _TvVinyl extends StatelessWidget {
  const _TvVinyl({required this.controller, required this.artworkUri});

  final AnimationController controller;
  final String? artworkUri;

  @override
  Widget build(BuildContext context) {
    final scale = TvLayoutScale.of(context);
    double px(double v) => v * scale;
    return RotationTransition(
      turns: controller,
      child: CustomPaint(
        painter: const _VinylRingsPainter(),
        child: Center(
          child: ClipOval(
            child: SizedBox(
              width: px(260),
              height: px(260),
              child: PlayerArtworkImage(
                artworkUri: artworkUri,
                isFill: true,
                fit: BoxFit.cover,
                decodeCap: 512,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 黑胶纹理：黑底圆盘 + 若干同心圆细纹 + 中心轴孔。
class _VinylRingsPainter extends CustomPainter {
  const _VinylRingsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    // 黑底圆盘（非纯黑，与基底区分层次）
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(0xFF0B0C10),
    );

    // 同心圆细纹（暗纹理，向内渐密）
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    var r = radius * 0.98;
    var i = 0;
    while (r > radius * 0.26) {
      ringPaint.color = Colors.white.withValues(alpha: i.isEven ? 0.05 : 0.02);
      canvas.drawCircle(center, r, ringPaint);
      r -= radius * 0.045;
      i++;
    }

    // 中心轴孔
    canvas.drawCircle(
      center,
      radius * 0.03,
      Paint()..color = TvColors.base,
    );
  }

  @override
  bool shouldRepaint(_VinylRingsPainter oldDelegate) => false;
}
