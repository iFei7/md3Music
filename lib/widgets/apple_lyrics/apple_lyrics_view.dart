/// Apple Music 风格歌词主组件
///
/// 参照 spec.md "Requirement: 点击跳转" 与 tasks.md Task 17 实现。
/// 接收已解析的 [LyricLine] 列表与播放状态，集成所有渲染器与控制器，
/// 通过 [CustomPainter] 绘制 Apple Music 风格的逐字 / 整行歌词。
///
/// 设计要点：
/// - 解析由调用方完成（[LyricParserChain.parse]），本组件只接收 [lines]
/// - 用 [Ticker] + [SingleTickerProviderStateMixin] 每帧推进
///   所有控制器与渲染器，触发 [setState] 重绘
/// - 每行独立的 renderer 实例（按行索引缓存），避免多行共用导致状态混乱
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import '../../core/utils/app_haptics.dart';
import 'package:flutter/widgets.dart';

import '../../core/services/player_frame_driver.dart';
import 'controllers/lyric_scroll_controller.dart';
import 'layout/lyric_layout.dart';
import 'layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'renderers/interlude_dots.dart';
import 'renderers/line_renderer.dart';
import 'renderers/word_renderer.dart';

/// Apple Music 风格歌词主组件。
///
/// 调用方负责通过 [LyricParserChain.parse] 解析得到 [lines]，本组件不再解析。
/// 内部用 [Ticker] + [SingleTickerProviderStateMixin] 驱动每帧
/// [tick] 推进所有控制器与渲染器，调用 [setState] 触发重绘。
class AppleLyricsView extends StatefulWidget {
  /// 已解析的歌词行列表（由调用方通过 LyricParserChain.parse 得到）
  final List<LyricLine> lines;

  /// 当前播放时间（毫秒）
  final int currentTimeMs;

  /// 是否正在播放
  final bool isPlaying;

  /// 播放流未就绪（切歌 loading / 音频缓冲 buffering）。
  /// 未就绪期间逐字动画时钟冻结在权威位置（语义对齐暂停），避免
  /// "帧时钟前进 300ms → 兜底回吸"的锯齿循环造成字内渐变来回抽搐。
  final bool playbackNotReady;

  /// 用户点击某行后回调（调用方应调用 just_audio.seek）
  final void Function(int timeMs)? onSeek;

  /// 是否启用缩放（默认 true）
  final bool enableScale;

  /// 是否强制使用深色背景的歌词颜色（白色文字）。
  ///
  /// AM 风格播放器背景始终为深色（Colors.black + 模糊封面），
  /// 即使 app 处于浅色主题也应使用白色歌词。
  /// 非 AM 播放器背景跟随主题，浅色主题用黑色歌词。
  final bool forceDarkBackground;

  /// 是否启用间奏点（节奏点）动画。
  ///
  /// 设为 false 时跳过间奏检测，歌词行之间不会出现节奏点小圆点动画。
  /// 适用于本地歌曲且歌词为 LRC 逐行格式的场景：LRC 没有逐字时间戳，
  /// 行间的节奏点与真实节拍不易对齐，禁用后体验更干净。
  /// 默认 true，保持原有视觉。
  final bool enableInterludeDots;

  /// 是否启用双击跳转（开启后单击不跳转，双击才跳转播放位置）
  final bool doubleTapToJump;

  /// 播放位置 listenable：提供后组件内部订阅位置更新，动画驱动直接消费
  /// 内部权威时间 [_AppleLyricsViewState._authorityTimeMs]，外层不再需要
  /// 每 ~200ms 用新 [currentTimeMs] 重建本组件（性能解耦）。
  final ValueListenable<Duration>? positionListenable;

  /// 对 [positionListenable] 的原始位置做二次校正并返回毫秒
  /// （如在线歌词时间偏移：渲染位置 = 播放位置 - 偏移），可为 null。
  final int Function(Duration)? adaptTimeMs;

  const AppleLyricsView({
    super.key,
    required this.lines,
    required this.currentTimeMs,
    this.isPlaying = false,
    this.playbackNotReady = false,
    this.onSeek,
    this.enableScale = true,
    this.forceDarkBackground = false,
    this.enableInterludeDots = true,
    this.doubleTapToJump = false,
    this.positionListenable,
    this.adaptTimeMs,
  });

  /// 找到当前应高亮的行索引：最后一个 `startTime <= currentTimeMs` 的行。
  ///
  /// 抽象为静态方法便于单元测试。空列表返回 -1；时间早于第一行返回 0。
  @visibleForTesting
  static int findCurrentLineIndex(List<LyricLine> lines, int currentTimeMs) {
    if (lines.isEmpty) return -1;
    // 性能优化：二分查找替代线性遍历，O(log N) 替代 O(N)
    // lines 按 startTime 升序排列，找最后一个 startTime <= currentTimeMs 的行
    int lo = 0, hi = lines.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (lines[mid].startTime <= currentTimeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // lo - 1 是最后一个 startTime <= currentTimeMs 的行索引
    // lo == 0 表示所有 startTime > currentTimeMs，返回 0（时间早于第一行）
    return lo > 0 ? lo - 1 : 0;
  }

  /// 计算行的"人声实际结束时间"（毫秒），用于间奏 gap 判定与激活窗口。
  ///
  /// - 无逐字行（LRC/纯文本）：直接返回 [LyricLine.endTime]
  ///   （LRC duration 为 0，endTime = startTime，两行间隔即 startTime 之差）。
  /// - 逐字行（KRC）：KRC 行级 duration 常覆盖尾音/空白，甚至延伸到下一行，
  ///   若直接用 endTime = startTime + duration，gap 被压缩为负或 < 阈值，
  ///   导致间奏点从源头识别不到。取「行 duration 结束」与「最后一个字结束」
  ///   的较小值作为人声实际结束，更贴近演唱真实空档。
  @visibleForTesting
  static int effectiveLineEndTime(LyricLine line) {
    final int lineEnd = line.endTime;
    if (line.words.isEmpty) return lineEnd;
    final LyricWord lastWord = line.words.last;
    final int wordEnd = lastWord.startTime + lastWord.duration;
    return math.min(lineEnd, wordEnd);
  }

  @override
  State<AppleLyricsView> createState() => _AppleLyricsViewState();
}

class _AppleLyricsViewState extends State<AppleLyricsView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // ============== 动画驱动 ==============
  //
  // 使用 Ticker（而非 AnimationController.addListener + DateTime.now()）驱动每帧，
  // 因为 Ticker 的回调参数 [Duration elapsed] 基于调度器时钟（测试中为模拟时间），
  // 保证单元测试中 pump(Duration) 能正确推进弹簧动画。
  // AnimationController.addListener + DateTime.now() 在测试中会用真实墙钟时间，
  // 导致弹簧几乎不推进，测试无法验证动画行为。

  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  /// v3 优化：Ticker 当前运行状态，用于幂等保护 start/stop 调用。
  bool _isTickerRunning = false;

  /// v3 优化：上次重绘时的关键动画值，用于判断本帧是否需要重绘。
  /// 检测阈值 0.5px / 0.001 远低于人眼感知，无视觉差异。
  double _lastRepaintPosY = 0;
  double _lastRepaintInterludeProgress = 0;
  double _lastRepaintTransExpand = 0;
  int _lastRepaintCurrentLineIndex = -1;

  // ============== 控制器与效果 ==============

  final LyricScrollController _scrollController = LyricScrollController();
  final InterludeDots _interludeDots = InterludeDots();
  /// 每行独立的 [WordRenderer] 缓存（按行索引）。
  ///
  /// WordRenderer 内部检测 line 切换并维护 alpha map，多行共用会导致状态混乱，
  /// 故每行独占一个实例。首次访问时懒创建。
  final Map<int, WordRenderer> _wordRenderers = <int, WordRenderer>{};

  /// 每行独立的 [LineRenderer] 缓存（按行索引）。
  final Map<int, LineRenderer> _lineRenderers = <int, LineRenderer>{};

  // ============== 当前状态 ==============

  int _currentLineIndex = -1;
  Offset? _tapDownPosition;

  // P0: 当前行查找结果缓存：currentTimeMs 与 lines 引用都未变化时，
  // _onTick 每帧跳过 findCurrentLineIndex 二分查找（O(log N) → 0 次）
  int _currentTimeMsCache = -1;
  Object? _linesCacheRef;

  /// 权威播放时间（ms）：listenable 模式由 [_onExternalPosition] 更新；
  /// 静态模式等于 widget.currentTimeMs。替代原先所有 widget.currentTimeMs 消费。
  int _authorityTimeMs = 0;

  /// 仅测试用：当前生效的权威时间
  @visibleForTesting
  int get authorityTimeMsForTest => _authorityTimeMs;

  // P0: 逐字动画时间平滑。positionStream 默认 ~200ms（5fps）才更新一次，
  // 直接用 widget.currentTimeMs 驱动上浮/字内渐变会让动画每 200ms 才推进一次
  // （120Hz 下"动 ~80ms + 冻结 ~120ms"）→ 肉眼卡顿。
  // 播放中用帧时钟每帧推进 [_smoothPosMs]，收到权威位置时对齐校正；
  // seek / 暂停恢复 / 切歌等大跳变直接吸附。仅用于逐字动画（maskX/上浮），
  // 行定位 / 间奏检测仍用权威 widget.currentTimeMs，保证与音频严格同步。
  double _smoothPosMs = 0;
  int _lastAuthorityPosMs = -1;

  // P0: 间奏点动画降频（30fps）用的帧时间累积器
  double _interludeAccumulator = 0;

  /// 逐字动画平滑时间的权威位置校正：
  ///
  /// - [_smoothPosSeekJumpMs]：权威位置跳变超过此值视为 seek/大跳变，直接吸附。
  /// - [_smoothPosCorrRate]：正常 position 更新时平滑逼近权威位置的速率（指数衰减系数）。
  ///   平滑逼近而非硬跳，避免音频时钟与帧时钟漂移导致权威位置硬跳跨过逐字边界、
  ///   字切换来回抖动（英文歌字短、边界密集时更明显，表现为"下一个字闪一下"）。
  static const int _smoothPosSeekJumpMs = 500;
  static const double _smoothPosCorrRate = 20.0;

  // ============== 歌词省电模式（60fps 限帧，默认关闭） ==============
  // 开启后歌词渲染推进锁定 60fps，用户上下滑动歌词（拖动/惯性/自动回弹动画）时
  // 解锁为最高刷新率；滚动视觉静止后自动重新锁定。
  //
  // **为什么必须停 Ticker 换 Timer**：仅在 _onTick 内节流跳过计算无法降低实际
  // 渲染帧率——Ticker 每帧都会 scheduleFrame()，引擎每帧 compositeFrame 提交
  // 场景，120Hz 屏上即便内容不变仍保持 120fps 刷新（CPU/GPU 白耗，这正是
  // "开了开关仍锁不住 60fps"的根因）。因此 eco 锁定时停掉 Ticker、改用
  // 16.67ms Timer 驱动 _onTick，帧生产被真正限制到 60fps；解锁/关闭 eco 时
  // 切回 Ticker 满帧。

  /// eco 锁定时是否挂在共享 60fps 帧驱动上（真正的帧率限制驱动源）。
  ///
  /// 与封面旋转/频谱共用 [PlayerFrameDriver] 的同一节拍：两者独立起 16ms
  /// Timer 时相位错开，会让 120Hz 屏整页跑到 ~120fps（功耗翻倍）。
  bool _ecoDriverBound = false;

  /// Ticker 帧间隔跳变阈值（秒）。
  ///
  /// 超过此值视为 Ticker 曾被 mute（TabBarView 切走 / App 退后台 /
  /// 主线程长时间卡顿）：mute 期间帧回调冻结，间奏点动画时钟（帧 dt 累积）
  /// 会停留在切走前的位置，而歌曲继续播放 → 切回后"跟不上进度"。
  /// 此时需把间奏点动画时钟重新对齐到真实窗口进度（O(1) 检测，无额外功耗）。
  static const double _tickerGapResumeThreshold = 0.5;

  /// 省电模式是否被用户滚动解锁（true = Ticker 满帧推进）。
  bool _ecoUnlocked = false;

  /// 省电模式是否处于解锁状态（仅测试用，避免 widget 测试无法观测限帧状态）。
  @visibleForTesting
  bool get ecoUnlockedForTest => _ecoUnlocked;

  /// 当前驱动源是否为 60fps eco Timer（eco Timer 在跑且满帧 Ticker 未跑）。
  /// 仅测试用：验证挂载即确定性建立 eco 限帧、不依赖 Ticker 的 _onTick 自我纠正。
  @visibleForTesting
  bool get ecoDriverIsTimerForTest => _ecoDriverBound && !_isTickerRunning;

  /// eco Timer 是否存活（仅测试用：验证 P0-A 挂起/恢复语义）。
  @visibleForTesting
  bool get ecoTimerActiveForTest => _ecoDriverBound;

  // P0-A：驱动源可见性门控状态。
  //
  // Ticker 由 TickerMode/引擎自动 mute，但 eco Timer 不受任何可见性约束——
  // TabBarView 切走 / App 退后台后仍会以 16ms 周期驱动 _onTick 产生离屏重绘。
  // 两个标志任一为 true 时，[_syncEcoDriver] 挂起全部驱动源。

  /// App 处于后台（hidden/paused/detached）。
  bool _lifecycleSuspended = false;

  /// TickerMode 关闭（歌词 tab 被切走，与 Ticker mute 同源）。
  bool _tickerModeMuted = false;

  /// 从挂起恢复后的首个 _onTick 按"gap 恢复"处理（Timer 路径 dt 恒 16ms，
  /// 自身检测不到挂起时长缺口，需此标记对齐间奏点等帧时钟动画）。
  bool _resumeGapPending = false;

  /// 间奏点是否仍处于激活（需要绘制）状态。仅测试用：验证跳转离开间奏后
  /// 圆点已自动清除，不会悬浮残留在原 anchor 行（穿帮回归护栏）。
  @visibleForTesting
  bool get interludeDotsActiveForTest => _interludeDots.shouldRender;

  /// 间奏点是否已进入消失动画阶段（末 750ms）。仅测试用：验证"跳转离开"
  /// 与"自然结束"两条路径被正确区分。
  @visibleForTesting
  bool get interludeDotsInExitPhaseForTest => _interludeDots.isInExitPhase;

  /// 间奏占位展开进度（0=完全收起，1=完全展开）。仅测试用。
  @visibleForTesting
  double get interludeExpandProgressForTest => _interludeExpandProgress;

  /// 第 i 行的副行预留高度（已含副行过长换行的行数）。仅测试用：
  /// 验证副行换行后行距预留随视觉行数增长（否则换行副行压到下一行）。
  @visibleForTesting
  double auxSubHeightForTest(int i) => _auxSubHeightOf(i);

  /// P1-C：上次间奏检测时的权威播放时间（毫秒）。
  ///
  /// 间奏检测只依赖 currentTimeMs（positionStream 约 200ms 更新一次），
  /// 时间未变且占位动画已收敛时，跳过每帧 O(间奏数) 的线性遍历。
  /// 同时用于检测时间回退（seek/跳转）：currentTimeMs < 上次值时说明
  /// 播放位置回跳，需强制重置间奏点动画时钟（见 [_updateInterlude]）。
  int _lastInterludeCheckTimeMs = -1;

  // overscan 视口缓冲行数：pad 端 15、手机端 10。在 build 中根据最短边更新
  int _overscan = 10;

  // P2-H 方案 A：ShaderMask 上下渐隐 shader 缓存。
  // shaderCallback 在每次 build 时被调用，渐隐参数仅依赖 bounds 尺寸，
  // 尺寸不变时复用同一 shader，避免每帧/每次重建 LinearGradient + createShader。
  ui.Shader? _fadeShader;
  Rect? _fadeShaderBounds;

  /// 获取（或按需重建）歌词界面上下边界渐隐 shader。
  ///
  /// 渐隐是静态的（上下 24px alpha 渐变），仅随视口尺寸变化。
  /// bounds 不变时直接返回缓存实例，消除每次 build 的对象与 shader 分配。
  ui.Shader _fadeShaderFor(Rect bounds) {
    if (_fadeShader != null && bounds == _fadeShaderBounds) {
      return _fadeShader!;
    }
    const double fadeHeight = 24.0;
    final double fadeRatio = (fadeHeight / bounds.height).clamp(0.0, 0.5);
    final shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: const [
        Colors.transparent,
        Colors.black,
        Colors.black,
        Colors.transparent,
      ],
      stops: [0.0, fadeRatio, 1.0 - fadeRatio, 1.0],
    ).createShader(bounds);
    _fadeShader = shader;
    _fadeShaderBounds = bounds;
    return shader;
  }

  // ============== 歌词行数据 ==============
  //
  // [_lines] 与 widget.lines 同引用，仅在来源引用变化时重新绑定并失效相关缓存。
  // 时间戳保持不变，故 onSeek / 当前行定位 / 间奏检测不受影响。
  List<LyricLine> _lines = const <LyricLine>[];

  /// 上次绑定时所基于的 widget.lines 引用（用于缓存命中判断）。
  Object? _cachedLinesSourceRef;

  /// 缓存的 hasTimestamps 结果（避免每帧 O(N) 遍历所有 lines）。
  /// 在 [_syncLinesIfNeeded] 中随 lines 引用变化时更新。
  bool _cachedHasTimestamps = false;

  /// 缓存的"是否含逐字行"结果（避免每帧 O(N) 遍历所有 lines）。
  ///
  /// 逐字行 = words 非空（KRC、字级 LRC，含本地/云盘音乐的 LRC 逐字）。
  /// P0-A 只对「整首歌都无逐字」的歌词（LRC 逐行 / 纯文本）启用
  /// 播放中停 Ticker 的静止省电模式；任何逐字行都必须保持 Ticker
  /// 持续推进逐字渐变/上浮/辉光动画。
  bool _cachedHasAnyWordTiming = false;

  /// 绑定当前歌词行列表（仅在来源引用变化时重新绑定并失效缓存）。
  void _syncLinesIfNeeded() {
    if (identical(widget.lines, _cachedLinesSourceRef) &&
        _lines.length == widget.lines.length) {
      return;
    }
    _cachedLinesSourceRef = widget.lines;
    _lines = widget.lines;
    // 缓存 hasTimestamps 结果，避免每帧 O(N) 遍历
    _cachedHasTimestamps = widget.lines.any((l) => l.startTime > 0);
    // 缓存"是否含逐字行"（KRC / 字级 LRC 的 words 非空），P0-A 静止省电
    // 模式仅对整首歌无逐字（LRC 逐行 / 纯文本）生效
    _cachedHasAnyWordTiming = widget.lines.any((l) => l.words.isNotEmpty);
    // 失效行高缓存，让 _recomputeLineHeightsIfNeeded 用新的 _lines 重算
    _cachedLinesRef = null;
    // 歌词内容变化：清空副行收起表并重置副行进度（旧行索引不再适用于新歌词）
    _transCollapsing.clear();
    _translationExpandProgress = 0;
  }

  /// 上一帧的当前行索引，用于检测行切换。
  int _previousLineIndex = -1;

  /// 预计算每行实际高度（含自动换行）。
  ///
  /// **性能优化**：只在 lines/fontSize/viewportWidth 变化时重算，
  /// 不再每帧重算（之前每帧 build 都跑 N 次 TextPainter.layout 是 CPU 杀手）。
  /// [_recomputeLineHeightsIfNeeded] 负责缓存命中判断。
  List<double> _lineHeights = const <double>[];
  List<double> _lineTops = const <double>[];

  /// 哪些行索引后面有间奏（gap >= thresholdMs）。
  ///
  /// 用于检测当前是否进入间奏时段（_activeInterludeAfterIndex）。
  /// 注意：只有激活间奏才占位高度（动态展开/收起），非激活间奏占位 = 0。
  List<int> _interludeAfterIndices = const <int>[];

  // v3 优化：generation counter，列表内容变化时 +1。
  // shouldRepaint 用 counter 比较替代 listEquals O(n) 比较。
  int _linesGeneration = 0;
  int _lineHeightsGeneration = 0;
  int _lineTopsGeneration = 0;
  int _interludeAfterIndicesGeneration = 0;

  /// 持久化 painter 实例。
  /// 通过 _repaintNotifier 驱动重绘，避免每帧 setState + build 的 widget tree 开销。
  _LyricsPainter? _painter;

  /// painter 的重绘信号源。fireRepaint() 触发 CustomPaint 重绘。
  final _RepaintNotifier _repaintNotifier = _RepaintNotifier();

  /// 当前激活的间奏在 _interludeAfterIndices 中的索引（-1 表示无激活）。
  ///
  /// 严格 AMLL 逻辑：只有 currentTime 真正进入间奏时段
  /// （gapStart < now < gapEnd）才激活占位。
  /// 一激活就开始 spring 展开 0 → totalHeight，
  /// 间奏结束（now >= gapEnd）就 spring 收起 totalHeight → 0。
  int _activeInterludeIdx = -1;

  /// 最后激活的间奏 anchor 行索引（-1 表示从未激活过）。
  ///
  /// 用于间奏结束后 progress 收起期间继续计算占位偏移，
  /// 避免 `_interludeOffsetBefore` 在间奏一结束就立即返回 0 导致 targetY 突变。
  /// 当 `_interludeExpandProgress` 收起到 0 后重置为 -1。
  int _lastActiveAnchorIdx = -1;

  /// 间奏占位 spring 进度（0 = 完全收起，1 = 完全展开）。
  ///
  /// 用指数衰减逼近目标值，目标由 _activeInterludeIdx 决定：
  /// - 激活：target = 1.0
  /// - 未激活：target = 0.0
  /// 每帧 _onTick 中推进：progress += (target - progress) * (1 - exp(-speed * dt))
  /// speed = 18（300ms 内基本到位）
  double _interludeExpandProgress = 0;

  /// 当前行翻译副行展开进度（0→1 副行"长出"，1→0 收起），指数逼近。
  ///
  /// 仅当前行预留副行高度（未播放歌词不占位）。本进度同时驱动当前行副行的
  /// 视觉"浮出"与 alpha 淡入（alpha 与位置同进度，淡入淡出贯穿整个过渡）。
  double _translationExpandProgress = 0.0;

  /// 当前切行过渡的副行动画速率（/s），切行时按退场行时长捕获
  /// （[_fadeRateForMs]：快歌快、慢歌最多 1s），收起与展开共用——
  /// 副行收起与该行原歌词主文本退场淡出严格同速，且维持
  /// "收起余量 + 展开量 ≡ 预留总量"的下方行零位移不变量。
  double _transSwitchRate = 14.0;

  /// 间奏占位完全展开后的总高度（含上下 0.4em 边距，跟随 fontSize 缩放）。
  double _interludePlaceholderHeight = 0;

  // 缓存命中判断字段
  double _cachedFontSize = -1;
  double _cachedViewportWidth = -1;

  /// 行高系数缓存（`LyricLayout.lineHeight`，由字号与行间距共同决定）。
  ///
  /// 必须进缓存键：`lineHeight = (fontSize / defaultFontSize) * lineSpacing`，
  /// 只调行间距时 fontSize 不变，若不比较本值则缓存命中、行高/行顶不重算，
  /// 表现为"调行间距不刷新，必须再调一次字号才生效"。
  double _cachedLineHeight = -1;
  int _cachedLinesLength = -1;
  Object? _cachedLinesRef;
  // 字体缓存：字体变化时强制重算行高 + 失效所有模糊图片缓存
  // （TextPainter 用 fontFamily 测量，旧缓存会与新字体渲染尺寸不一致）
  String? _cachedFontFamily;
  // 字重缓存：字重变化时同样需强制重算行高 + 失效模糊图片缓存
  int _cachedFontWeight = -1;
  // 副行布局缓存：displayMode 切换也需重算（虽副行高度不变，但需触发重绘）
  LyricDisplayMode _cachedDisplayMode = LyricDisplayMode.translation;

  /// 返回指定行索引上方所有激活间奏占位的累计高度。
  ///
  /// **progress 驱动**：只要 `_interludeExpandProgress > 0` 就返回占位高度，
  /// 不依赖 `_activeInterludeIdx`。这样间奏结束后 progress 缓慢收起到 0 期间，
  /// 占位偏移也跟随平滑收起，posY target 不会突变。
  ///
  /// 使用 `_lastActiveAnchorIdx` 记录最后激活的间奏 anchor，
  /// 避免影响其他未激活间奏的占位。
  ///
  /// 高度 = _interludePlaceholderHeight × _interludeExpandProgress
  double _interludeOffsetBefore(int lineIndex) {
    if (_interludeExpandProgress <= 0) return 0;
    final int anchorIdx = _lastActiveAnchorIdx;
    if (anchorIdx < 0 || anchorIdx >= lineIndex) return 0;
    return _interludePlaceholderHeight * _interludeExpandProgress;
  }

  /// 每行副行（翻译/罗马音）预留高度（含过长换行），索引与 [_lines] 对齐。
  ///
  /// 公式见 [LyricLayout.auxSubHeight]：`rows × transFontSize × 1.5 + 0.3em 间隙`，
  /// rows 为该行副行在可用宽度内的实际视觉行数。行高缓存恒按纯主行测量，
  /// 副行占位由本值 × 动画进度每帧动态叠加。
  /// **逐行取值**：不同行的副行行数不同（有的一行、有的换行成 2~3 行），
  /// 用单一"单行高度"会让换行副行压到下一行歌词上（行距未调整）。
  List<double> _auxSubHeights = const <double>[];

  /// 第 i 行的副行预留高度（无副行文本/越界 → 0）。
  double _auxSubHeightOf(int i) =>
      (i >= 0 && i < _auxSubHeights.length) ? _auxSubHeights[i] : 0;

  /// 正在收起副行的行索引 → 收起进度（0=刚开始收起，1=完全收起后移除）。
  ///
  /// 行切换时上一当前行从当前展开进度登记（c0 = 1 - 展开进度），起点与切换
  /// 瞬间的视觉完全一致，无跳变。用 Map 而非单槽：快歌（行隔 < 400ms）连切
  /// 时上一轮收起可能未完成，各行需独立收完。
  final Map<int, double> _transCollapsing = {};

  /// 指定行是否有副行文本（翻译或罗马音，按 displayMode）。
  bool _lineHasAuxText(int i) {
    if (i < 0 || i >= _lines.length) return false;
    final line = _lines[i];
    final String? aux =
        LyricPreferences.instance.displayMode == LyricDisplayMode.roma
        ? line.roma
        : line.translation;
    return aux != null && aux.isNotEmpty;
  }

  /// 第 i 行因副行动画产生的额外高度（行高消费点叠加）。
  ///
  /// 当前行跟随展开进度增长；收起表中的行随收起进度回落；其余行恒 0
  /// （静态行高即纯主行高度）。各自使用**该行自身的**副行预留高度
  /// （[_auxSubHeightOf]，已含换行行数），换行副行不会与下一行重叠。
  ///
  /// **不读 showTranslation 做立即短路**：关闭翻译时 target 变 0、进度指数
  /// 衰减到 0，高度跟随动画平滑收起——若在此短路，关闭瞬间高度直接塌缩。
  /// 进度收敛后本值自然归 0，无残留。
  double _transExtraHeightFor(int i) {
    if (i == _currentLineIndex && _lineHasAuxText(i)) {
      return _auxSubHeightOf(i) * _translationExpandProgress;
    }
    final double? c = _transCollapsing[i];
    return c == null ? 0 : _auxSubHeightOf(i) * (1.0 - c);
  }

  /// 第 i 行上方所有副行动画高度之和（行 top 消费点叠加）。
  ///
  /// 当前行与收起中的行通常相邻（outgoing = current - 1），表极小（≤4），
  /// 遍历开销可忽略。各行使用自身的副行预留高度（与 [_transExtraHeightFor] 同口径）。
  /// **不读 showTranslation 短路**（理由同 [_transExtraHeightFor]）。
  double _transDeltaBefore(int i) {
    double d = 0;
    if (_currentLineIndex >= 0 &&
        _currentLineIndex < i &&
        _lineHasAuxText(_currentLineIndex)) {
      d += _auxSubHeightOf(_currentLineIndex) * _translationExpandProgress;
    }
    _transCollapsing.forEach((k, v) {
      if (k < i) d += _auxSubHeightOf(k) * (1.0 - v);
    });
    return d;
  }

  /// 根据 fontSize/viewportWidth/lines 变化判断是否需要重算 lineHeights/lineTops。
  ///
  /// 命中缓存时直接 return，避免每帧 N 次 TextPainter.layout（N=歌词行数）。
  /// 50 行歌词 × 60fps = 每秒 3000 次 layout → 缓存后降为 0 次/帧。
  ///
  /// 同时检测相邻行间隔 >= [LyricLayout.interludeThresholdMs] 的位置，
  /// 记录到 [_interludeAfterIndices]。占位高度动态展开/收起（不在这里固定）。
  void _recomputeLineHeightsIfNeeded(double fontSize, double viewportWidth) {
    final identitySame = identical(_lines, _cachedLinesRef);
    final currentFontFamily = LyricLayout.fontFamily;
    final currentFontWeight = LyricLayout.fontWeight.value;
    final currentLineHeight = LyricLayout.lineHeight;
    final currentDisplayMode = LyricPreferences.instance.displayMode;
    if (currentDisplayMode != _cachedDisplayMode) {
      debugPrint(
        '[RomaToggle] AppleLyricsView displayMode 变化: $_cachedDisplayMode -> $currentDisplayMode',
      );
    }
    if (fontSize == _cachedFontSize &&
        viewportWidth == _cachedViewportWidth &&
        currentLineHeight == _cachedLineHeight &&
        _lines.length == _cachedLinesLength &&
        identitySame &&
        _lineHeights.length == _lines.length &&
        currentFontFamily == _cachedFontFamily &&
        currentFontWeight == _cachedFontWeight &&
        currentDisplayMode == _cachedDisplayMode) {
      return; // 缓存命中
    }
    _cachedFontSize = fontSize;
    _cachedViewportWidth = viewportWidth;
    _cachedLineHeight = currentLineHeight;
    _cachedLinesLength = _lines.length;
    _cachedLinesRef = _lines;
    _cachedFontFamily = currentFontFamily;
    _cachedFontWeight = currentFontWeight;
    _cachedDisplayMode = currentDisplayMode;

    // v3 优化：列表内容变化时递增 generation counter。
    // lines 用 identical 比较，只有引用变化才递增；
    // lineHeights/lineTops/interludeAfterIndices 每次重算都递增。
    if (!identitySame) {
      _linesGeneration++;
    }
    _lineHeightsGeneration++;
    _lineTopsGeneration++;
    _interludeAfterIndicesGeneration++;

    final maxLineWidth = LyricLayout.maxLineWidth(viewportWidth, fontSize);
    final mainLineHeight = fontSize * LyricLayout.lineHeight;
    // 间奏占位总高度 = 点高度 + 上下 0.4em 边距
    // 点高度约 2 * dotRadius = 2 * fontSize * 0.08 = 0.16em
    // 边距 = 0.8em
    // 总高度约 0.96em，约等于 1 倍主行高
    _interludePlaceholderHeight = mainLineHeight * 1.0;
    final List<double> heights = <double>[];
    final List<double> tops = <double>[];
    final List<int> interludeIndices = <int>[];
    double acc = 0;
    for (int i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      // 行高恒按"纯主行"测量：翻译副行预留不再进静态缓存，改由
      // _transExtraHeightFor（展开/收起进度）每帧动态叠加。副行占位随动画
      // 平滑增长/回落，消除行切换时高度瞬间换位导致的位置闪现。
      heights.add(
        LyricLayout.measureLineHeight(
          line,
          fontSize,
          mainLineHeight,
          maxLineWidth,
        ),
      );
      tops.add(acc);
      acc += heights.last;
      // 检测当前行与下一行之间是否有间奏（最后一行后面无间奏）
      // 间奏点关闭时跳过检测，_interludeAfterIndices 保持为空，
      // _updateInterlude 自然不会激活任何间奏，节奏点不会出现。
      if (widget.enableInterludeDots && i < _lines.length - 1) {
        final next = _lines[i + 1];
        // 用"人声实际结束时间"而非 endTime（KRC 行 duration 常覆盖尾音/空白，
        // 会把真实 gap 压缩导致间奏点识别不到，见 effectiveLineEndTime）
        final gap = next.startTime - AppleLyricsView.effectiveLineEndTime(line);
        if (gap >= LyricLayout.interludeThresholdMs) {
          interludeIndices.add(i);
        }
      }
    }
    _lineHeights = heights;
    _lineTops = tops;
    _interludeAfterIndices = interludeIndices;
    // 逐行副行预留高度（含过长换行）：按 displayMode 取翻译或罗马音，
    // 用实际视觉行数 × 副行行高 + 0.3em 间隙。仅在副行文本非空时测量，
    // 无翻译/罗马音的歌零额外开销。此值在动画中按进度逐行叠加（见
    // [_transExtraHeightFor]），也是 renderer 副行"长出"位移的取值来源。
    final List<double> auxHeights = List<double>.filled(
      _lines.length,
      0,
    );
    for (int i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      final String? auxText = currentDisplayMode == LyricDisplayMode.roma
          ? line.roma
          : line.translation;
      if (auxText == null || auxText.isEmpty) continue;
      auxHeights[i] = LyricLayout.auxSubHeight(
        fontSize,
        LyricLayout.measureAuxRows(auxText, fontSize, maxLineWidth),
      );
    }
    _auxSubHeights = auxHeights;
    // 重置激活间奏（lines 变化时）
    _activeInterludeIdx = -1;
    _lastActiveAnchorIdx = -1;
    _interludeExpandProgress = 0;
  }

  @override
  void initState() {
    super.initState();
    // createTicker 由 SingleTickerProviderStateMixin 提供，
    // 在 widget 不可见时自动暂停（muted），节省 CPU。
    _ticker = createTicker(_onTick);
    // 帧时钟基准：必须在启动驱动源前归零，避免 eco Timer 首帧读到未初始化值。
    _lastElapsed = Duration.zero;
    // 省电模式：挂载即按当前 eco 偏好确定性建立驱动源——eco 开且锁定 → 直接起
    // 不依赖 vsync 的 60fps eco Timer；eco 关 → 起满帧 Ticker。不再裸调
    // _startTickerIfNeeded()：否则在无 Surface 的 headless 引擎（升级后常见拉起路径）
    // 里 Ticker 被 mute、_onTick 从不触发，限帧自我纠正失效，页面停在 120Hz，
    // 必须拨动开关才恢复。改走 _syncEcoDriver() 与拨动开关走同一条路径。
    _syncEcoDriver();
    // P0-A：监听 App 生命周期——退后台挂起驱动源、回前台恢复（见 _syncEcoDriver）
    WidgetsBinding.instance.addObserver(this);
    // 自动回弹触发时恢复模糊（由 _computeLineBlur 自动处理）
    _scrollController.onAutoReturn = () {};
    // 解耦：初始化权威时间；提供 positionListenable 时内部订阅位置更新
    _authorityTimeMs = widget.currentTimeMs;
    final listenable = widget.positionListenable;
    if (listenable != null) {
      _readAuthorityFrom(listenable);
      listenable.addListener(_onExternalPosition);
    }
    // 监听字号/行间距偏好变化，实时刷新（设置页滑块、长按菜单调节后立即生效）
    LyricPreferences.instance.addListener(_onPreferencesChanged);
    // 加固：首帧后再确认一次驱动源，覆盖 headless 挂载 → 前台 attach 过渡期
    // 可能出现的驱动源漂移（如 attach 后 TickerMode 变化意外拉起 Ticker）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncEcoDriver();
    });
  }

  /// P0-A：跟踪 TickerMode（TabBarView 切走时 Ticker 自动 mute，Timer 需同步挂起）。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool muted = !TickerMode.of(context);
    if (muted != _tickerModeMuted) {
      _tickerModeMuted = muted;
      _syncEcoDriver();
    }
  }

  /// P0-A：App 退后台挂起驱动源，回前台恢复（见 _syncEcoDriver）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (suspended == _lifecycleSuspended) return;
    _lifecycleSuspended = suspended;
    _syncEcoDriver();
  }

  /// v3 优化：幂等启动 Ticker。
  /// 在恢复播放、用户交互、lines 变化等场景调用。
  void _startTickerIfNeeded() {
    if (_isTickerRunning) return;
    _isTickerRunning = true;
    _lastElapsed = Duration.zero;
    _ticker.start();
  }

  /// v3 优化：幂等停止 Ticker。
  /// 在暂停且所有动画收敛后调用，节省 CPU。
  void _stopTickerIfNeeded() {
    if (!_isTickerRunning) return;
    _isTickerRunning = false;
    _ticker.stop();
  }

  /// 从 listenable 读取并校正权威时间。
  void _readAuthorityFrom(ValueListenable<Duration> listenable) {
    final raw = listenable.value;
    _authorityTimeMs = widget.adaptTimeMs?.call(raw) ?? raw.inMilliseconds;
  }

  /// positionNotifier 每 ~200ms 回调：仅更新权威时间并唤醒驱动源，
  /// 不触发 setState（视觉更新由 _onTick → repaintNotifier 快路径完成）。
  /// 唤醒语义对齐原 didUpdateWidget 的 currentTimeMs 分支（含 eco 锁定判断）。
  void _onExternalPosition() {
    final listenable = widget.positionListenable;
    if (listenable == null || !mounted) return;
    final prev = _authorityTimeMs;
    _readAuthorityFrom(listenable);
    if (_authorityTimeMs == prev) return;
    if (widget.isPlaying) {
      // 统一走 _syncEcoDriver：锁定 → 确保 60fps Timer；解锁/关闭 → Ticker 满帧
      _syncEcoDriver();
    }
  }

  /// 省电模式驱动源同步：在 Ticker（满帧）与 60fps Timer 之间切换。
  ///
  /// - 页面不可见（TabBarView 切走 / App 退后台）→ 挂起全部驱动源（P0-A）
  /// - eco 开启且锁定 → 停 Ticker，用 16.67ms Timer 驱动 _onTick，
  ///   把实际帧生产限制到 60fps（Ticker 每帧 scheduleFrame 会让 120Hz 屏
  ///   始终 120fps，仅节流 _onTick 计算省不掉帧）。
  /// - 解锁 / eco 关闭 → 取消 Timer，恢复 Ticker 满帧。
  ///
  /// 所有"唤醒驱动"的路径一律走本方法，保证任意时刻至多一个驱动源：
  /// 裸调 _startTickerIfNeeded 会出现 Ticker + Timer 并存，而 Ticker 被
  /// TickerMode mute 时 _onEcoTimerTick 会因 _isTickerRunning 持续早退，
  /// 驱动源实质失效（"切歌后省电模式失效、须重新开关"的一类根因）。
  void _syncEcoDriver() {
    // P0-A：不可见时挂起。Ticker 此刻本就被 TickerMode/引擎 mute（不回调、
    // 不产帧），Timer 则不受任何可见性约束，必须显式取消——否则逐字播放中
    // （恒不收敛）切走 tab / 退后台后仍以 60Hz 驱动 _onTick → 离屏重绘。
    if (_lifecycleSuspended || _tickerModeMuted) {
      _resumeGapPending = true;
      if (_ecoDriverBound) {
        PlayerFrameDriver.instance.removeListener(_onEcoFrameTick);
        _ecoDriverBound = false;
      }
      return;
    }
    final bool wantTimer = LyricPreferences.instance.ecoMode && !_ecoUnlocked;
    if (wantTimer) {
      if (_isTickerRunning) {
        _stopTickerIfNeeded();
      }
      if (!_ecoDriverBound) {
        // 挂在共享节拍上：与封面旋转/频谱同相位，避免两个独立 16ms Timer
        // 交错产帧把整页推到 120fps（各组件更新率仍为 60fps，无视觉降级）。
        PlayerFrameDriver.instance.addListener(_onEcoFrameTick);
        _ecoDriverBound = true;
      }
    } else {
      if (_ecoDriverBound) {
        PlayerFrameDriver.instance.removeListener(_onEcoFrameTick);
        _ecoDriverBound = false;
      }
      if (!_isTickerRunning) {
        // 复用幂等启动：Ticker 重启后首帧回调传 elapsed=0，必须重置 _lastElapsed
        // 使首帧 dt=0，否则会算出负 dt（间奏点动画时钟指数爆炸）。
        _startTickerIfNeeded();
      }
    }
  }

  /// eco 锁定态下由共享 60fps 帧驱动推进：以 16ms 步进推进帧时钟，调用 [_onTick]。
  void _onEcoFrameTick() {
    if (!mounted) return;
    if (_isTickerRunning) {
      // Ticker 与 Timer 并存：Timer 被 _isTickerRunning 阻塞，本帧不驱动。
      return;
    }
    // 用 _lastElapsed + 16ms 作为本帧时间：_onTick 内 dt 即 16ms，动画按真实时间推进
    _onTick(_lastElapsed + PlayerFrameDriver.step);
  }

  /// v3 优化：检测视口附近 renderer 是否已收敛。
  /// 检查当前行的 WordRenderer + 视口内 LineRenderer 的 isConverged。
  bool _areRenderersConverged() {
    final currentRenderer = _wordRenderers[_currentLineIndex];
    if (currentRenderer != null && !currentRenderer.isConverged) {
      return false;
    }
    final int overscan = _overscan;
    final int startIdx = math.max(0, _currentLineIndex - overscan);
    final int endIdx = math.min(
      widget.lines.length,
      _currentLineIndex + overscan,
    );
    for (int i = startIdx; i < endIdx; i++) {
      final renderer = _lineRenderers[i];
      if (renderer != null && !renderer.isConverged) {
        return false;
      }
    }
    return true;
  }

  /// 按歌词行时长计算"入场/退场模糊淡出"速率（/s）。
  ///
  /// 时长 = `clamp(行时长 × 40%, 60ms, 1000ms)`：快歌（每行短）更快淡完、
  /// 慢歌最多 1s；行时长为 0/未知时按 1s 处理。
  /// 假定量从 ~1 指数衰减到 alpha 阈值 0.001，故 rate = ln(1000) / 时长(秒)。
  double _fadeRateForMs(int lineDurationMs) {
    double ms = lineDurationMs > 0 ? lineDurationMs * 0.4 : 1000.0;
    if (ms > 1000) ms = 1000;
    if (ms < 60) ms = 60; // 绝对下限，避免瞬时淡出或除零
    return math.log(1000.0) / (ms / 1000.0);
  }

  /// 偏好变化时触发重绘。
  ///
  /// **始终 setState**：偏好变化（字号/字重/行距等）需要触发 build 重新测量。
  /// 若仅依赖 _onTick 末尾的 hasVisualChange 判断，在播放中但当前行未切换时
  /// hasVisualChange 为 false，不会 setState，导致布局不更新。
  ///
  /// **字体变化时的特殊处理**：失效所有缓存，强制下帧重算：
  /// - 行高缓存：让 `_recomputeLineHeightsIfNeeded` 重测所有行高度
  ///   （TextPainter 用新 fontFamily layout，行高/换行可能变化）
  /// - WordRenderer/LineRenderer 内部绑定：清空 _wordRenderers/_lineRenderers,
  ///   让它们用新字体重新测量 word 宽度（_ensureBound）并重置 alpha 状态
  void _onPreferencesChanged() {
    // 字体/字重变化时失效所有依赖字体测量的缓存
    final currentFontFamily = LyricLayout.fontFamily;
    final currentFontWeight = LyricLayout.fontWeight.value;
    if (currentFontFamily != _cachedFontFamily ||
        currentFontWeight != _cachedFontWeight) {
      // 失效行高缓存（让 _recomputeLineHeightsIfNeeded 重算）
      _cachedFontFamily = null;
      _cachedFontWeight = -1;
      // 失效 WordRenderer/LineRenderer 内部绑定（清空后下次 paint 会重新创建 +
      // 重新 _ensureBound 测量 word 宽度，避免用旧字体宽度做换行判断）
      _releaseRendererCaches();
    }
    // 统一走 _syncEcoDriver 确定驱动源（eco 开关变化：锁定 → 60fps Timer；
    // 解锁/关闭 → Ticker 满帧），并确保偏好变化触发重建
    _syncEcoDriver();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant AppleLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // lines 列表缩短时，清理不再存在的行索引对应的 renderer 缓存，避免内存泄漏
    _wordRenderers.removeWhere((key, renderer) {
      if (key < widget.lines.length) return false;
      renderer.dispose();
      return true;
    });
    _lineRenderers.removeWhere((key, renderer) {
      if (key < widget.lines.length) return false;
      renderer.dispose();
      return true;
    });
    // v3 优化：恢复播放或切歌时立即重启驱动（停止态恢复）。
    //
    // **省电模式关键**：统一走 [_syncEcoDriver] 决策——eco 开启且锁定 →
    // 确保 60fps Timer 在跑（绝不能裸起 Ticker，否则每 ~200ms position 更新
    // 都会以 120Hz 重启一帧，破坏"锁 60fps"）；解锁/关闭 eco → Ticker 满帧。
    // 任意时刻至多一个驱动源，由本方法集中保证。
    if (oldWidget.isPlaying != widget.isPlaying && widget.isPlaying) {
      _syncEcoDriver();
    }
    // v3 优化：切歌（lines 引用变化）时重启驱动，重新推进新行的 renderer
    if (!identical(oldWidget.lines, widget.lines)) {
      // 切歌后首次定位直接瞬移到新歌当前行（避免从旧歌曲的长距离滚动）
      _scrollController.resetInitialJump();
      // 切歌诊断日志：定位"切歌后省电模式失效须重新开关"问题用（低频事件）
      _syncEcoDriver();
    }
    // P0-A: 非逐字歌词在播放中可能已停 Ticker（静止省电）。position 更新
    //（约 200ms，经 ListenableBuilder 重建本 widget）时唤醒一帧：若确实
    // 发生行切换 / 滚动回弹 / 间奏等动画则继续跑，否则下一帧再次收敛停止。
    // **省电模式锁定态**：由 60fps Timer 持续驱动，无需（也不应）重启 Ticker。
    if (oldWidget.currentTimeMs != widget.currentTimeMs && widget.isPlaying) {
      _syncEcoDriver();
    }
    // 解耦：positionListenable 实例变化时重新挂载订阅
    // （切歌时若宿主换了 notifier 实例，旧订阅失效 → position 永久静默 →
    //  停帧后无法唤醒，表现为"省电模式失效"，故此处的切换必须可观测）
    if (oldWidget.positionListenable != widget.positionListenable) {
      oldWidget.positionListenable?.removeListener(_onExternalPosition);
      final listenable = widget.positionListenable;
      if (listenable != null) {
        _readAuthorityFrom(listenable);
        listenable.addListener(_onExternalPosition);
      } else {
        _authorityTimeMs = widget.currentTimeMs;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.positionListenable?.removeListener(_onExternalPosition);
    if (_ecoDriverBound) {
      PlayerFrameDriver.instance.removeListener(_onEcoFrameTick);
      _ecoDriverBound = false;
    }
    _ticker.dispose();
    _scrollController.dispose();
    _repaintNotifier.dispose();
    _releaseRendererCaches();
    LyricPreferences.instance.removeListener(_onPreferencesChanged);
    super.dispose();
  }

  /// 释放行渲染器持有的 TextPainter 与 ui.Image，再清空按行缓存。
  void _releaseRendererCaches() {
    for (final renderer in _wordRenderers.values) {
      renderer.dispose();
    }
    for (final renderer in _lineRenderers.values) {
      renderer.dispose();
    }
    _wordRenderers.clear();
    _lineRenderers.clear();
  }

  // ============== 工具方法 ==============

  /// 获取或创建指定行的 [WordRenderer]。
  WordRenderer _wordRendererFor(int index) =>
      _wordRenderers.putIfAbsent(index, () => WordRenderer());

  /// 获取或创建指定行的 [LineRenderer]。
  LineRenderer _lineRendererFor(int index) =>
      _lineRenderers.putIfAbsent(index, () => LineRenderer());

  // ============== 动画推进 ==============

  void _onTick(Duration elapsed) {
    // 使用 Ticker 的调度器时钟（测试中为模拟时间）计算 dt，
    // 避免 DateTime.now() 在测试中返回真实墙钟时间导致弹簧不推进。
    double dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;

    // 检测 Ticker 曾被 mute（TabBarView 切走 / App 退后台 / 长时间卡顿）：
    // 恢复后首帧 dt 会等于切走时长（远大于正常帧间隔）。mute 期间
    // 间奏点动画时钟（帧 dt 累积）冻结而歌曲继续播放，需在本帧把时钟
    // 对齐到真实窗口进度（见 _updateInterlude 的 alignDotsToRealTime）。
    // 该检测为 O(1) 比较，不增加每帧开销。
    // P0-A：挂起恢复（Timer 路径 dt 恒为 16ms，检测不到 gap）后的首帧
    // 也按 gap 恢复处理，对齐间奏点等帧时钟动画到真实进度。
    final bool tickerGapResume =
        dt > _tickerGapResumeThreshold || _resumeGapPending;
    _resumeGapPending = false;

    // ============== 歌词省电模式：锁定 60fps ==============
    // 解锁（120Hz 满帧）仅限"用户驱动"的滚动：
    //   1. 手指正按住拖动（isUserScrolling）
    //   2. 松手后惯性仍在滑行（isWaitingForAutoReturn 且弹簧未静止）——惯性速度高，
    //      60fps 会明显发卡，必须保持满帧顺滑
    // 其余一律保持 60fps：
    //   - 惯性已停、仅等待自动回弹倒计时（画面静止）→ 锁 60fps（这正是"拖动后要锁回"的原始 bug）
    //   - 自动回弹动画 / 播放行切换的自动滚动 → 60fps 足够顺滑
    // **真正限帧由 [_syncEcoDriver] 切换 Ticker/Timer 实现**：锁定 → 停 Ticker、
    // 用 60fps Timer 驱动 _onTick（限制实际帧生产）；解锁/关闭 eco → Ticker 满帧。
    if (LyricPreferences.instance.ecoMode) {
      final bool wasUnlocked = _ecoUnlocked;
      _ecoUnlocked =
          _scrollController.isUserScrolling ||
          (_scrollController.isWaitingForAutoReturn &&
              !_scrollController.isPosYSpringSettled);
      _syncEcoDriver();
    }

    // P0: 推进逐字动画平滑时间（上浮/字内渐变的进度来源）。
    // positionStream 每 ~200ms 才给一个权威位置，播放中若直接用它会
    // 造成动画"追到旧目标后冻结 ~120ms"的卡顿；这里用帧时钟每帧推进，
    // 收到新权威位置时对齐校正。
    //
    // 校正策略：正常 position 更新用**平滑逼近**而非硬跳。音频时钟与帧时钟
    // 存在漂移，若权威位置硬跳跨过逐字边界，字切换会来回抖动（英文歌字短、
    // 边界密集时更明显，表现为"下一个字闪一下"）。seek/切歌等大跳变仍直接吸附。
    // 暂停时冻结在权威位置。播放流未就绪（切歌 loading / 缓冲 buffering）
    // 同样走冻结分支：期间 positionStream 静默、权威值冻结，若仍按帧时钟
    // 推进会反复触发下方 300ms 兜底回吸，形成"前进→跳回"锯齿，
    // 字内渐变随之来回抽搐。
    if (widget.isPlaying && !widget.playbackNotReady) {
      _smoothPosMs += dt * 1000;
      if (_authorityTimeMs != _lastAuthorityPosMs) {
        final int jump = (_authorityTimeMs - _lastAuthorityPosMs).abs();
        _lastAuthorityPosMs = _authorityTimeMs;
        if (jump > _smoothPosSeekJumpMs) {
          // seek/大跳变：直接吸附，避免平滑拖尾
          _smoothPosMs = _authorityTimeMs.toDouble();
        } else {
          // 正常 position 更新：平滑逼近权威，避免硬跳跨字边界造成闪烁
          final double corr = 1.0 - math.exp(-_smoothPosCorrRate * dt);
          _smoothPosMs += (_authorityTimeMs - _smoothPosMs) * corr;
        }
      } else if ((_smoothPosMs - _lastAuthorityPosMs).abs() > 300) {
        // 兜底：权威位置长时间不更新（缓冲等）时防止平滑值漂移过大
        _smoothPosMs = _lastAuthorityPosMs.toDouble();
      }
    } else {
      _smoothPosMs = _authorityTimeMs.toDouble();
      _lastAuthorityPosMs = _authorityTimeMs;
    }

    // 1. 找当前行
    // 纯文本歌词（无时间轴）不高亮、不滚动、不模糊，直接平铺显示
    // 性能优化：缓存 hasTimestamps 结果，避免每帧 O(N) 遍历所有 lines
    final bool hasTimestamps = _cachedHasTimestamps;
    // P0: 缓存行查找结果：currentTimeMs 与 lines 引用都未变化时跳过二分查找。
    // （暂停时 currentTimeMs 不变，播放中每帧 200ms 才有一次变化，绝大多数帧直接命中）
    if (_currentTimeMsCache != _authorityTimeMs ||
        !identical(_linesCacheRef, widget.lines)) {
      _currentTimeMsCache = _authorityTimeMs;
      _linesCacheRef = widget.lines;
      _currentLineIndex = hasTimestamps
          ? AppleLyricsView.findCurrentLineIndex(widget.lines, _authorityTimeMs)
          : -1;
    }

    // 1.5 行切换副行交接 + 收起推进（必须在下方 renderer 注入与滚动目标
    // 计算之前执行，保证本帧渲染用的就是交接后的进度，切换帧视觉与上一帧
    // 严格连续，不存在"旧副行闪一帧再消失"的中间态）。
    if (_currentLineIndex != _previousLineIndex) {
      // 上一行副行收起登记：从当前展开进度继续收（c0 = 1 - p），
      // 收起起点 = 切换瞬间的副行实际位置，无跳变。
      // 独立判断：current 变为 -1（间奏/结尾）时同样要收起。
      final int outgoingIdx = _previousLineIndex;
      if (outgoingIdx >= 0 && _translationExpandProgress > 0.001) {
        _transCollapsing[outgoingIdx] = (1.0 - _translationExpandProgress)
            .clamp(0.0, 1.0);
        // 兜底：极端连切导致条目过多时移除最旧（最小 key）条目
        if (_transCollapsing.length > 4) {
          _transCollapsing.remove(
            _transCollapsing.keys.reduce((a, b) => a < b ? a : b),
          );
        }
      }
      // 过渡速率 = 退场行主文本退场淡出速率（[_fadeRateForMs]：快歌快、
      // 慢歌最多 1s），副行收起与原歌词退场严格同速；无退场行（首行/
      // 间奏后）用入场行时长。收起与展开共用该速率，维持下方行零位移。
      // 边界防御：切歌等 lines 整体替换场景下，outgoingIdx 可能超出新歌词
      // 行数（_previousLineIndex 尚未随新行更新）。越界访问会让 _onTick 每帧
      // 抛异常、歌词永久冻结（外观与"省电模式失效"一致），故显式钳制。
      _transSwitchRate = outgoingIdx >= 0 && outgoingIdx < widget.lines.length
          ? _fadeRateForMs(widget.lines[outgoingIdx].duration)
          : (_currentLineIndex >= 0 && _currentLineIndex < widget.lines.length
                ? _fadeRateForMs(widget.lines[_currentLineIndex].duration)
                : 14.0);
      // 新当前行展开进度重置：该行此前若正在收起，从当前进度续升（回环
      // 连切连续性）；否则从头长出。
      final double? resume = _currentLineIndex >= 0
          ? _transCollapsing.remove(_currentLineIndex)
          : null;
      _translationExpandProgress = resume != null ? 1.0 - resume : 0.0;
    }
    // 退场行副行收起推进：暂停时也推进（UI 过渡而非播放驱动），收完移除，
    // 保证 animConverged 判定与静态停帧不被残留占位阻塞。
    // 快连切时旧条目沿用最新过渡速率（近似，多条目仅在极快连切时短暂共存）。
    if (_transCollapsing.isNotEmpty) {
      final double collapseDecay = 1 - math.exp(-_transSwitchRate * dt);
      final List<int> done = <int>[];
      _transCollapsing.forEach((k, v) {
        // 指数趋近 1（与入场 _translationExpandProgress 同一推进方式）。
        // 原实现是线性 `v + decay`：1/rate ≈ 150ms 就收完，而入场要 ~450ms，
        // 出场比入场快约 3 倍，观感是"一闪而过、衔接僵硬"。
        //
        // 更关键的是它让本文件注释声明的不变量真正成立：稳态切行时
        // 收起余量 (1-c) = p₀·e^(-λt)、展开量 = 1-e^(-λt)，两者之和恒为 p₀
        // （上一行切走瞬间通常已完全展开，p₀=1）→ 当前行以下的行在切行期间
        // **零位移**；线性推进下该和会中途掉 ~18%，表现为下方歌词整块抖一下。
        final double next = v + (1.0 - v) * collapseDecay;
        if (next >= 0.99) {
          done.add(k);
        } else {
          _transCollapsing[k] = next;
        }
      });
      for (final k in done) {
        _transCollapsing.remove(k);
      }
    }

    // 2. 推进滚动控制器（需要 lineHeight 与 intervalMs 计算目标 posY）
    if (_currentLineIndex >= 0) {
      final fontSize = LyricLayout.fontSize(context);
      final mainLineHeight = fontSize * LyricLayout.lineHeight;
      // 当前行实际高度（含换行）：用预计算 _lineHeights，无则降级 mainLineHeight；
      // 副行动画高度动态叠加（展开中增长 / 收起中回落）
      final currentLineHeight =
          (_currentLineIndex < _lineHeights.length
              ? _lineHeights[_currentLineIndex]
              : mainLineHeight) +
          _transExtraHeightFor(_currentLineIndex);
      // 当前行顶部 y（前面所有行高度的累加 + 间奏占位偏移 + 上方副行动画高度）
      final currentLineRawTop = (_currentLineIndex < _lineTops.length
          ? _lineTops[_currentLineIndex]
          : _currentLineIndex * mainLineHeight);
      final currentLineTop =
          currentLineRawTop +
          _interludeOffsetBefore(_currentLineIndex) +
          _transDeltaBefore(_currentLineIndex);
      // intervalMs = 下一行 startTime - 当前行 endTime，用于动态 stiffness
      int intervalMs = 0;
      if (_currentLineIndex < widget.lines.length - 1) {
        final current = widget.lines[_currentLineIndex];
        final next = widget.lines[_currentLineIndex + 1];
        intervalMs = next.startTime - current.endTime;
      }
      _scrollController.setCurrentLine(
        _currentLineIndex,
        // 暂停时视为 seeking 模式（固定弹簧参数），播放时用动态参数
        isSeeking: !widget.isPlaying,
        lineHeight: currentLineHeight,
        intervalMs: intervalMs,
        lineTop: currentLineTop,
        // 间奏激活或占位还在收起时都用柔和 spring（stiffness=40, damping=10），
        // 让歌词跟随占位收起时有阻尼感而非瞬移
        isInterludeActive: _interludeExpandProgress > 0.01,
      );
    }
    _scrollController.tick(dt);

    // 4. 推进每行的 renderer
    // 性能优化：只 tick 视口附近的行（前后各 15 行），避免 200+ 行全量 tick。
    // 当前行用 WordRenderer（逐字 alpha + 上浮），其他行用 LineRenderer。
    final int overscan = _overscan;
    final int startIdx = math.max(0, _currentLineIndex - overscan);
    final int endIdx = math.min(
      widget.lines.length,
      _currentLineIndex + overscan,
    );
    // P1-G: 顺带聚合"是否有 renderer 仍在动画"，替代 _hasRendererAlphaChanged
    // 的二次 O(±10 行) 遍历（hasVisualChange 与收敛判断复用）。
    bool anyRendererAnimating = false;
    for (int i = startIdx; i < endIdx; i++) {
      final line = widget.lines[i];
      final isActive = i == _currentLineIndex;
      // 文字层不再使用 scale 弹簧，当前行瞬移到 activeScale
      final scale = isActive
          ? LyricLayout.activeScale
          : (widget.enableScale
                ? LyricLayout.inactiveScale
                : LyricLayout.activeScale);
      final bool useWordRenderer = isActive && line.hasWordTiming;
      if (useWordRenderer) {
        final renderer = _wordRendererFor(i);
        // 翻译副行浮出/渐显进度（仅当前行注入；非当前行 WordRenderer 不绘制副行）。
        // alpha 与位置共用展开进度，淡入淡出贯穿整个过渡。
        // 当前行恒为入场：副行绕底边从下翻转出现（方向标记必须无条件赋值，
        // 字段跨帧保留，漏设会让副行残留在上一行的出场方向上）。
        renderer.translationExpand = _translationExpandProgress;
        renderer.translationFade = _translationExpandProgress;
        renderer.translationExiting = false;
        renderer.setLineState(
          isActive: true,
          scale: scale,
        );
        // 用平滑时间驱动逐字动画（上浮/字内渐变），避免 positionStream 5fps 卡顿
        renderer.tick(dt, _smoothPosMs.round());
        if (!renderer.isConverged) anyRendererAnimating = true;
      } else {
        final renderer = _lineRendererFor(i);
        // 副行动画注入（必须无条件赋值——renderer 字段跨帧保留，漏设会残留
        // 旧值画出幽灵副行）：
        // - 当前行：跟随全局展开/渐显进度，LRC 当前行由此获得与 KRC 当前行
        //   一致的长出动画（此前固定位置固定 alpha，切行瞬间出现）；
        // - 收起中的退场行：注入 1 - 收起进度，副行从当前位置平滑缩回主行底
        //   并渐隐，消除切行时副行瞬间消失的硬切；
        // - 其余非当前行：两值恒 0，副行不绘制（与旧行为一致）。
        if (isActive) {
          renderer.translationExpand = _translationExpandProgress;
          renderer.translationFade = _translationExpandProgress;
          // 当前行：入场，绕副行底边从下翻转出现。
          renderer.translationExiting = false;
        } else {
          final double? c = _transCollapsing[i];
          renderer.translationExpand = c == null ? 0.0 : 1.0 - c;
          renderer.translationFade = c == null ? 0.0 : 1.0 - c;
          // 收起中的退场行：出场，绕副行顶边向上翻转消失（入场/出场锚线不同，
          // 必须显式告知方向）；c == null 的行副行 alpha 为 0，方向无意义。
          renderer.translationExiting = c != null;
        }
        renderer.setLineState(
          isActive: isActive,
          scale: scale,
        );
        renderer.tick(dt);
        if (!renderer.isConverged) anyRendererAnimating = true;
      }
    }

    // 5. 间奏检测与推进
    // P1-C: 间奏检测只依赖 currentTimeMs（positionStream 约 200ms 更新一次），
    // 时间未变且占位动画已收敛时，跳过每帧 O(间奏数) 的线性遍历。
    // 占位未收敛（展开/收起中）时仍需每帧检测以正确处理 clear 时机。
    final bool interludeTimeChanged =
        _authorityTimeMs != _lastInterludeCheckTimeMs;
    final bool interludePlaceholderSettled = _activeInterludeIdx >= 0
        ? _interludeExpandProgress >= 0.999
        : _interludeExpandProgress <= 0.001;
    if (interludeTimeChanged ||
        !interludePlaceholderSettled ||
        tickerGapResume) {
      // 时间回退（seek/跳转回跳）时强制重置间奏点动画时钟：
      // setInterlude 幂等保护无法区分"每帧重复调用"与"seek 回到同一间奏"，
      // 不重置会导致动画从旧进度继续、甚至超时隐藏（间奏点不显示）。
      final bool timeRewound = _authorityTimeMs < _lastInterludeCheckTimeMs;
      _lastInterludeCheckTimeMs = _authorityTimeMs;
      _updateInterlude(
        forceDotsReset: timeRewound,
        // Ticker 曾被 mute（切走 tab / 退后台）恢复：动画时钟滞后于真实进度，
        // 需对齐到当前间奏窗口内的真实偏移（而非重置从 0 重播入场动画）。
        alignDotsToRealTime: tickerGapResume,
      );
    }

    // 6. 推进间奏点动画时钟（基于帧 dt，60fps 流畅，不受 positionStream 5fps 限制）
    // 暂停时不推进动画时钟，让间奏点随播放器一起暂停
    // P0: 降到 30fps 推进（累积帧时间，33ms 才 tick 一次），视觉无感但减半推进开销
    if (widget.isPlaying) {
      _interludeAccumulator += dt;
      if (_interludeAccumulator >= 1.0 / 30.0) {
        _interludeDots.tick(_interludeAccumulator);
        _interludeAccumulator = 0;
      }
    }

    // 7. 推进间奏占位 spring（_interludeExpandProgress）
    // 严格 AMLL：进入间奏时段 spring 展开 0 → 1，离开则 spring 收起 1 → 0
    // 用指数衰减逼近目标值：progress += (target - progress) * (1 - exp(-speed * dt))
    // speed = 18 对应 ~300ms 内基本到位（AMLL 视觉过渡感）
    final double interludeTarget = _activeInterludeIdx >= 0 ? 1.0 : 0.0;
    // 展开用 18.0（~300ms 快速展开），收起用 9.0（~767ms 平滑收起，匹配间奏点消失动画 750ms）
    final double interludeSpeed = _activeInterludeIdx >= 0 ? 18.0 : 9.0;
    // P0: 暂停时直接吸附到目标，不再指数逼近。
    // 指数衰减永不精确到达 target，且暂停时动画应冻结；
    // 此前暂停时 progress 缓慢逼近，收敛检测 |progress-target|<0.001 依赖它，
    // 有间奏点的歌曲暂停后 Ticker 迟迟不收敛 → 每帧重绘（间奏点+辉光 shader）→ 120fps。
    if (widget.isPlaying) {
      _interludeExpandProgress +=
          (interludeTarget - _interludeExpandProgress) *
          (1 - math.exp(-interludeSpeed * dt));
    } else {
      _interludeExpandProgress = interludeTarget;
    }
    // 收起到接近 0 时直接归零，避免无限逼近占着微小高度
    if (_activeInterludeIdx < 0 && _interludeExpandProgress < 0.001) {
      _interludeExpandProgress = 0;
      // 收起完成 = 间奏点生命周期的终点：占位已归零，圆点（属于占位行）
      // 与 anchor 一并释放。
      // **必须在此处收口**：progress 归零后画面随即收敛，同一帧末尾的
      // animConverged 判断会停掉 Ticker，之后不再有任何帧回调去执行
      // _updateInterlude 的收尾分支——若把释放放在那里，间奏点会永久
      // 停留在 _isActive（时钟冻结、状态悬空），任何后续帧都不会再清除它。
      _interludeDots.clear();
      _lastActiveAnchorIdx = -1;
    }

    // 7.5 翻译副行展开进度：当前行、开启翻译且有副行文本 → 展开，否则收起。
    // alpha 与位置共用同一进度（淡入淡出贯穿整个过渡时长，慢歌最多 ~1s
    // 清晰可感知），因此不再维护独立的 fade 状态。
    // 速率随行时长自适应：过渡期间（有退场行在收起）用切行捕获的
    // [_transSwitchRate]，与收起严格同速（稳态切行「收起余量 + 展开量 ≡
    // 预留总量」，当前行以下的行零位移）；纯展开（首次出现/翻译开关切换）
    // 用当前行时长速率；无当前行兜底 14.0。
    // **暂停时也指数推进（不再吸附）**：开关切换/切行是用户主动触发的 UI
    // 过渡而非播放驱动，暂停中切翻译开关同样要有动画；推进到收敛后
    // animConverged 成立、Ticker 自然停止，不会造成持续重绘。
    final bool transVisible =
        _currentLineIndex >= 0 &&
        LyricPreferences.instance.showTranslation &&
        _lineHasAuxText(_currentLineIndex);
    final double transExpandTarget = transVisible ? 1.0 : 0.0;
    final double transRate = _transCollapsing.isNotEmpty
        ? _transSwitchRate
        : (_currentLineIndex >= 0 && _lineHasAuxText(_currentLineIndex)
              ? _fadeRateForMs(widget.lines[_currentLineIndex].duration)
              : 14.0);
    _translationExpandProgress +=
        (transExpandTarget - _translationExpandProgress) *
        (1 - math.exp(-transRate * dt));
    if (_translationExpandProgress < 0.001) _translationExpandProgress = 0;

    // 8. 行切换：上一当前行退场淡出交接
    if (_currentLineIndex >= 0 && _currentLineIndex != _previousLineIndex) {
      // 上一当前行退场交接：启动清晰层淡出，消除硬切。
      // KRC 行退场前由 WordRenderer 绘制，其 LineRenderer 实例那一帧根本没被
      // 调用过（alpha 停在 0、setLineState 输入缓存判定"未变"而早退），
      // 必须把逐字 alpha 均值交接过去才有可淡出的量；
      // LRC/纯文本行退场前本就是该实例绘制，沿用当前值、只换成快速退场速度。
      final int outgoing = _previousLineIndex;
      if (outgoing >= 0 && outgoing < widget.lines.length) {
        final WordRenderer? outgoingWord = _wordRenderers[outgoing];
        final LineRenderer outgoingLine = _lineRendererFor(outgoing);
        final bool outgoingWasWordMode =
            outgoingWord != null && widget.lines[outgoing].hasWordTiming;
        // 退场淡出时长随该行歌词时长动态：快歌更快、慢歌最多 1s
        final double exitRate = _fadeRateForMs(widget.lines[outgoing].duration);
        outgoingLine.beginExitFadeFrom(
          outgoingWasWordMode
              ? outgoingWord.averageWordAlpha
              : outgoingLine.currentAlpha,
          rate: exitRate,
        );
      }
    }
    _previousLineIndex = _currentLineIndex;

    // 11. v3 优化：检测是否暂停且所有动画都已收敛到稳态。
    // 收敛条件：
    //   - 暂停中（!widget.isPlaying）
    //   - scroll controller 已收敛（无用户滚动、无等待回弹、posY 弹簧稳定）
    //   - 间奏 progress 已到目标
    //   - 翻译副行展开进度已到目标且无收起中的行
    //   - 视口附近 renderer alpha 已收敛
    // 收敛时停止 Ticker，恢复播放或用户交互时由 didUpdateWidget /
    // _onTapDown / _onVerticalDragUpdate 重新启动。
    // P0-A：非逐字歌词（LRC 逐行 / 纯文本，整首歌无 word timing）在播放中
    // 画面同样静止（无逐字渐变/上浮/辉光），允许播放中停 Ticker 省电；
    // position 更新（约 200ms）由 didUpdateWidget 唤醒一帧检查即可。
    // 逐字歌词（KRC / 字级 LRC，含本地/云盘音乐的 LRC 逐字）必须保持
    // Ticker 持续推进动画，由 canStopWhilePlaying 排除。
    // 间奏激活期间（_activeInterludeIdx >= 0）间奏点有呼吸/亮起动画，
    // 也不能停 Ticker，否则圆点冻结。
    final bool animConverged =
        _scrollController.isConverged &&
        (_interludeExpandProgress - interludeTarget).abs() < 0.001 &&
        (_translationExpandProgress - transExpandTarget).abs() < 0.001 &&
        _transCollapsing.isEmpty;
    // P1-G: renderer 的收敛检测（O(±10 行) 遍历）只在需要"停 Ticker 决策"时
    // 执行：逐字歌词播放中永远不会停（P0-A 排除），跳过该循环；
    // 非逐字播放中仅每 200ms 唤醒帧执行一次。
    final bool needsStopDecision =
        !widget.isPlaying || !_cachedHasAnyWordTiming;
    final bool canStopWhilePlaying =
        !_cachedHasAnyWordTiming && _activeInterludeIdx < 0;
    final bool deepConverged =
        !needsStopDecision || _areRenderersConverged();
    if (animConverged &&
        deepConverged &&
        (!widget.isPlaying || canStopWhilePlaying)) {
      _stopTickerIfNeeded();
      // 同时停掉 eco 限帧 Timer：静态画面无需继续驱动 _onTick
      //（否则 Timer 每 16ms 触发一次 setState，仍会产生 60fps 空帧）。
      if (_ecoDriverBound) {
        PlayerFrameDriver.instance.removeListener(_onEcoFrameTick);
        _ecoDriverBound = false;
      }
      // 最后一帧 setState 确保稳态画面渲染
      setState(() {});
      return;
    }

    // 12. v3 优化：检测本帧是否有视觉变化，无变化则跳过 setState。
    // 检测阈值（0.5px / 0.001）远低于人眼感知，肉眼不可见的变化才跳过。
    final double currentPosY = _scrollController.posY;
    final bool hasVisualChange =
        _currentLineIndex != _lastRepaintCurrentLineIndex ||
        (currentPosY - _lastRepaintPosY).abs() > 0.5 ||
        (_interludeExpandProgress - _lastRepaintInterludeProgress).abs() >
            0.001 ||
        (_translationExpandProgress - _lastRepaintTransExpand).abs() > 0.001 ||
        // 副行收起期间占位高度逐帧变化，需持续重绘
        _transCollapsing.isNotEmpty ||
        anyRendererAnimating ||
        // P0: 暂停时间奏点动画已冻结（tick 跳过、画面静止），
        // shouldRender 仅表示"处于间奏时段"，不应再驱动每帧重绘
        (widget.isPlaying && _interludeDots.shouldRender);

    if (hasVisualChange) {
      _lastRepaintCurrentLineIndex = _currentLineIndex;
      _lastRepaintPosY = currentPosY;
      _lastRepaintInterludeProgress = _interludeExpandProgress;
      _lastRepaintTransExpand = _translationExpandProgress;
      // P0-1 方案 A：统一走持久化 painter 快路径（repaintNotifier 驱动文字层重绘），
      // 避免每帧 setState + build 重建整个 widget tree
      // （LayoutBuilder/GestureDetector/ShaderMask）。
      if (_painter != null) {
        _painter!.updatePerFrame(
          currentLineIndex: _currentLineIndex,
          posY: currentPosY,
          currentTimeMs: _authorityTimeMs,
          interludeExpandProgress: _interludeExpandProgress,
          activeInterludeIdx: _activeInterludeIdx,
          lastActiveAnchorIdx: _lastActiveAnchorIdx,
          transExpandProgress: _translationExpandProgress,
          auxSubHeights: _auxSubHeights,
          transCollapsing: _transCollapsing,
        );
        _repaintNotifier.fireRepaint();
      } else {
        setState(() {});
      }
    }
    // 无视觉变化：跳过 setState，节省 build + shouldRepaint 开销
  }

  /// 检测当前时间是否处于某个间奏时段，更新 [_activeInterludeIdx] 和 [_interludeDots]。
  ///
  /// 严格 AMLL 逻辑：遍历所有 [_interludeAfterIndices]，
  /// 找到第一个满足 `gapStart <= currentTime < gapEnd` 的间奏，
  /// 设置为激活间奏（占位动态展开 0 → totalHeight）。
  /// 若无激活，则清除间奏点并收起占位（totalHeight → 0）。
  ///
  /// 间奏时段：[line.endTime, next.startTime - interludeEarlyEndMs]，
  /// 250ms 提前结束以准备下一行渲染（与 AMLL 一致）。
  ///
  /// **间奏点同步收起**：间奏结束后不立即 `clear()` 间奏点，
  /// 让 `_animationTimeMs` 继续推进到 `interludeDuration`，
  /// 间奏点会自然完成消失动画（最后 750ms easeInBack 缩小）。
  /// 占位收起与点消失同步进行（都是 ~300-750ms）。占位收起完成后的
  /// `clear()` + anchor 释放由推进循环的归零分支收口（见 `_onTick`）。
  /// 该"继续播完消失动画"的行为只适用于**自然结束**（`isInExitPhase`）；
  /// 点击其他行歌词跳转 / seek 离开间奏时时钟仍在间奏早期，必须立即清除
  /// 圆点，否则会悬浮穿帮（见下方 else 分支）。
  /// [forceDotsReset] 为 true 时，即使命中的间奏与当前激活相同，也强制重置
  /// 间奏点动画时钟（`_interludeDots.setInterlude(..., forceReset: true)`）。
  /// 用于 seek/跳转回跳：幂等保护会忽略相同间奏，导致动画时钟从旧进度继续，
  /// 一旦超过间奏总时长，间奏点会直接隐藏（识别为"未启用"）。
  ///
  /// [alignDotsToRealTime] 为 true 时，把间奏点动画时钟对齐到
  /// `currentTimeMs - gapStart`（真实窗口内偏移）。用于 Ticker 被 mute
  /// （切走 tab / 退后台）后恢复：帧时钟冻结期间歌曲继续播放，动画时钟
  /// 滞后于真实进度，对齐后间奏点立即处于正确阶段，而非重置重播入场动画。
  void _updateInterlude({
    bool forceDotsReset = false,
    bool alignDotsToRealTime = false,
  }) {
    int foundIdx = -1;
    int? gapStart;
    int? gapEnd;
    for (int i = 0; i < _interludeAfterIndices.length; i++) {
      final int lineIdx = _interludeAfterIndices[i];
      if (lineIdx < 0 || lineIdx >= widget.lines.length - 1) continue;
      final current = widget.lines[lineIdx];
      final next = widget.lines[lineIdx + 1];
      // 激活窗口起点与 gap 判定（_recomputeLineHeightsIfNeeded）保持一致，
      // 均用"人声实际结束时间"（KRC 行 duration 覆盖尾音/空白时窗口起点会偏晚，
      // 导致短暂处于真实空档却未激活间奏点）。
      final start = AppleLyricsView.effectiveLineEndTime(current);
      final end = next.startTime - LyricLayout.interludeEarlyEndMs;
      if (_authorityTimeMs >= start && _authorityTimeMs < end) {
        foundIdx = i;
        gapStart = start;
        gapEnd = end;
        break;
      }
    }

    _activeInterludeIdx = foundIdx;

    if (foundIdx >= 0 && gapStart != null && gapEnd != null) {
      // 先确保间奏状态正确（新间奏会重置时钟，幂等命中的相同间奏保留），
      // 再按需校正动画时钟。
      _interludeDots.setInterlude(gapStart, gapEnd, forceReset: forceDotsReset);
      // 时钟漂移校正：帧时钟在 Ticker mute（切走 tab / 退后台）或页面重建
      // （TabBarView 默认销毁 State，新 State 时钟从 0 开始）期间滞后于真实
      // 进度。每次权威位置更新时比较偏差，超阈值（1s）即对齐到真实窗口偏移。
      // 正常播放下偏差不超过 position 更新粒度（约 200ms），不会误触发，
      // 因此不引入额外开销。
      if (alignDotsToRealTime ||
          _interludeDots.shouldRealignTo(_authorityTimeMs, driftMs: 1000)) {
        _interludeDots.alignToRealTime(_authorityTimeMs);
      }
      // 记录最后激活的 anchor 行索引（用于间奏结束后继续计算占位偏移）
      if (foundIdx < _interludeAfterIndices.length) {
        _lastActiveAnchorIdx = _interludeAfterIndices[foundIdx];
      }
    } else {
      // 间奏结束：不立即 clear() 间奏点
      // 让 _animationTimeMs 继续推进到 interludeDuration，
      // 间奏点会自然完成消失动画（最后 750ms easeInBack 缩小）
      //
      // 但仅限"自然结束"（时钟已在消失阶段）。用户点击其他行歌词跳转 /
      // 拖动进度条 seek 离开间奏时，时钟可能还停在间奏早期（长间奏尤甚），
      // 此时若放任其继续推进，满尺寸、满不透明度的圆点会在占位收起的
      // ~750ms 内悬浮在原 anchor 行，与已切换的歌词同屏 → 穿帮。
      // 这种情况直接清除圆点（_lastActiveAnchorIdx 不在此重置：占位偏移
      // 仍由 _interludeExpandProgress 平滑收起，避免下方行瞬间跳位）。
      //
      // 占位收起完成后的收尾（clear + 释放 anchor）统一在推进循环的
      // 归零分支处理——那里不受本方法的调用时机限制。
      if (!_interludeDots.isInExitPhase) {
        _interludeDots.clear();
      }
    }
    // 注意：间奏点动画时间由 _onTick 中的 _interludeDots.tick(dt) 推进，
    // 不依赖 currentTimeMs（positionStream 5fps 太卡）
  }

  // ============== 点击跳转与手动滚动 ==============

  void _onTapDown(TapDownDetails details) {
    // 用户交互唤醒驱动：统一走 _syncEcoDriver（eco 锁定 → Timer；否则 Ticker），
    // 避免裸起 Ticker 造成与 60fps Timer 并存、Ticker 被 mute 时 Timer 空转
    _syncEcoDriver();
    _tapDownPosition = details.localPosition;
  }

  void _onTapUp(TapUpDetails details) {
    final downPos = _tapDownPosition;
    if (downPos == null) return;
    _tapDownPosition = null;
    // 移动距离 < clickThresholdPx(10px) 视为点击，否则视为滚动
    final delta = (details.localPosition - downPos).distance;
    if (delta >= LyricLayout.clickThresholdPx) return;

    // 计算点击 y 对应的行索引：用预计算的 lineTops（支持非均匀行高）
    // 每行的实际 top = lineTops[i] + _interludeOffsetBefore(i)，
    // 找第一个 (lineTops[i+1] + interludeOffset) + posY > clickY 的 i（即 clickY 落在第 i 行内）
    final posY = _scrollController.posY;
    final relativeY = details.localPosition.dy - posY;
    if (_lineTops.isEmpty) return;
    int index = -1;
    for (int i = 0; i < _lineTops.length; i++) {
      final top =
          _lineTops[i] + _interludeOffsetBefore(i) + _transDeltaBefore(i);
      final height =
          (_lineHeights.length > i ? _lineHeights[i] : 0) +
          _transExtraHeightFor(i);
      if (relativeY >= top && relativeY < top + height) {
        index = i;
        break;
      }
    }
    if (index < 0 && _lineTops.isNotEmpty) {
      // 兆底：找最接近的行
      index = (_lineTops.length - 1).clamp(0, widget.lines.length - 1);
    }
    if (index >= 0 && index < widget.lines.length) {
      AppHaptics.tick();
      widget.onSeek?.call(widget.lines[index].startTime);
    }
  }

  /// 双击跳转：使用 onDoubleTapDown 已存储的 _tapDownPosition 触发跳转。
  void _triggerDoubleTapSeek() {
    final downPos = _tapDownPosition;
    if (downPos == null) return;
    _tapDownPosition = null;

    final posY = _scrollController.posY;
    final relativeY = downPos.dy - posY;
    if (_lineTops.isEmpty) return;
    int index = -1;
    for (int i = 0; i < _lineTops.length; i++) {
      final top =
          _lineTops[i] + _interludeOffsetBefore(i) + _transDeltaBefore(i);
      final height =
          (_lineHeights.length > i ? _lineHeights[i] : 0) +
          _transExtraHeightFor(i);
      if (relativeY >= top && relativeY < top + height) {
        index = i;
        break;
      }
    }
    if (index < 0 && _lineTops.isNotEmpty) {
      index = (_lineTops.length - 1).clamp(0, widget.lines.length - 1);
    }
    if (index >= 0 && index < widget.lines.length) {
      widget.onSeek?.call(widget.lines[index].startTime);
    }
  }

  /// 用户垂直拖动歌词：调用 scrollController.onUserScroll 偏移 posY 并重置 5s 回弹倒计时。
  ///
  /// 之前只挂了 onTapDown/onTapUp，导致用户无法上下滑动歌词（spec 要求
  /// 用户滚动后 5s 自动回弹到当前行）。这里补上 onVerticalDragUpdate/End。
  void _onVerticalDragUpdate(DragUpdateDetails details) {
    // 省电模式：用户开始滑动歌词立即解锁帧率限制（保持 120Hz 顺滑滚动）。
    // 必须立刻同步驱动源：取消 60fps Timer、确认 Ticker 在跑，
    // 否则要等下一帧 _onTick 里的 _syncEcoDriver 才切，拖动首帧会多走一次 60fps。
    _ecoUnlocked = true;
    _syncEcoDriver();
    _scrollController.onUserScroll(details.primaryDelta ?? 0);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    // 传递松手时的垂直速度给 scrollController，用于惯性滚动
    // velocity.pixelsPerSecond.dy 单位 px/s，向下为正
    _scrollController.onUserScrollEnd(
      velocity: details.velocity.pixelsPerSecond.dy,
    );
  }

  // ============== 构建 ==============

  @override
  Widget build(BuildContext context) {
    // 根据屏幕最短边判断设备类型：>= 600dp 视为 pad（平板），更新 overscan 缓冲行数
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    _overscan = shortestSide >= 600 ? 15 : 10;
    // 根据主题亮度设置歌词文字颜色：
    // - AM 风格（forceDarkBackground=true）→ 始终白色
    // - 深色主题 → 白色
    // - 浅色主题 → 黑色
    final isLightTheme = Theme.of(context).brightness == Brightness.light;
    LyricLayout.textColorValue = (widget.forceDarkBackground || !isLightTheme)
        ? 0xFFFFFFFF
        : 0xFF000000;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 设置视口大小，供 scrollController 计算 targetY
        _scrollController.setViewportSize(
          Size(constraints.maxWidth, constraints.maxHeight),
        );

        final fontSize = LyricLayout.fontSize(context);
        final mainLineHeight = fontSize * LyricLayout.lineHeight;
        // 可用最大文字宽度（视口宽 - 左右 1em 边距），用于自动换行
        final maxLineWidth = LyricLayout.maxLineWidth(
          constraints.maxWidth,
          fontSize,
        );

        // 绑定歌词行列表（仅在来源引用变化时重新绑定）
        _syncLinesIfNeeded();
        // 性能优化：缓存命中检查，只在数据/字号/视口变化时重算 lineHeights/lineTops
        // 之前每帧都跑 N 次 TextPainter.layout 是 CPU 瓶颈（UI 线程 70%+）
        _recomputeLineHeightsIfNeeded(fontSize, constraints.maxWidth);

        // 创建或复用持久化 painter
        // 性能优化：painter 字段在 _onTick 中通过 updatePerFrame + notifyListeners 更新，
        // 避免每帧 setState + build 重建 widget tree。
        // build() 只在 widget 重建时运行，设置布局相关字段。
        if (_painter == null) {
          _painter = _LyricsPainter(
            repaint: _repaintNotifier,
            lines: _lines,
            currentLineIndex: _currentLineIndex,
            posY: _scrollController.posY,
            fontSize: fontSize,
            mainLineHeight: mainLineHeight,
            lineHeights: _lineHeights,
            lineTops: _lineTops,
            viewportHeight: constraints.maxHeight,
            maxLineWidth: maxLineWidth,
            currentTimeMs: _authorityTimeMs,
            enableScale: widget.enableScale,
            wordRenderers: _wordRenderers,
            lineRenderers: _lineRenderers,
            interludeDots: _interludeDots,
            interludeAfterIndices: _interludeAfterIndices,
            interludePlaceholderHeight: _interludePlaceholderHeight,
            activeInterludeIdx: _activeInterludeIdx,
            lastActiveAnchorIdx: _lastActiveAnchorIdx,
            interludeExpandProgress: _interludeExpandProgress,
            transExpandProgress: _translationExpandProgress,
            auxSubHeights: _auxSubHeights,
            transCollapsing: _transCollapsing,
            textColorValue: LyricLayout.textColorValue,
            linesGeneration: _linesGeneration,
            lineHeightsGeneration: _lineHeightsGeneration,
            lineTopsGeneration: _lineTopsGeneration,
            interludeAfterIndicesGeneration: _interludeAfterIndicesGeneration,
          );
        } else {
          // 复用持久化 painter，更新所有字段（布局 + 动画）
          _painter!.lines = _lines;
          _painter!.currentLineIndex = _currentLineIndex;
          _painter!.posY = _scrollController.posY;
          _painter!.fontSize = fontSize;
          _painter!.mainLineHeight = mainLineHeight;
          _painter!.lineHeights = _lineHeights;
          _painter!.lineTops = _lineTops;
          _painter!.viewportHeight = constraints.maxHeight;
          _painter!.maxLineWidth = maxLineWidth;
          _painter!.currentTimeMs = _authorityTimeMs;
          _painter!.enableScale = widget.enableScale;
          _painter!.wordRenderers = _wordRenderers;
          _painter!.lineRenderers = _lineRenderers;
          _painter!.interludeDots = _interludeDots;
          _painter!.interludeAfterIndices = _interludeAfterIndices;
          _painter!.interludePlaceholderHeight = _interludePlaceholderHeight;
          _painter!.activeInterludeIdx = _activeInterludeIdx;
          _painter!.lastActiveAnchorIdx = _lastActiveAnchorIdx;
          _painter!.interludeExpandProgress = _interludeExpandProgress;
          // 逐行副行高度随行集/字号/宽度/displayMode 变化（重算中被替换为新列表），
          // 必须在此同步引用，否则换歌/切翻译后 painter 会读旧列表（长度不匹配）
          _painter!.auxSubHeights = _auxSubHeights;
          _painter!.textColorValue = LyricLayout.textColorValue;
          _painter!.linesGeneration = _linesGeneration;
          _painter!.lineHeightsGeneration = _lineHeightsGeneration;
          _painter!.lineTopsGeneration = _lineTopsGeneration;
          _painter!.interludeAfterIndicesGeneration =
              _interludeAfterIndicesGeneration;
        }

        final lyricsContent = ClipRect(
          child: CustomPaint(painter: _painter, size: Size.infinite),
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.doubleTapToJump ? null : _onTapDown,
          onTapUp: widget.doubleTapToJump ? null : _onTapUp,
          onDoubleTapDown: widget.doubleTapToJump ? _onTapDown : null,
          onDoubleTap: widget.doubleTapToJump ? _triggerDoubleTapSeek : null,
          onVerticalDragUpdate: _onVerticalDragUpdate,
          onVerticalDragEnd: _onVerticalDragEnd,
          child: ShaderMask(
            // 歌词界面上下边界 alpha 渐变（参数与评论区一致：24px 渐变高度），
            // 顶部 24px alpha 0→1，底部 24px alpha 1→0，
            // 让歌词从边界柔和淡入/淡出。
            // P2-H 方案 A：shader 按 bounds 尺寸缓存复用，避免每次 build 重建。
            shaderCallback: (Rect bounds) => _fadeShaderFor(bounds),
            blendMode: BlendMode.dstIn,
            child: lyricsContent,
          ),
        );
      },
    );
  }

}

/// 歌词绘制器。
///
/// 遍历所有 lines，跳过视口外（含 overscan=300px 上下缓冲）的行，
/// 按行调用对应 renderer 的 [WordRenderer.paintLine] / [LineRenderer.paintLine]。
///
/// 每行 scale 取稳态值：当前行 [LyricLayout.activeScale]、
/// 非当前行 [LyricLayout.inactiveScale]（可调）。
///
/// 间奏时段在视口中央绘制 [InterludeDots]。
///
/// **自动换行**：每行实际高度由 [lineHeights] 提供（非均匀），
/// 行顶部 y = lineTops[i] + posY（累加偏移）。renderer 的 paintLine 接收
/// [maxLineWidth] 参数实现 word 级换行。
class _LyricsPainter extends CustomPainter {
  List<LyricLine> lines;
  int currentLineIndex;
  double posY;
  double fontSize;
  double mainLineHeight;
  List<double> lineHeights;
  List<double> lineTops;
  double viewportHeight;
  double maxLineWidth;
  int currentTimeMs;
  bool enableScale;
  Map<int, WordRenderer> wordRenderers;
  Map<int, LineRenderer> lineRenderers;

  InterludeDots interludeDots;
  List<int> interludeAfterIndices;
  double interludePlaceholderHeight;
  int activeInterludeIdx;
  int lastActiveAnchorIdx;
  double interludeExpandProgress;

  /// 翻译副行动画：当前行展开进度（0→1）/ 逐行副行预留高度（含过长换行，
  /// 索引与 lines 对齐）/ 收起中的行
  /// （索引 → 收起进度，live 引用，State 侧原地更新）。
  double transExpandProgress;
  List<double> auxSubHeights;
  Map<int, double> transCollapsing;
  int textColorValue;
  int linesGeneration;
  int lineHeightsGeneration;
  int lineTopsGeneration;
  int interludeAfterIndicesGeneration;

  _LyricsPainter({
    super.repaint,
    required this.lines,
    required this.currentLineIndex,
    required this.posY,
    required this.fontSize,
    required this.mainLineHeight,
    required this.lineHeights,
    required this.lineTops,
    required this.viewportHeight,
    required this.maxLineWidth,
    required this.currentTimeMs,
    required this.enableScale,
    required this.wordRenderers,
    required this.lineRenderers,
    required this.interludeDots,
    required this.interludeAfterIndices,
    required this.interludePlaceholderHeight,
    required this.activeInterludeIdx,
    required this.lastActiveAnchorIdx,
    required this.interludeExpandProgress,
    required this.transExpandProgress,
    required this.auxSubHeights,
    required this.transCollapsing,
    required this.textColorValue,
    required this.linesGeneration,
    required this.lineHeightsGeneration,
    required this.lineTopsGeneration,
    required this.interludeAfterIndicesGeneration,
  });

  /// 更新每帧变化的动画字段（在 _onTick 中调用，避免 setState + build）。
  void updatePerFrame({
    required int currentLineIndex,
    required double posY,
    required int currentTimeMs,
    required double interludeExpandProgress,
    required int activeInterludeIdx,
    required int lastActiveAnchorIdx,
    required double transExpandProgress,
    required List<double> auxSubHeights,
    required Map<int, double> transCollapsing,
  }) {
    this.currentLineIndex = currentLineIndex;
    this.posY = posY;
    this.currentTimeMs = currentTimeMs;
    this.interludeExpandProgress = interludeExpandProgress;
    this.activeInterludeIdx = activeInterludeIdx;
    this.lastActiveAnchorIdx = lastActiveAnchorIdx;
    this.transExpandProgress = transExpandProgress;
    this.auxSubHeights = auxSubHeights;
    this.transCollapsing = transCollapsing;
  }

  /// 获取指定行 i 的实际高度（含换行 + 副行动画高度），降级到 mainLineHeight。
  double _heightOf(int i) =>
      (i < lineHeights.length ? lineHeights[i] : mainLineHeight) +
      _transExtra(i);

  /// 获取指定行 i 的顶部 y（累加偏移），降级到 i * mainLineHeight。
  /// 不包含间奏占位偏移与副行动画高度。
  double _topOf(int i) =>
      i < lineTops.length ? lineTops[i] : i * mainLineHeight;

  /// 指定行是否有副行文本（与 State._lineHasAuxText 同口径；
  /// lines 即 _lines）。
  bool _lineHasAuxText(int i) {
    if (i < 0 || i >= lines.length) return false;
    final line = lines[i];
    final String? aux =
        LyricPreferences.instance.displayMode == LyricDisplayMode.roma
        ? line.roma
        : line.translation;
    return aux != null && aux.isNotEmpty;
  }

  /// 第 i 行的副行预留高度（与 State._auxSubHeightOf 同口径，含换行行数）。
  double _auxSubHeightOf(int i) =>
      (i >= 0 && i < auxSubHeights.length) ? auxSubHeights[i] : 0;

  /// 第 i 行副行动画额外高度（与 State._transExtraHeightFor 同口径）：
  /// 当前行跟随展开进度增长，收起表中的行随收起进度回落，且各自使用
  /// **该行自身的**副行预留高度（含换行），换行副行不会与下一行重叠。
  /// 不读 showTranslation 短路（关闭翻译时进度衰减到 0，高度平滑收起）。
  double _transExtra(int i) {
    if (i == currentLineIndex && _lineHasAuxText(i)) {
      return _auxSubHeightOf(i) * transExpandProgress;
    }
    final double? c = transCollapsing[i];
    return c == null ? 0 : _auxSubHeightOf(i) * (1.0 - c);
  }

  /// 第 i 行上方副行动画高度之和（与 State._transDeltaBefore 同口径），
  /// 叠加到行 top 消费点（主绘制循环 / 二分查找 / 间奏锚点）。
  double _transDeltaBefore(int i) {
    double d = 0;
    if (currentLineIndex >= 0 &&
        currentLineIndex < i &&
        _lineHasAuxText(currentLineIndex)) {
      d += _auxSubHeightOf(currentLineIndex) * transExpandProgress;
    }
    transCollapsing.forEach((k, v) {
      if (k < i) d += _auxSubHeightOf(k) * (1.0 - v);
    });
    return d;
  }

  /// 计算指定行索引上方激活间奏的占位高度。
  ///
  /// **progress 驱动**：只要 `interludeExpandProgress > 0` 就返回占位高度，
  /// 不依赖 `activeInterludeIdx`。这样间奏结束后 progress 缓慢收起到 0 期间，
  /// 占位偏移也跟随平滑收起，posY target 不会突变。
  ///
  /// 使用 `lastActiveAnchorIdx` 记录最后激活的间奏 anchor，
  /// 避免影响其他未激活间奏的占位。
  ///
  /// 高度 = interludePlaceholderHeight * interludeExpandProgress
  double _interludeOffsetBefore(int lineIndex) {
    if (interludeExpandProgress <= 0) return 0;
    final int anchorIdx = lastActiveAnchorIdx;
    if (anchorIdx < 0 || anchorIdx >= lineIndex) return 0;
    return interludePlaceholderHeight * interludeExpandProgress;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 行水平起始位置：左留 1em 边距（对应 LyricLayout.linePadding 的 horizontal）
    final double startX = fontSize * 1.0;

    // === 性能优化：二分查找定位首行可见索引 ===
    // 之前从 i=0 遍历所有 lines（200+ 行），只靠 y 范围 continue/break 跳过。
    // 现在用二分查找快速定位第一个可能可见的行，跳过前方所有不可见行。
    // lineTops 是预排序的（递增），适合二分查找。
    int startI = 0;
    if (lineTops.isNotEmpty && lines.isNotEmpty) {
      int lo = 0, hi = lines.length;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        final double yMid = _topOf(mid) + _transDeltaBefore(mid) + posY;
        if (yMid + _heightOf(mid) < -LyricLayout.overscanPx) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      // 向前多看 2 行，处理间奏占位偏移导致的 y 变化
      startI = math.max(0, lo - 2);
    }

    for (int i = startI; i < lines.length; i++) {
      final line = lines[i];
      final double lineHeight = _heightOf(i);
      // 行顶部 y 坐标 = lineTops[i] + 该行上方间奏占位偏移 + 上方副行动画高度 + posY
      final double y =
          _topOf(i) +
          _transDeltaBefore(i) +
          _interludeOffsetBefore(i) +
          posY;

      // 跳过视口外（含 overscan=300px 上下缓冲）的行，避免不必要的绘制
      if (y + lineHeight < -LyricLayout.overscanPx) continue;
      if (y > viewportHeight + LyricLayout.overscanPx) break;

      final bool isActive = i == currentLineIndex;

      // 每行 scale 取稳态值（无弹簧）：当前行 activeScale、非当前行 inactiveScale。
      // 与 _onTick 步骤 4 传给 renderer 的 scale 口径保持一致。
      final double alphaScale = isActive
          ? LyricLayout.activeScale
          : (enableScale ? LyricLayout.inactiveScale : LyricLayout.activeScale);

      // 保存画布状态，应用 scale 变换。
      // pivotX 取左边缘：scale<1.0 时文本以左边缘为中心收缩，对齐不会偏移。
      canvas.save();
      const double pivotX = startX;
      final double pivotY = y + lineHeight / 2;
      canvas.translate(pivotX, pivotY);
      canvas.scale(alphaScale, alphaScale);
      canvas.translate(-pivotX, -pivotY);

      // 当前行 + 有 word 时间戳 → WordRenderer（逐字模式：N 次 layout/帧）
      // 否则 → LineRenderer（整行模式：1 次 layout/帧，含非当前行的 KRC 行）
      // 性能优化：非当前行不需要逐字渐变，用 LineRenderer 大幅减少 layout 次数
      final bool useWordRenderer = isActive && line.hasWordTiming;
      if (useWordRenderer) {
        // 逐字模式：当前行的 KRC 行
        final renderer = wordRenderers[i] ?? WordRenderer();
        renderer.setLineState(
          isActive: true,
          scale: alphaScale,
        );
        renderer.paintLine(
          canvas,
          Offset(startX, y),
          line,
          fontSize,
          maxWidth: maxLineWidth,
        );
      } else {
        // 整行模式：LRC/纯文本行 + 非当前行的 KRC 行
        final renderer = lineRenderers[i] ?? LineRenderer();
        renderer.setLineState(
          isActive: isActive,
          scale: alphaScale,
        );
        renderer.paintLine(
          canvas,
          Offset(startX, y),
          line,
          fontSize,
          maxWidth: maxLineWidth,
        );
      }

      canvas.restore();
    }

    // 绘制间奏点（若处于间奏时段或间奏结束后收起期间）。
    // 间奏点作为占位行嵌在歌词流里，位于激活间奏的 anchor 行之后。
    // 占位高度 = interludePlaceholderHeight * interludeExpandProgress（动态展开/收起）
    // centerY 居中在占位区域内（动态高度的一半）。
    // 点大小/间距跟随 fontSize 缩放：radius≈fontSize*0.18，spacing≈fontSize*0.9。
    //
    // **同步收起**：间奏结束后 progress 收起期间也绘制间奏点，
    // 让点消失动画与占位收起同步（都是 ~300-750ms）。
    // 占位完全收起（progress == 0）后不得再绘制：圆点属于占位行，
    // 零高度时绘制会残留在 anchor 行下方悬浮穿帮。
    if (interludeDots.shouldRender &&
        interludeExpandProgress > 0 &&
        lastActiveAnchorIdx >= 0 &&
        lastActiveAnchorIdx < lines.length) {
      final int anchorIdx = lastActiveAnchorIdx;
      final double anchorHeight = _heightOf(anchorIdx);
      final double anchorTop = _topOf(anchorIdx);
      // anchor 行底部 y（含 anchor 行上方的间奏偏移 + 副行动画高度）
      final double anchorBottomY =
          anchorTop +
          anchorHeight +
          _transDeltaBefore(anchorIdx) +
          _interludeOffsetBefore(anchorIdx) +
          posY;
      // 占位高度动态展开：0 → interludePlaceholderHeight
      final double placeholderH =
          interludePlaceholderHeight * interludeExpandProgress;
      // 间奏点 centerY 居中在占位区域内
      final double centerY = anchorBottomY + placeholderH / 2;
      // 点半径与间距跟随 fontSize 缩放（AMLL 风格：直径约 6-8px @ fontSize=24）
      final double dotRadius = fontSize * 0.18;
      final double dotSpacing = fontSize * 0.9;
      // 间奏点单独右移：startX * 1.5（比歌词左对齐右移 0.5em）
      // 让点整体居中偏右，视觉更平衡
      final double dotsStartX = fontSize * 1.5;
      interludeDots.paintAtLineY(
        canvas,
        dotsStartX,
        centerY,
        dotRadius: dotRadius,
        spacing: dotSpacing,
        colorValue: LyricLayout.textColorValue,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LyricsPainter oldDelegate) {
    // 持久化 painter：由 notifyListeners() 驱动重绘，shouldRepaint 返回 false。
    // 仅在 build() 创建新 painter 时（首次构建或 widget 重建）才会调用此方法。
    return false;
  }
}

/// ChangeNotifier 子类，暴露 public fireRepaint() 方法。
/// 用于驱动持久化 _LyricsPainter 的重绘，替代 setState + build。
class _RepaintNotifier extends ChangeNotifier {
  void fireRepaint() {
    notifyListeners();
  }
}
