import 'dart:async';
// FontVariation / ScrollDirection / ValueListenable 等不经 material_ui 完整导出，
// 显式引入（同 player_seek_bar / lyrics_view 的做法）
import 'dart:ui' show FontVariation;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
// HapticFeedback 不经 material_ui 导出（同 full_player 的显式引入做法）
import 'package:flutter/services.dart' show HapticFeedback;
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
/// - 跟随态交互：自动跟随时整视图渐变焦点层（离当前行越远越淡出，视口级
///   单层 ShaderMask，见 [_AppleMusicLyricsViewState._buildFollowFocusFade]），
///   并经 [AppleMusicLyricsView.onFollowChanged] 上报跟随态供播放器收起
///   底部进度条/传输行；手动拖动立即去模糊并恢复操作区，滚动停止后选中行
///   （基准线对齐行）以品牌红文字 + 淡色底高亮，该行右侧常驻尖角朝左的
///   播放胶囊（lyric-bubble 样式，点按 seek 到该行并恢复跟随）；3 秒无操作
///   自动恢复跟随。
class AppleMusicLyricsView extends StatefulWidget {
  const AppleMusicLyricsView({
    super.key,
    required this.lyricLines,
    required this.positionListenable,
    required this.onSeek,
    this.adaptPosition,
    this.speed = 1.0,
    this.isPlaying,
    this.onFollowChanged,
  });

  /// 胶囊播放按钮的 Key（供测试定位）。
  static const Key capsulePlayKey = ValueKey('apple_lyrics_capsule_play');

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

  /// 跟随状态回调：自动跟随=true / 手动浏览=false（首次挂载后一帧内上报
  /// 初始值）。全屏播放器据此收起/恢复底部进度条与播放操作按钮。
  final ValueChanged<bool>? onFollowChanged;

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
  // 选中行高亮淡色底圆角（与播放胶囊体圆角一致）
  static const double _selectedHighlightRadius = 9;

  final ScrollController _scrollController = ScrollController();
  late final Ticker _ticker;
  Timer? _resumeFollowTimer;

  /// 歌词列表的全局 Key。
  ///
  /// 根因修复：[_buildFollowFocusFade] 的 builder 按焦点强度在
  /// 「ShaderMask(包裹列表)」与「裸列表」两种树形间切换，t 跨 0 时列表
  /// 所在 slot 的 widget 类型变化 → 整棵列表子树被卸载重挂 ——
  /// ScrollController 会挂到全新的 ScrollPosition（滚动偏移重置为 0），
  /// 且拖拽中的手势随 Scrollable 的销毁被取消。表现为：手动滚动松手后
  /// 歌词跳回顶部/当前行、滚动中途卡住、恢复跟随时列表不回当前行。
  /// 挂上本 Key 后，树形切换时列表子树被**原地转移**（Element 复用，
  /// State / RenderObject / ScrollPosition / 手势识别器全部保留），
  /// 手动滚动只浏览、不丢偏移、不中断手势。
  final GlobalKey _lyricsListKey = GlobalKey();

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

  /// 用户滚动物理进行中（拖动起手 → 滚动完全停止，含惯性滑行）。
  /// 与 [_follow]（含 3 秒延迟窗）共同决定选中行高亮的显隐：
  /// 仅「非跟随 且 滚动已停止」时显示，拖动/惯性途中不显示。
  bool _isUserScrolling = false;

  /// 手动浏览态与基准线（视口上部 [_anchorViewportRatio] 处）对齐的选中行：
  /// 驱动选中行高亮与常驻播放胶囊的宿主行。跟随态不适用（选中行即当前行，
  /// 见 [_bubbleLineIndex]），由 [_onScrollOffsetChanged] 在滚动偏移变化时
  /// 按 [_computeSelectedLine] 逐帧刷新（仅下标变化才 setState，一次拖动
  /// 约每行高一次重建）。
  int? _selectedLine;

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
    // 滚动偏移变化时逐帧刷新手动浏览态的选中行（驱动行高亮与常驻胶囊）
    _scrollController.addListener(_onScrollOffsetChanged);
    // 首帧后同步一次初始跟随态：tab 切走再切回会重建 State（_follow 复位为
    // true），而外部可能还保留上一次的 false——必须上报对齐。
    // post-frame 触发避免在 build 阶段同步改写外部 listenable。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFollowChanged?.call(_follow);
    });
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
      // 选中行随旧行集失效（布局缓存已脏，反算无意义），下次滚动重新计算
      _selectedLine = null;
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
    _scrollController.removeListener(_onScrollOffsetChanged);
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
  ///
  /// 状态机（跟随态 [_follow] × 滚动态 [_isUserScrolling]）：
  /// - 跟随中：渐变焦点层生效（模糊淡出），无选中行高亮；
  /// - 手动滚动中（拖动起手/惯性滑行）：立即去模糊，胶囊跟随基准线移动；
  /// - 手动停止（滚动结束、3 秒延迟窗内）：无模糊，选中行高亮 + 胶囊定格；
  /// - 恢复跟随（3 秒无操作 / 点胶囊 / 点行 seek）：回到跟随态。
  bool _onScrollNotification(ScrollNotification notification) {
    final isUserDrag =
        notification is ScrollStartNotification &&
            notification.dragDetails != null;
    final isUserFling = notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle;
    if (isUserDrag || isUserFling) {
      _resumeFollowTimer?.cancel();
      final wasFollowing = _follow;
      _setUserScrolling(true);
      _setFollow(false);
      if (wasFollowing) {
        // 进入手动浏览：选中行先初始化为基准线对齐行（此刻即当前行），
        // 随后由 [_onScrollOffsetChanged] 逐帧跟踪，避免胶囊/高亮闪烁
        _selectedLine = _computeSelectedLine();
      }
      _resumeFollowTimer = Timer(_followResumeDelay, () {
        if (!mounted) return;
        _setUserScrolling(false);
        _setFollow(true);
        // 恢复跟随：立即滚回当前行
        if (_currentIndex >= 0) {
          _scrollToLine(_currentIndex, jump: false);
        }
      });
    } else if (notification is ScrollEndNotification && _isUserScrolling) {
      // 滚动完全停止（含惯性结束）：选中行定格，显示行高亮
      _setUserScrolling(false);
    }
    return false;
  }

  /// 更新跟随态并同步视觉层（焦点层 / overlay 显隐）与外部回调。
  void _setFollow(bool value) {
    if (_follow == value) return;
    _follow = value;
    setState(() {});
    widget.onFollowChanged?.call(value);
  }

  /// 更新「滚动物理进行中」标志（决定选中行高亮是否显示）。
  void _setUserScrolling(bool value) {
    if (_isUserScrolling == value) return;
    _isUserScrolling = value;
    setState(() {});
  }

  /// 滚动偏移变化（用户拖动/惯性/程序滚动）：手动浏览态逐帧刷新选中行，
  /// 驱动常驻胶囊跟随基准线对齐行移动；仅下标变化才 setState。
  /// 跟随态选中行即当前行（[_bubbleLineIndex] 直取 [_currentIndex]），不反算。
  void _onScrollOffsetChanged() {
    if (_follow) return;
    final next = _computeSelectedLine();
    if (next != _selectedLine) {
      setState(() => _selectedLine = next);
    }
  }

  /// 常驻播放胶囊的宿主行：跟随态=当前行（锚定在基准线）；手动浏览态=选中行。
  int? get _bubbleLineIndex =>
      _follow ? (_currentIndex >= 0 ? _currentIndex : null) : _selectedLine;

  /// 与基准线（视口上部 [_anchorViewportRatio] 处）对齐的歌词行下标。
  ///
  /// 仅在手动浏览态使用（滚动停止定影选中行、滚动中逐帧跟踪胶囊归属）。
  /// 行高估算同 [_scrollToLine]，误差约一个副行高，对「选中行」判定足够。
  int? _computeSelectedLine() {
    if (!_scrollController.hasClients || _lineTopOffsets.isEmpty) return null;
    final position = _scrollController.position;
    if (position.viewportDimension <= 0) return null;
    // 基准线在内容坐标系中的 Y（扣除 ListView 上下留白 padding）
    final anchorContentY = _scrollController.offset +
        position.viewportDimension * _anchorViewportRatio -
        _topPadding;
    var selected = 0;
    for (var i = 0; i < _lineTopOffsets.length; i++) {
      if (_lineTopOffsets[i] <= anchorContentY) {
        selected = i;
      } else {
        break;
      }
    }
    return selected.clamp(0, _lines.length - 1);
  }

  /// 播放指定行：seek 到该行显示轴 startTime，并立即恢复自动跟随。
  /// （点胶囊 / 点行共用：选中起播，取消 3 秒恢复计时。）
  /// [withHaptic] 仅胶囊点按触发（触觉反馈），点行沿用旧行为不反馈。
  void _playLineAt(int index, {bool withHaptic = false}) {
    if (index < 0 || index >= _lines.length) return;
    if (withHaptic) HapticFeedback.selectionClick();
    _resumeFollowTimer?.cancel();
    _setUserScrolling(false);
    _setFollow(true);
    widget.onSeek(Duration(milliseconds: _lines[index].startTime));
  }

  // ===== 行高估算（仅滚动偏移用，渲染行高由内容自适应）=====

  /// 用 TextPainter 按**非当前行样式**（26 / w700 / wght700，与
  /// [_otherTextStyle] 逐字段一致）测量主行高度。
  ///
  /// 必须用非当前态测量：锚定行 j 的偏移 = 行 0..j-1 高度和，而这些行
  /// 此刻均渲染为非当前态（26 / w700）；若按当前行样式（32 / w900）测量，
  /// 每行系统性高估 32×1.3 − 26×1.3 ≈ 7.8px（长行在 32px 下多换行时更多），
  /// 误差随行号线性累积，数十行歌曲累计数百 px，会把当前行推出视窗。
  /// 当前行自身 32px 膨胀只影响其下方行的实际偏移，不影响自身 top 锚定。
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
            fontSize: _otherFontSize,
            height: _lineHeightFactor,
            fontWeight: FontWeight.w700,
            fontVariations: const [FontVariation('wght', 700.0)],
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
    // 手动浏览停止态：选中行（基准线对齐行）高亮——品牌红文字 + 淡色底。
    // 当前行已有 32px 扫色强调，不叠加高亮（文字样式会冲突）。
    final isSelected = !_follow &&
        !_isUserScrolling &&
        !isCurrent &&
        index == _selectedLine;
    // 行右侧常驻播放胶囊：跟随态挂当前行，手动浏览态挂选中行
    final hasBubble = index == _bubbleLineIndex;

    return GestureDetector(
      // 点击行 seek：传该行显示轴 startTime（与旧 LyricsView 一致，
      // 不做逆变换，由 full_player 的 onSeek 回调统一下发）。
      // 点行 = 选中起播，立即恢复自动跟随（新交互收敛，替代旧的
      // 「点行后仍等 3 秒」行为；恢复跟随机制本身保留）。
      onTap: () => _playLineAt(index),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _lineVerticalPadding),
        // Stack 尺寸=Column 尺寸（非定位子决定），行布局与行高测量不受影响；
        // 选中行淡色底与播放胶囊均为定位子，不参与尺寸计算。
        // clipBehavior.none：胶囊左尖角允许向行左缘外溢出（极窄行如「…」
        // 时尖角探出行盒，指向歌词不被裁切）。
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 选中行淡色底（贴着文本行宽）
            if (isSelected)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(
                      _selectedHighlightRadius,
                    ),
                  ),
                ),
              ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 字号/字重平滑过渡（200ms），当前行以纯白做扫色模板
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  style: isCurrent
                      ? _currentTextStyle()
                      : isSelected
                          // 选中行：仅换色（字号/字重/字轴不变，行高测量契约
                          // 不受影响），品牌红 + 淡色底双重强调
                          ? _otherTextStyle(colorScheme).copyWith(
                              color: colorScheme.primary,
                            )
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
            // 行右侧常驻播放胶囊（尖角朝左指向该行歌词）
            if (hasBubble)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildPlayBubble(colorScheme, index),
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
          // 选中态不再用基准线 overlay：行高亮 + 行右侧常驻胶囊均随行走
          // （见 [_buildLine]），此处只保留跟随态渐变焦点层。
          // 列表子树挂 [_lyricsListKey]：焦点层树形切换时原地转移、不重挂。
          return _buildFollowFocusFade(
            child: NotificationListener<ScrollNotification>(
              key: _lyricsListKey,
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
            ),
          );
        },
      ),
    );
  }

  /// 自动跟随态的视觉焦点层：整视图单层渐变 mask（ShaderMask + dstIn）。
  ///
  /// 当前行锚定在视口上部 1/3（[_anchorViewportRatio]），该处全亮；向上下
  /// 两端 alpha 线性衰减——离当前行越远越「虚」（渐变淡出即等效失焦观感）。
  ///
  /// 性能取舍（对比逐行 ImageFiltered / BackdropFilter）：
  /// - 仅一层 viewport 级 saveLayer，滚动帧无逐行滤镜成本；
  /// - 手动滚动态（t≈0）完全不挂 ShaderMask，零滤镜成本；
  /// - 渐变静态，不随行距逐帧重算。
  /// 显隐用 [TweenAnimationBuilder] 在 250ms 内插值边缘 alpha（1→0），
  /// 避免模式切换时突兀跳变。
  ///
  /// 树形稳定性：builder 在 t 跨 0 时会在「ShaderMask(包裹)」与「裸子树」
  /// 两种树形间切换——列表子树因此挂 [_lyricsListKey]（GlobalKey）保命，
  /// 切换时 Element 原地转移而非卸载重挂（详见该字段注释）。
  Widget _buildFollowFocusFade({required Widget child}) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _follow ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      // 列表作为稳定 child 复用，t 变化只重建 builder 闭包
      child: child,
      builder: (context, t, masked) {
        if (t <= 0.001) return masked!;
        // 边缘 alpha 随焦点强度 t 从 1（无效果）收敛到 0（完全淡出）
        final edgeAlpha = 1.0 - t;
        Color stop(double a) => Colors.white.withValues(alpha: a);
        return ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              stop(edgeAlpha),
              stop(1),
              stop(1),
              stop(edgeAlpha),
            ],
            stops: const [0.0, 0.20, 0.45, 1.0],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: masked,
        );
      },
    );
  }

  /// 行右侧常驻播放胶囊（lyric-bubble 样式：胶囊体 + 左尖角指向该行歌词）。
  ///
  /// 宿主行：跟随态=当前行，手动浏览态=选中行（基准线对齐行），随行走、
  /// 随列表滚，不只在停止态出现。点按 seek 到该行 startTime 并恢复跟随。
  ///
  /// 命中行为：整块 [_bubbleWidth]×[_bubbleHeight] 不透明可点
  /// （[HitTestBehavior.opaque]），但只挂 tap 手势——垂直拖动会输给
  /// ListView 的拖拽器（>slop 即被拒绝），因此「从胶囊上起手的滚动」
  /// 依然正常滚动，不会误触 seek、也不会挡住歌词浏览。
  Widget _buildPlayBubble(ColorScheme colorScheme, int index) {
    return GestureDetector(
      key: AppleMusicLyricsView.capsulePlayKey,
      onTap: () => _playLineAt(index, withHaptic: true),
      behavior: HitTestBehavior.opaque,
      child: CustomPaint(
        painter: _LyricBubblePainter(fill: colorScheme.primaryContainer),
        // SizedBox 锁死 46×30：宿主 Positioned(top/bottom=0) 给的是行高
        // 拉伸约束，内层 Center（空因子）会撑满可用高度，必须显式限幅；
        // 图标居中于胶囊体（尖角左侧 9px 不计入），配色走 token。
        child: SizedBox(
          width: _bubbleWidth,
          height: _bubbleHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: _bubbleTipWidth),
            child: Center(
              child: Icon(
                Icons.play_arrow_rounded,
                size: 18,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 常驻播放胶囊（lyric-bubble 样式）几何：整体宽高 / 左尖角宽与半高 /
/// 胶囊体圆角。尖角底高 11 < 体高 30 − 2×圆角 9 = 12，底边完全落在胶囊体
/// 左边缘的平直段内，同色并集无凹口。
const double _bubbleWidth = 46;
const double _bubbleHeight = 30;
const double _bubbleTipWidth = 9;
const double _bubbleTipHalfHeight = 5.5;
const double _bubbleRadius = 9;

/// 播放胶囊外形：圆角胶囊体 + 左尖角（气泡指向歌词行）。
///
/// 体与尖角同色不透明分绘（同一 canvas 先后绘制，取并集），避免
/// [Path.combine] 的布尔运算开销；尖角底边完全落在胶囊体左边缘的平直段内
/// （底高 11 < 体高 30 − 2×圆角 9 = 12），并集无凹口、无接缝。
class _LyricBubblePainter extends CustomPainter {
  _LyricBubblePainter({required this.fill});

  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = fill;
    final cy = size.height / 2;
    // 胶囊体（右端与左端均为圆角，左边缘中段平直供尖角拼接）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(_bubbleTipWidth, 0, size.width - _bubbleTipWidth,
            size.height),
        const Radius.circular(_bubbleRadius),
      ),
      paint,
    );
    // 左尖角（等腰三角形，顶点指向左侧歌词行）
    canvas.drawPath(
      Path()
        ..moveTo(_bubbleTipWidth, cy - _bubbleTipHalfHeight)
        ..lineTo(0, cy)
        ..lineTo(_bubbleTipWidth, cy + _bubbleTipHalfHeight)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_LyricBubblePainter oldDelegate) =>
      oldDelegate.fill != fill;
}
