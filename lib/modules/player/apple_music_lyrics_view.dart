import 'dart:async';
// FontVariation / ScrollDirection / ValueListenable 等不经 material_ui 完整导出，
// 显式引入（同 player_seek_bar / lyrics_view 的做法）
import 'dart:ui' show FontVariation;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/md3_lyric_preferences.dart';

/// Apple Music 风格歌词视图。
///
/// 设计要点：
/// - 大字粗体左对齐歌词：当前行 32 / w900（**显式写入 fontVariations wght=900**，
///   根因同 full_player 标题加粗修复——M3E emphasized 会向继承链注入 wght 轴，
///   可变字体的 wght 轴优先级高于 fontWeight，必须显式覆盖才能生效），非当前行
///   26 / w700。
/// - 扫色：当前行用 [ShaderMask] 叠水平渐变做「已唱（onSurface 全亮）/
///   未唱（onSurface 40%）」分界，progress 由字级 [LyricWord] 分段线性插值
///   （无词级 timing 时按整行 [LyricLine.duration] 线性降级）。
/// - 平滑驱动：positionNotifier 只有 ~200ms 一次上报，内部用 [Ticker] 以
///   `上次上报锚点 + 墙钟差 * speed` 自驱动内插，每次上报重设锚点校正漂移。
///   功耗纪律：暂停时不推进不重绘；TabBarView 切走时子树被销毁、Ticker 随之
///   dispose，无常驻动画。
/// - 滚动：当前行锚定到视口上部约 1/3（animateTo 300ms easeOut，首次 jumpTo）；
///   用户手动滚动后暂停自动跟随 3 秒。
/// - 点击行 → [AppleMusicLyricsView.onSeek]（传该行显示轴 startTime，与旧
///   LyricsView 的 seek 方向保持一致，由 full_player 统一下发 seek）。
class AppleMusicLyricsView extends StatefulWidget {
  const AppleMusicLyricsView({
    super.key,
    required this.lyricLines,
    required this.positionListenable,
    required this.onSeek,
    this.adaptPosition,
    this.speed = 1.0,
    this.isPlaying,
  });

  /// 已解析的结构化歌词（须为显示轴时间，即与 [adaptPosition] 输出同轴）。
  final List<LyricLine> lyricLines;

  /// 播放位置 listenable（positionNotifier，~200ms 一次）。
  final ValueListenable<Duration> positionListenable;

  /// 对上报位置做二次校正（如在线歌词时间偏移）：显示位置 = adapt(raw)。
  final Duration Function(Duration)? adaptPosition;

  /// seek 回调：参数为歌词显示轴时间（与旧 LyricsView 一致，不做逆变换）。
  final ValueChanged<Duration> onSeek;

  /// 播放倍速，参与 Ticker 自驱动内插推算。
  final double speed;

  /// 外部播放态。为 null 时由相邻两次 position 上报差值推断
  /// （差值 >0 且 <3s 视为播放中）；有确切播放态时建议传入，
  /// 暂停可立即停 Ticker，不依赖 200ms 推断窗口。
  final bool? isPlaying;

  @override
  State<AppleMusicLyricsView> createState() => _AppleMusicLyricsViewState();
}

class _AppleMusicLyricsViewState extends State<AppleMusicLyricsView>
    with SingleTickerProviderStateMixin {
  // ===== 样式常量 =====
  static const double _currentFontSize = 32;
  static const double _otherFontSize = 26;
  static const double _lineHeightFactor = 1.3;
  static const double _lineVerticalPadding = 10;
  // 副文本（翻译/罗马音）相对主行的字号比例
  static const double _subScale = 0.55;
  // 用户手动滚动后恢复自动跟随的等待时长
  static const Duration _followResumeDelay = Duration(seconds: 3);
  // 首尾空白占视口高度比例（当前行可锚定到视口上部 1/3）
  static const double _edgeViewportRatio = 0.35;
  // 当前行锚定点距视口顶部的比例
  static const double _anchorViewportRatio = 1 / 3;

  final ScrollController _scrollController = ScrollController();
  late final Ticker _ticker;
  Timer? _resumeFollowTimer;

  /// 按startTime 升序的显示副本（parser 输出应已有序，这里保险再排一次）。
  List<LyricLine> _lines = const [];

  // ===== 位置锚点（显示轴毫秒）=====
  double _anchorMs = 0;
  DateTime _anchorTime = DateTime.now();
  // 相邻两次上报的显示轴毫秒，用于在未传 isPlaying 时推断播放态
  double? _lastReportedMs;
  bool _inferredPlaying = false;

  // ===== 当前状态 =====
  int _currentIndex = -1;
  final ValueNotifier<double> _progress = ValueNotifier(0);
  bool _follow = true;
  bool _initialJumpDone = false;

  // ===== 行高估算缓存（TextPainter 预测，仅用于滚动偏移计算）=====
  bool _layoutDirty = true;
  double _layoutWidth = -1;
  List<double> _lineHeights = const [];
  List<double> _lineTopOffsets = const [];
  double _topPadding = 0;

  // 当前 MD3 歌词偏好快照（副文本开关与显示模式）
  Md3LyricPreferences get _prefs => Md3LyricPreferences.instance;

  @override
  void initState() {
    super.initState();
    _rebuildLines();
    widget.positionListenable.addListener(_onPositionChanged);
    _prefs.addListener(_onPrefsChanged);
    _ticker = createTicker(_onTick);
    // 初始定位：读一次当前上报值（不推断播放态，等下一次上报）
    final display = widget.adaptPosition?.call(widget.positionListenable.value) ??
        widget.positionListenable.value;
    _anchorMs = display.inMilliseconds.toDouble();
    _lastReportedMs = _anchorMs;
    _anchorTime = DateTime.now();
    _applyDisplayPosition(_anchorMs);
  }

  @override
  void didUpdateWidget(covariant AppleMusicLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切歌 / 重新解析：重建行、重置定位与布局缓存
    if (!identical(oldWidget.lyricLines, widget.lyricLines) &&
        !listEquals(oldWidget.lyricLines, widget.lyricLines)) {
      _rebuildLines();
      _layoutDirty = true;
      _currentIndex = -1;
      _initialJumpDone = false;
      _applyDisplayPosition(_anchorMs);
    }
    if (oldWidget.speed != widget.speed ||
        oldWidget.isPlaying != widget.isPlaying) {
      _syncTicker();
    }
  }

  @override
  void dispose() {
    widget.positionListenable.removeListener(_onPositionChanged);
    _prefs.removeListener(_onPrefsChanged);
    _resumeFollowTimer?.cancel();
    _ticker.dispose();
    _scrollController.dispose();
    _progress.dispose();
    super.dispose();
  }

  void _onPrefsChanged() {
    if (mounted) setState(() {});
  }

  void _rebuildLines() {
    _lines = [...widget.lyricLines]..sort(
        (a, b) => a.startTime.compareTo(b.startTime),
      );
  }

  // ===== 位置输入 =====

  /// positionNotifier 上报（~200ms）：校正 Ticker 锚点、更新当前行与扫色进度。
  void _onPositionChanged() {
    final raw = widget.positionListenable.value;
    final display = widget.adaptPosition?.call(raw) ?? raw;
    final ms = display.inMilliseconds.toDouble();
    // 未传 isPlaying 时由相邻上报差值推断播放态：
    // 正常播放 delta ≈ 200ms；暂停 delta == 0；seek（大幅跳变 ≥3s）不算播放。
    if (widget.isPlaying == null && _lastReportedMs != null) {
      final delta = ms - _lastReportedMs!;
      _inferredPlaying = delta > 0 && delta < 3000;
    }
    _lastReportedMs = ms;
    _anchorMs = ms;
    _anchorTime = DateTime.now();
    _applyDisplayPosition(ms);
    _syncTicker();
  }

  /// Ticker 帧回调：自 _anchorTime 起按墙钟内插显示位置（speed 参与）。
  /// 暂停（playing=false）时直接返回，不推进不重绘。
  void _onTick(Duration _) {
    if (!_isPlaying) return;
    final elapsedMs = DateTime.now().difference(_anchorTime).inMilliseconds;
    _applyDisplayPosition(_anchorMs + elapsedMs * widget.speed);
  }

  bool get _isPlaying => widget.isPlaying ?? _inferredPlaying;

  /// 功耗纪律：仅播放中且存在当前行时运行 Ticker；页面切走时子树被
  /// TabBarView 销毁，Ticker 随 dispose 停止，无常驻动画。
  void _syncTicker() {
    final shouldRun = _isPlaying && _currentIndex >= 0;
    if (shouldRun && !_ticker.isActive) {
      _anchorTime = DateTime.now();
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  // ===== 当前位置 → 行索引 / 扫色进度 =====

  int _findLineIndex(double posMs) {
    var index = -1;
    for (var i = 0; i < _lines.length; i++) {
      if (posMs >= _lines[i].startTime) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _applyDisplayPosition(double posMs) {
    if (_lines.isEmpty) return;
    final newIndex = _findLineIndex(posMs);
    if (newIndex != _currentIndex) {
      setState(() => _currentIndex = newIndex);
      _updateProgress(posMs);
      _syncTicker();
      if (_follow && newIndex >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollToLine(newIndex, jump: !_initialJumpDone);
          }
        });
      }
    } else {
      _updateProgress(posMs);
    }
  }

  void _updateProgress(double posMs) {
    final p = _currentIndex < 0 ? 0.0 : _computeProgress(posMs);
    if ((_progress.value - p).abs() > 0.0008) {
      _progress.value = p;
    }
  }

  /// 当前行的已唱进度（0~1）。
  ///
  /// 有词级 timing（[LyricLine.hasWordTiming]）：按 [LyricWord] 分段线性插值，
  /// 以累计字符数加权近似字符宽度（找当前字：pos ∈ [word.start, word.start +
  /// word.duration] → 字内进度；整行 = (已完整字字符数 + 字内进度 × 当前字
  /// 字符数) / 总字符数）。无词级 timing（纯 LRC）：整行按
  /// (pos - startTime) / duration 线性降级。
  double _computeProgress(double posMs) {
    final line = _lines[_currentIndex];
    if (line.hasWordTiming) {
      var totalChars = 0;
      for (final w in line.words) {
        totalChars += w.text.length;
      }
      if (totalChars == 0) return 0;
      if (posMs >= line.endTime) return 1;
      var doneChars = 0;
      for (final w in line.words) {
        final start = w.startTime.toDouble();
        final end = start + w.duration;
        if (posMs >= end) {
          doneChars += w.text.length;
          continue;
        }
        if (posMs <= start) break;
        final inWord = w.duration <= 0
            ? 1.0
            : (posMs - start) / w.duration;
        return (doneChars + inWord * w.text.length) / totalChars;
      }
      return doneChars / totalChars;
    }
    // 降级：整行线性插值
    if (line.duration <= 0) return posMs >= line.startTime ? 1 : 0;
    final p = (posMs - line.startTime) / line.duration;
    return p.clamp(0.0, 1.0).toDouble();
  }

  // ===== 滚动 =====

  /// 用直接偏移量滚动（不依赖 Scrollable.ensureVisible——它会冒泡到
  /// TabBarView 的 PageView 破坏滚动状态，同旧 LyricsView 的经验）。
  void _scrollToLine(int index, {required bool jump}) {
    if (!_scrollController.hasClients) return;
    if (index < 0 || index >= _lineTopOffsets.length) return;
    final viewport = _scrollController.position.viewportDimension;
    if (viewport <= 0) return;

    // 行高估算未含「当前行展开的副文本」，锚定误差约一个副行高，
    // 视口 1/3 锚定位有足够余量，不做精确测量（避免常驻 TextPainter 开销）。
    final target =
        _topPadding + _lineTopOffsets[index] - viewport * _anchorViewportRatio;
    // clamp 返回 num，jumpTo/animateTo 需要 double，显式收窄
    final clamped = target.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    ).toDouble();
    if (jump) {
      _scrollController.jumpTo(clamped);
    } else {
      _scrollController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
    _initialJumpDone = true;
  }

  /// 用户手动滚动（拖动起手或惯性方向非 idle）后暂停自动跟随 3 秒。
  /// 注意：程序 animateTo 触发的 ScrollStartNotification 携带
  /// dragDetails == null，不会误判为用户滚动。
  bool _onScrollNotification(ScrollNotification notification) {
    final isUserDrag =
        notification is ScrollStartNotification &&
            notification.dragDetails != null;
    final isUserFling = notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle;
    if (isUserDrag || isUserFling) {
      _resumeFollowTimer?.cancel();
      _follow = false;
      _resumeFollowTimer = Timer(_followResumeDelay, () {
        if (!mounted) return;
        _follow = true;
        // 恢复跟随：立即滚回当前行
        if (_currentIndex >= 0) {
          _scrollToLine(_currentIndex, jump: false);
        }
      });
    }
    return false;
  }

  // ===== 行高估算（仅滚动偏移用，渲染行高由内容自适应）=====

  /// 用 TextPainter 按**当前行样式**（32 / w900，最大字号）测量主行高度。
  /// 不含当前行展开的翻译/罗马音副行（仅当前行显示），锚定误差见
  /// [_scrollToLine] 注释。
  void _ensureLayout(double width) {
    if (!_layoutDirty && _layoutWidth == width) return;
    _layoutDirty = false;
    _layoutWidth = width;

    final n = _lines.length;
    _lineHeights = List<double>.generate(n, (i) {
      final text = _lines[i].text.isEmpty ? '…' : _lines[i].text;
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: _currentFontSize,
            height: _lineHeightFactor,
            fontWeight: FontWeight.w900,
            fontVariations: const [FontVariation('wght', 900.0)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final h = painter.height + _lineVerticalPadding * 2;
      painter.dispose();
      return h;
    });
    _lineTopOffsets = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      _lineTopOffsets[i] = _lineTopOffsets[i - 1] + _lineHeights[i - 1];
    }
  }

  // ===== 渲染 =====

  /// 当前行副文本（翻译/罗马音）：跟随 MD3 歌词偏好开关，仅当前行显示。
  String? _subTextFor(LyricLine line) {
    if (!_prefs.showAuxiliary) return null;
    final preferRoma = _prefs.displayMode == Md3LyricDisplayMode.roma;
    final primary = preferRoma ? line.roma : line.translation;
    final fallback = preferRoma ? line.translation : line.roma;
    final text = (primary == null || primary.isEmpty) ? fallback : primary;
    return (text == null || text.isEmpty) ? null : text;
  }

  TextStyle _currentTextStyle() => TextStyle(
        fontSize: _currentFontSize,
        height: _lineHeightFactor,
        fontWeight: FontWeight.w900,
        // 根因同 full_player 标题修复：M3E emphasized 向继承链注入 wght 轴，
        // copyWith(fontWeight:) 清不掉，必须显式重写 fontVariations。
        fontVariations: const [FontVariation('wght', 900.0)],
        // 当前行为「扫色模板」：ShaderMask(srcIn) 用渐变色替代文字色，
        // 文字本身只承载 alpha，因此固定纯白。
        color: Colors.white,
      );

  TextStyle _otherTextStyle(ColorScheme colorScheme) => TextStyle(
        fontSize: _otherFontSize,
        height: _lineHeightFactor,
        fontWeight: FontWeight.w700,
        fontVariations: const [FontVariation('wght', 700.0)],
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
      );

  Widget _buildCurrentLine(LyricLine line, ColorScheme colorScheme) {
    // 扫色：水平渐变在 progress 处硬分界（stops: [p, p]），
    // 已唱 = onSurface 全亮，未唱 = onSurface 40%。
    // RepaintBoundary 限定 ShaderMask 重绘范围，避免每帧外溢整棵歌词树。
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: _progress,
        // child 固定，progress 变化只重建 ShaderMask 闭包（不重建 Text）
        child: Text(line.text.isEmpty ? '…' : line.text),
        builder: (context, progress, child) {
          return ShaderMask(
            shaderCallback: (bounds) {
              final p = progress.clamp(0.0, 1.0).toDouble();
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  colorScheme.onSurface,
                  colorScheme.onSurface.withValues(alpha: 0.4),
                ],
                stops: [p, p],
              ).createShader(bounds);
            },
            blendMode: BlendMode.srcIn,
            child: child,
          );
        },
      ),
    );
  }

  Widget _buildLine(BuildContext context, int index) {
    final colorScheme = Theme.of(context).colorScheme;
    final line = _lines[index];
    final isCurrent = index == _currentIndex;
    final mainText = line.text.isEmpty ? '…' : line.text;
    final subText = isCurrent ? _subTextFor(line) : null;
    final subFontSize = _currentFontSize * _subScale;

    return GestureDetector(
      // 点击行 seek：传该行显示轴 startTime（与旧 LyricsView 一致，
      // 不做逆变换，由 full_player 的 onSeek 回调统一下发）
      onTap: () => widget.onSeek(Duration(milliseconds: line.startTime)),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _lineVerticalPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 字号/字重平滑过渡（200ms），当前行以纯白做扫色模板
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              style: isCurrent
                  ? _currentTextStyle()
                  : _otherTextStyle(colorScheme),
              child: isCurrent
                  ? _buildCurrentLine(line, colorScheme)
                  : Text(mainText),
            ),
            if (subText != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  subText,
                  style: TextStyle(
                    fontSize: subFontSize,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_lines.isEmpty) {
      // 空歌词：居中提示
      final colorScheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lyrics_outlined,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '暂无歌词',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    // 排除全局 UI 缩放，歌词保持原始大小（同旧 LyricsView）
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth - 48; // 水平 padding 24*2
          _ensureLayout(width);
          // 首尾各留视口高度 35% 的空白：首行可锚定到视口上部 1/3 处
          _topPadding = constraints.maxHeight * _edgeViewportRatio;
          return NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: ListView.builder(
              controller: _scrollController,
              padding: EdgeInsets.symmetric(
                vertical: _topPadding,
                horizontal: 24,
              ),
              itemCount: _lines.length,
              itemBuilder: (context, index) => _buildLine(context, index),
            ),
          );
        },
      ),
    );
  }
}
