/// 逐字 mask alpha 渲染器（核心渲染组件）
///
/// 参照 spec.md "Requirement: 逐字 mask alpha 渲染" 实现。
/// 文字本身固定白色，靠 mask alpha 区分已播 / 未播字：
/// - 当前行（GRADIENT 模式）：已播字 alpha = dynamicBrightAlpha，未播字 alpha = dynamicDarkAlpha，
///   当前字按指数衰减在两者之间过渡，左亮右暗。
/// - 非当前行（SOLID 模式）：整行均匀 alpha = dynamicDarkAlpha。
///
/// 本类不是 Widget，是核心绘制逻辑类，由外部 CustomPainter 调用 [paintLine]。
/// 动画驱动由外部 AnimationController + Ticker 调用 [tick] 实现（SubTask 7.7）。
library;

import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';

import '../layout/lyric_layout.dart';
import '../layout/lyric_preferences.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// 逐字 mask alpha 渲染器。
///
/// 持有当前 scale、isActive、currentLineProgress 与每个 word 的当前 alpha 值，
/// 通过 [tick] 推进指数衰减动画，通过 [paintLine] 用对应 alpha 逐字绘制白色文本。
class WordRenderer {
  WordRenderer();

  // ============== 内部状态 ==============

  /// 当前是否为当前行（GRADIENT 模式）。默认 false（SOLID）。
  bool _isActive = false;

  /// 当前行缩放，0.850（inactive）~1.0（active）。默认 inactive。
  double _scale = LyricLayout.inactiveScale;

  /// 当前绑定的 LyricLine。用于检测 line 切换并重置 alpha map。
  LyricLine? _boundLine;

  /// 缓存的字号（用于检测 fontSize 变化时重新测量 word 宽度）。
  double _boundFontSize = -1;

  /// 缓存的字重（用于检测 fontWeight 变化时重新测量 word 宽度）。
  int _boundFontWeight = -1;

  /// 缓存的行高系数（用于检测行间距变化时重新绑定）。
  ///
  /// 行盒高度与字形在盒内的垂直位置都由 `TextStyle.height`（= lineHeight）决定，
  /// 不进绑定键则调行间距后 painter 仍按旧行高绘制，表现为不刷新。
  double _boundLineHeight = -1;

  /// 每个 word 的缓存宽度（在 [_ensureBound] 时一次性测量）。
  ///
  /// **性能优化**：之前每帧 paintLine 都为每个 word 创建 TextPainter + layout
  /// 来测量宽度（用于换行判断）。现在只在 line 切换或 fontSize 变化时测量一次。
  /// 10 word/行 × 60fps = 每秒 600 次 layout → 缓存后降为 0 次/帧。
  List<double> _wordWidths = const <double>[];

  /// v4 优化：per-word TextPainter 实例列表。
  ///
  /// **背景**：v3 Task 1 用单实例 _painter + _lastSetAlphas 缓存导致"当前行重复显示同一字"bug
  /// （commit b56b7e9 已回滚）。根因：单实例 _painter 在循环中被多个 word 共用，下一个 word 的
  /// set text 会覆盖 painter.text，导致 _lastSetAlphas[i] 比较时基于"上次循环的最后一个 word"
  /// 状态而非该 word 自身上次状态。
  /// **v4 解决方案**：每个 word 独占一个 TextPainter 实例，alpha 不变时跳过 set text + layout 是安全的。
  /// 10 word/行 × 60fps = 每秒 600 次 layout → 缓存后降到 ~100-200 次/秒
  /// （仅当前字 + 边界附近 word 在过渡）。
  List<TextPainter?> _wordPainters = const <TextPainter?>[];

  /// v4 优化：每个 word index 上次设置的 alpha（量化步进值）。
  /// 仅在量化值变化时才 set text + layout，避免每帧 N 次 layout。
  List<int> _lastSetAlphas = const <int>[];

  /// 每个 word index 的当前 alpha 值。
  List<double> _wordAlphas = const <double>[];

  /// v3 优化：renderer 是否已收敛（alpha 和 Y offset 都不再变化）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool _isConverged = true;

  /// 每个 word index 的当前 Y 轴偏移（上浮特效）。
  ///
  /// AMLL 规范：当前字会轻微上浮（最大约 -3px），用指数衰减平滑过渡。
  /// 已播字回到 0，未播字保持 0，当前字上浮。
  List<double> _wordYOffsets = const <double>[];

  /// 已播字上浮幅度（px，向上为负）。
  ///
  /// 由用户在设置页"歌词动画 → 已播字上浮高度"调节
  /// （[LyricPreferences.liftHeightPx]，默认 3.0）。0 = 完全不上浮。
  ///
  /// 每帧在 [tick] 内读取一次并缓存到局部变量，避免在 per-word 循环里重复
  /// 访问单例；偏好变化会在下一帧自然生效，无需重置绑定缓存。
  static double get _maxLiftPx => -LyricPreferences.instance.liftHeightPx;

  /// AMLL 上浮 ATTACK 速度：当前字上浮指数衰减系数。
  static const double _liftAttackSpeed = 30.0;

  /// AMLL 上浮 RELEASE 速度：当前字回落指数衰减系数。
  static const double _liftReleaseSpeed = 10.0;

  /// 上次 set text 时的文字颜色值。
  /// 主题切换时 textColorValue 变化，需清空 _lastSetAlphas 强制重建所有 word TextSpan。
  int _lastTextColorValue = -1;

  /// 翻译副行专用 TextPainter（复用避免每帧创建，仅 active 行使用）。
  final TextPainter _translationPainter = TextPainter(
    textDirection: TextDirection.ltr,
  );

  /// 渐变路径复用的 Paint 实例（避免每帧新建，减少 GC）。
  /// 渐变路径稳态下每帧只改 shader，0 次 layout。
  final Paint _gradientPaint = Paint();

  // ============== 渐变遮罩状态 ==============

  /// 当前正在演唱的 word 索引（-1 表示还未开始）。
  int _currentWordIdx = -1;

  /// 当前 word 内进度（0.0-1.0）。
  double _intraWordProgress = 0.0;

  /// 行级渐变 mask 位置（相对于行首的累计已播宽度）。
  ///
  /// **行级渐变模型**：mask 边界随演唱进度从行首移动到行尾，
  /// 跨越多个 word。长字上停留久（速度慢），短字上快速掠过，
  /// 自然实现"根据字长不同改变移动速度"。
  /// -1 表示无效（非当前行），double.infinity 表示已播完。
  double _maskX = -1.0;

  /// 过渡区半宽（固定值，行内字宽的平均）。
  ///
  /// 渐变过渡区宽度 = 2 × 半宽。**必须固定、不随当前字变化**：
  /// - 若直接用当前字宽，字切换瞬间半宽突变 → 过渡区尺寸瞬变，边缘字 alpha 断崖（闪）。
  /// - 若对半宽做平滑逼近，字切换瞬间过渡区短暂取上一字宽（偏大），下一个字整个处于
  ///   过渡区（偏亮"亮一下"），随后过渡区收缩（右边缘转暗"暗下来"），再随演唱变亮——
  ///   呈现"亮-暗-亮"的闪烁。
  /// 固定为行内平均字宽：字切换时过渡区尺寸恒定，消除上述两种闪烁。
  double _transitionHalfWidth = 0;

  /// 预计算的每个 word 在行内的起始 X 坐标（相对于行首）。
  /// 在 [_ensureBound] 时一次性计算，避免每帧 O(n²) 循环累加。
  List<double> _wordStartXs = const <double>[];

  // ============== 状态查询 ==============

  /// 当前 alpha map（不可变视图，供测试断言）。
  ///
  /// 内部用 List 存储（性能优化），此处通过 [List.asMap] 返回 Map 视图，
  /// 保持测试接口兼容。仅测试调用，非热路径。
  @visibleForTesting
  Map<int, double> get wordAlphas => _wordAlphas.asMap();

  /// 当前逐字 alpha 的平均值。
  ///
  /// 行退场（当前行 → 非当前行）时作为清晰层淡出的起点：该期间渲染器实例
  /// 从 [WordRenderer] 换成 [LineRenderer]，若不把本值交接过去，新实例的
  /// alpha 停留在 0，明亮歌词会硬切成模糊图。
  double get averageWordAlpha {
    if (_wordAlphas.isEmpty) return dynamicDarkAlpha;
    double sum = 0;
    for (final a in _wordAlphas) {
      sum += a;
    }
    return sum / _wordAlphas.length;
  }

  /// 当前行级渐变 mask 位置（供测试断言字切换时的连续性）。
  @visibleForTesting
  double get maskX => _maskX;

  /// 当前演唱字索引（供测试断言）。
  @visibleForTesting
  int get currentWordIdx => _currentWordIdx;

  /// 过渡区半宽固定值（供测试断言字切换时的稳定性）。
  @visibleForTesting
  double get transitionHalfWidth => _transitionHalfWidth;

  /// 每个 word 的行内起始 X（供测试断言过渡区计算）。
  @visibleForTesting
  List<double> get wordStartXsRef => _wordStartXs;

  /// 每个 word 的宽度（供测试断言过渡区计算）。
  @visibleForTesting
  List<double> get wordWidthsRef => _wordWidths;

  /// 每个 word 的当前 Y 偏移（上浮量，向上为负，供测试断言）。
  @visibleForTesting
  List<double> get wordYOffsetsRef => _wordYOffsets;

  /// 转发 [alphaAtX] 供测试断言绘制 alpha 的连续性。
  @visibleForTesting
  double debugAlphaAtX(
    double x,
    double start,
    double span,
    double bright,
    double dark,
  ) => _alphaAtX(x, start, span, bright, dark);

  /// 当前 scale 对应的 factor（0~1）。
  ///
  /// 公式：`factor = clamp01((scale - inactiveScale) / (activeScale - inactiveScale))`
  double get factor {
    final raw =
        (_scale - LyricLayout.inactiveScale) /
        (LyricLayout.activeScale - LyricLayout.inactiveScale);
    return raw.clamp(0.0, 1.0).toDouble();
  }

  /// 动态暗态 alpha（未播字 / 非当前行 SOLID）。
  ///
  /// 公式：`dynamicDarkAlpha = factor * 0.2 + 0.2`，范围 0.2~0.4。
  double get dynamicDarkAlpha => factor * 0.2 + 0.2;

  /// 动态亮态 alpha（已播字 / 当前字目标）。
  ///
  /// 公式：`dynamicBrightAlpha = factor * 0.8 + 0.2`，范围 0.2~1.0。
  double get dynamicBrightAlpha => factor * 0.8 + 0.2;

  /// 当前是否为当前行。
  bool get isActive => _isActive;

  /// v3 优化：renderer 是否已收敛（alpha 和 Y offset 都不再变化）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool get isConverged => _isConverged;

  // ============== 状态设置 ==============

  /// 设置当前行状态。
  ///
  /// [isActive] 为 true 时启用 GRADIENT 模式（已播亮 / 未播暗），
  /// 为 false 时启用 SOLID 模式（整行均匀暗）。
  /// [scale] 是行缩放，0.850（inactive）~1.0（active）。
  void setLineState({
    required bool isActive,
    required double scale,
  }) {
    _isActive = isActive;
    _scale = scale;
  }

  /// 翻译副行展开进度（0→1 副行"长出"）。由 AppleLyricsView 注入（当前行）。
  ///
  /// 仅当前行预留副行高度，本进度控制当前行副行的视觉浮出：
  /// progress=0 时副行贴主行底（隐藏位），progress=1 时到正常副行位置。
  double translationExpand = 0.0;

  /// 翻译副行显隐 alpha 进度（0→1 渐显，1→0 渐隐）。由 AppleLyricsView 注入。
  ///
  /// 当前实现与 [translationExpand] 同值注入（alpha 与位置同进度，
  /// 淡入淡出贯穿整个过渡时长，速率随行时长自适应）。
  double translationFade = 0.0;

  /// 副行是否处于**出场**阶段。由 AppleLyricsView 注入（与 LineRenderer 同义）。
  ///
  /// - false（当前行 / 入场）：绕副行底边，从下翻转出现；
  /// - true（收起中的退场行 / 出场）：绕副行顶边，向上翻转消失。
  ///
  /// WordRenderer 只负责当前行，生产路径恒为 false；字段保留是为了与
  /// LineRenderer 共用 [LyricLayout] 的翻转几何、跨渲染器切换时行为一致。
  bool translationExiting = false;

  // ============== 动画推进 ==============

  /// 推进动画。
  ///
  /// [dt] 距上一帧的时间间隔（秒）。[currentTimeMs] 当前播放位置（毫秒），
  /// 用于根据每个 word 的 [LyricWord.startTime] / [LyricWord.duration]
  /// 精确判断当前正在演唱的 word 及 word 内进度。
  /// 用指数衰减公式 `alpha += (target - alpha) * (1 - exp(-speed * dt))`
  /// 平滑过渡：变亮用 [LyricLayout.attackSpeed]（50.0），变暗用 [LyricLayout.releaseSpeed]（7.0）。
  /// 差值小于 [LyricLayout.alphaEpsilon]（0.001）时吸附到目标。
  ///
  /// **性能优化（上浮动画功耗优化）**：
  /// - 预计算 decay：dt 对所有 word 相同，speed 只有 attack/release 两值，
  ///   每帧只调 4 次 exp() 而非最多 2N 次（N=word 数）
  /// - 非激活行快速路径：跳过 currentWordIdx 计算、smoothstep、per-word target 分支，
  ///   所有 word 统一 target=dark / Y=0
  /// - early-exit 已收敛字：90% 的字已收敛，跳过乘法运算
  void tick(double dt, int currentTimeMs) {
    if (dt <= 0) return;
    if (_boundLine == null || _boundLine!.words.isEmpty) return;

    final double dark = dynamicDarkAlpha;
    final double bright = dynamicBrightAlpha;
    final words = _boundLine!.words;
    final int wordCount = words.length;

    // === 预计算 decay 值（核心优化：每帧只调 4 次 exp()）===
    // 之前每 word 最多调 2 次 exp()（alpha + Y offset），10 word 行 = 20 次/帧
    // 现在固定 4 次/帧，与 word 数无关
    final double alphaAttackDecay = 1.0 - exp(-LyricLayout.attackSpeed * dt);
    final double alphaReleaseDecay = 1.0 - exp(-LyricLayout.releaseSpeed * dt);
    final double liftAttackDecay = 1.0 - exp(-_liftAttackSpeed * dt);
    final double liftReleaseDecay = 1.0 - exp(-_liftReleaseSpeed * dt);

    // 已播字上浮幅度：每帧读一次偏好（见 [_maxLiftPx] 的说明）
    final double maxLiftPx = _maxLiftPx;

    // === 非当前行快速路径 ===
    // 非当前行：所有 word alpha 目标 = dark，Y offset 目标 = 0，emphasis = idle
    // 跳过 currentWordIdx 查找、smoothstep、per-word target 分支判断
    if (!_isActive) {
      bool anyChanged = false;
      for (int i = 0; i < wordCount; i++) {
        // Alpha → dark（使用方向判断选 decay，兼容 dark 值随 scale 变化的情况）
        final double current = _wordAlphas[i];
        if ((current - dark).abs() >= LyricLayout.alphaEpsilon) {
          final double decay = dark >= current
              ? alphaAttackDecay
              : alphaReleaseDecay;
          double next = current + (dark - current) * decay;
          if ((next - dark).abs() < LyricLayout.alphaEpsilon) next = dark;
          _wordAlphas[i] = next;
          anyChanged = true;
        }
        // Y offset → 0（非当前行不上浮）
        final double currentY = _wordYOffsets[i];
        if (currentY.abs() >= 0.01) {
          final double yDecay = 0 >= currentY
              ? liftAttackDecay
              : liftReleaseDecay;
          double nextY = currentY + (0 - currentY) * yDecay;
          if (nextY.abs() < 0.01) nextY = 0;
          _wordYOffsets[i] = nextY;
          anyChanged = true;
        }
      }
      _isConverged = !anyChanged;
      _currentWordIdx = -1;
      _intraWordProgress = 0.0;
      _maskX = -1.0;
      return;
    }

    // === 当前行：完整 per-word 处理 ===
    // 找到当前正在演唱的 word 索引及 word 内进度
    int currentWordIdx = -1;
    double intraWordProgress = 0.0;

    for (int i = 0; i < wordCount; i++) {
      final w = words[i];
      if (currentTimeMs >= w.startTime &&
          currentTimeMs < w.startTime + w.duration) {
        currentWordIdx = i;
        intraWordProgress = w.duration > 0
            ? ((currentTimeMs - w.startTime) / w.duration).clamp(0.0, 1.0)
            : 0.0;
        break;
      } else if (currentTimeMs >= w.startTime + w.duration &&
          (i == wordCount - 1 || currentTimeMs < words[i + 1].startTime)) {
        // 当前 word 已结束，下一个 word 还没开始 → 保持当前 word 为"已播"
        currentWordIdx = i;
        intraWordProgress = 1.0;
      }
    }

    // 如果 currentTimeMs 在所有 word 之前，第一个 word 为当前
    if (currentWordIdx == -1 &&
        wordCount > 0 &&
        currentTimeMs < words[0].startTime) {
      currentWordIdx = 0;
      intraWordProgress = 0.0;
    }

    // 记录当前演唱状态，供 paintLine 中行级渐变使用
    _currentWordIdx = currentWordIdx;
    _intraWordProgress = intraWordProgress;

    // === 计算行级 mask 位置（核心：行级渐变模型）===
    // maskX = 已播字总宽度 + 当前字内进度 × 当前字宽
    // 渐变边界随演唱进度从行首移动到行尾，跨越多个 word。
    // 长字上停留久（速度慢），短字上快速掠过。
    //
    // 注意：_wordStartXs 是累计宽度，字切换时 wordStartXs[i+1] == wordEndXs[i]，
    // 故 maskX 天然连续，无需额外平滑。
    if (currentWordIdx < 0) {
      _maskX = -1.0; // 无效，全 dark
    } else if (currentWordIdx >= wordCount) {
      _maskX = double.infinity; // 已播完，全 bright
    } else {
      _maskX =
          _wordStartXs[currentWordIdx] +
          _wordWidths[currentWordIdx] * _intraWordProgress;
    }

    bool anyChanged = false;
    // 性能优化：内联 target 计算 + early-exit 已收敛字 + 预计算 decay
    // 90% 的字在任意时刻已收敛到目标值，跳过乘法运算可大幅降低 CPU 开销
    for (int i = 0; i < wordCount; i++) {
      // === Alpha 动画 ===
      final double target;
      if (i < currentWordIdx) {
        target = bright;
      } else if (i > currentWordIdx) {
        target = dark;
      } else {
        target = dark + (bright - dark) * intraWordProgress;
      }

      final double current = _wordAlphas[i];
      if ((current - target).abs() < LyricLayout.alphaEpsilon) {
        // 已收敛：直接吸附到目标，跳过乘法
        if (current != target) _wordAlphas[i] = target;
      } else {
        // 使用预计算的 decay，避免每 word 调 exp()
        final double decay = target >= current
            ? alphaAttackDecay
            : alphaReleaseDecay;
        double next = current + (target - current) * decay;
        if ((next - target).abs() < LyricLayout.alphaEpsilon) {
          next = target;
        }
        _wordAlphas[i] = next;
        anyChanged = true;
      }

      // === Y 偏移动画（上浮特效）===
      final double targetY;
      if (i < currentWordIdx) {
        targetY = maxLiftPx;
      } else if (i == currentWordIdx) {
        // smoothstep 缓动（仅 3 次乘法 + 1 次加法，开销极低）
        final double eased =
            intraWordProgress * intraWordProgress * (3 - 2 * intraWordProgress);
        targetY = maxLiftPx * eased;
      } else {
        targetY = 0;
      }

      final double currentY = _wordYOffsets[i];
      // Y offset 用 0.01px epsilon（3px 范围，0.3% 不可见）
      if ((currentY - targetY).abs() < 0.01) {
        // 已收敛：直接吸附到目标，跳过乘法
        if (currentY != targetY) _wordYOffsets[i] = targetY;
      } else {
        // 使用预计算的 decay，避免每 word 调 exp()
        final double yDecay = targetY >= currentY
            ? liftAttackDecay
            : liftReleaseDecay;
        double nextY = currentY + (targetY - currentY) * yDecay;
        if ((nextY - targetY).abs() < 0.01) {
          nextY = targetY;
        }
        _wordYOffsets[i] = nextY;
        anyChanged = true;
      }

    }
    // v3 优化：跟踪 alpha/Y offset 是否仍在变化（用于 AppleLyricsView 判断停止 Ticker）
    _isConverged = !anyChanged;
  }

  // ============== 绘制 ==============

  /// 绘制单行歌词。
  ///
  /// [offset] 是行起始绘制原点。文字颜色固定白色 #FFFFFFFF，
  /// 通过逐字 alpha 区分已播 / 未播。
  ///
  /// [maxWidth] 为该行可用最大文字宽度（视口宽 - 左右 1em 边距）。
  /// 当 word 累加 dx 超过 [maxWidth] 且 dx > 0 时换行：
  /// dx 归零，currentY += mainLineHeight × wrapLineHeightFactor（0.8x 行高）。
  ///
  /// **性能优化**：
  /// - word 宽度用 [_wordWidths] 缓存（[_ensureBound] 时一次性测量），
  ///   换行判断不再每帧创建 TextPainter + layout
  /// - **v4 优化**：per-word TextPainter 实例 + alpha 缓存。
  ///   仅在 alpha 变化时才 set text + layout，alpha 不变时直接 paint。
  ///   这与 v3 Task 1 共享 painter 不同：每个 word 独占一个 TextPainter 实例，
  ///   不会出现"下一个 word 覆盖 painter.text 导致 _lastSetAlphas[i] 错乱"的 bug。
  void paintLine(
    Canvas canvas,
    Offset offset,
    LyricLine line,
    double fontSize, {
    double maxWidth = double.infinity,
  }) {
    // 临时调试：行切换时打印换行分析（定位歌词重叠）
    final bool isNewLine =
        !identical(_boundLine, line) || _boundFontSize != fontSize;
    _ensureBound(line, fontSize);
    if (isNewLine) {
      _debugLogWrap(line, fontSize, maxWidth);
    }

    // 颜色变化时清空 alpha 缓存强制重建所有 word TextSpan。
    final int textColorValue = LyricLayout.textColorValue;
    if (textColorValue != _lastTextColorValue) {
      // 哨兵 -2 = 未初始化：与渐变路径的白色缓存（-1）和 uniform 的
      // alphaStep（0~20）都不同，保证首次绘制必定重新 set text + layout。
      _lastSetAlphas = List<int>.filled(_lastSetAlphas.length, -2);
      _lastTextColorValue = textColorValue;
    }
    final int textRed = (textColorValue >> 16) & 0xFF;
    final int textGreen = (textColorValue >> 8) & 0xFF;
    final int textBlue = textColorValue & 0xFF;

    if (line.words.isEmpty) {
      _paintSolidFallback(
        canvas,
        offset,
        line,
        fontSize,
        maxWidth: maxWidth,
      );
      return;
    }

    int visualLineIndex = 0;
    final double baseX = offset.dx;

    double dx = 0; // 相对 baseX 的水平偏移
    double currentY = offset.dy; // 当前视觉行的 y 坐标
    final double dark = dynamicDarkAlpha;
    final double bright = dynamicBrightAlpha;
    // 主行行高 = 主行高（完整行盒）；换行行盒模型与 measureLineHeight 一致：
    // 主行完整行高，换行行 0.8x 行高、从主行底开始，行盒=行距避免相邻行重叠。
    final double mainLineHeight = fontSize * LyricLayout.lineHeight;
    // 换行内部行高 = 主行高 × 0.8（与 LyricLayout.measureLineHeight 一致）
    final double wrapLineHeight =
        mainLineHeight * LyricLayout.wrapLineHeightFactor;
    final double lineHeight = LyricLayout.lineHeight;

    // === 行级渐变参数（核心：行级 maskX 模型）===
    // 过渡区以 _maskX 为中心，宽度 = 2 × 当前字宽，让渐变跨越 2-3 个 word。
    // 长字过渡区宽，渐变在字上移动慢；短字过渡区窄，移动快。
    // _maskX < 0 表示非当前行或未开始，全 dark。
    final bool useGradient =
        _isActive &&
        _boundLine != null &&
        _boundLine!.words.length == line.words.length &&
        _maskX >= 0;
    final double transitionHalfWidth =
        useGradient &&
            _currentWordIdx >= 0 &&
            _currentWordIdx < _wordWidths.length
        ? _transitionHalfWidth
        : 0.0;
    final double transitionStart = _maskX - transitionHalfWidth;
    final double transitionEnd = _maskX + transitionHalfWidth;
    final double transitionSpan = transitionEnd - transitionStart;

    for (int i = 0; i < line.words.length; i++) {
      final LyricWord word = line.words[i];
      // AMLL 上浮特效：当前字 Y 偏移（上浮）
      final double yOffset = i < _wordYOffsets.length ? _wordYOffsets[i] : 0;
      // 用缓存宽度做换行判断（避免每帧 TextPainter.layout 测量）
      final double width = i < _wordWidths.length ? _wordWidths[i] : 0;
      // 自动换行：累计宽度超过 maxWidth 且本视觉行已有 word 时换行
      if (dx + width > maxWidth && dx > 0) {
        dx = 0;
        // 第一个换行行从主行底部（offset.dy + mainLineHeight）开始，
        // 后续换行行之间 0.8x 行高（与 measureLineHeight 一致，避免行盒重叠）
        currentY = visualLineIndex == 0
            ? offset.dy + mainLineHeight
            : currentY + wrapLineHeight;
        visualLineIndex++;
      }

      // 换行行用 0.8x 行盒（行盒=行距，避免行盒重叠）；主行用完整行高
      final double rowHeight = visualLineIndex > 0
          ? LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor
          : LyricLayout.lineHeight;

      final double wordX = baseX + dx;
      final double wordY = currentY + yOffset;

      // === 整词渲染 ===
      // 行级 maskX 模型：基于 word 在行内的累计 X 坐标计算边缘 alpha。
      // 已播区（maskX 左侧远端）= bright，未播区（maskX 右侧远端）= dark，
      // 过渡区内线性插值，实现跨字平滑渐变。
      final double leftAlpha;
      final double rightAlpha;
      if (!useGradient) {
        leftAlpha = rightAlpha = i < _wordAlphas.length
            ? _wordAlphas[i]
            : dark;
      } else {
        final double wordStartX = i < _wordStartXs.length
            ? _wordStartXs[i]
            : 0;
        final double wordEndX = wordStartX + width;
        leftAlpha = _alphaAtX(
          wordStartX,
          transitionStart,
          transitionSpan,
          bright,
          dark,
        );
        rightAlpha = _alphaAtX(
          wordEndX,
          transitionStart,
          transitionSpan,
          bright,
          dark,
        );
      }

      final TextPainter painter = _wordPainters[i]!;

      // === 渲染文字 ===
      // 性能优化（核心）：左右 alpha 几乎一致时用均匀绘制（量化缓存，跳过 layout）。
      // 过渡区内的 word 走渐变路径，用 saveLayer + BlendMode.modulate 应用渐变。
      //
      // **layout 复用原理**：
      // - 渐变路径保持 painter.text 为 plain white（color=white, alpha=1.0）
      // - TextSpan.== 比较时 plain white 的 color/fontSize/fontFamily 不变 → 不触发 relayout
      // - 渐变通过 saveLayer + drawRect(modulate) 事后应用，不影响 layout
      // - 稳态下 0 次 layout/帧（仅路径切换时 1 次 layout）
      //
      // **BlendMode.modulate 公式**：result = src × dst（逐分量含 alpha）
      // - dst = 白色文字（color=white, alpha=文字形状）
      // - src = 渐变（color=white, alpha=leftAlpha→rightAlpha）
      // - result.color = white × white = white
      // - result.alpha = 渐变alpha × 文字形状 ✓
      final bool isUniform = (leftAlpha - rightAlpha).abs() < 0.01;
      if (isUniform) {
        // === 均匀路径 ===
        final double uniformAlpha = (leftAlpha + rightAlpha) * 0.5;
        final int alphaStep = (uniformAlpha * 20).round();
        if (_lastSetAlphas[i] != alphaStep) {
          // 量化值变化或从渐变路径切换过来：重新 set text + layout
          painter.text = TextSpan(
            text: word.text,
            style: TextStyle(
              color: Color.fromRGBO(
                textRed,
                textGreen,
                textBlue,
                uniformAlpha,
              ),
              fontSize: fontSize,
              height: rowHeight,
              fontFamily: LyricLayout.fontFamily,
              fontWeight: LyricLayout.fontWeight,
            ),
          );
          painter.layout();
          _lastSetAlphas[i] = alphaStep;
        }
        painter.paint(canvas, Offset(wordX, wordY));
      } else {
        // === 渐变路径（saveLayer + modulate，复用 layout）===
        // 确保 painter 处于 plain white 状态（只在切换时 set text + layout）
        if (_lastSetAlphas[i] != -1) {
          painter.text = TextSpan(
            text: word.text,
            style: TextStyle(
              color: const Color.fromRGBO(255, 255, 255, 1.0), // plain white
              fontSize: fontSize,
              height: rowHeight,
              fontFamily: LyricLayout.fontFamily,
              fontWeight: LyricLayout.fontWeight,
            ),
          );
          painter.layout();
          _lastSetAlphas[i] = -1; // 标记 plain white 已缓存
        }
        final Rect wordRect = Rect.fromLTWH(
          wordX,
          wordY,
          width,
          fontSize * rowHeight,
        );
        canvas.saveLayer(wordRect, Paint());
        painter.paint(
          canvas,
          Offset(wordX, wordY),
        ); // dst = 白色文字（layout 已缓存，不重算）
        // 复用 _gradientPaint 实例，只改 shader 和 blendMode。
        // 注意：不要对渐变 alpha 做量化缓存（曾引入 5% 可见阶跃闪烁 + 频繁清空重建反而卡顿）。
        _gradientPaint.shader = LinearGradient(
          colors: [
            Color.fromRGBO(textRed, textGreen, textBlue, leftAlpha),
            Color.fromRGBO(textRed, textGreen, textBlue, rightAlpha),
          ],
          stops: const <double>[0.0, 1.0],
        ).createShader(wordRect);
        _gradientPaint.blendMode = BlendMode.modulate;
        canvas.drawRect(wordRect, _gradientPaint); // src = 渐变
        canvas.restore();
      }

      dx += width;
    }

    // 辅助副行（翻译或罗马音）：WordRenderer 仅在当前行（KRC）被调用，故无需再判 _isActive。
    // 根据 displayMode 选择显示 translation 还是 roma。
    // 副行字号为主行 70%；alpha = translationOpacity × translationFade（渐显渐隐），
    // 位置随 translationExpand 从主行底平滑浮出（占位高度由动画进度动态叠加）。
    // **不读 showTranslation 做立即短路**：关闭翻译时注入进度衰减到 0、
    // alpha 平滑渐隐至消失——若在此短路，关闭瞬间副行直接消失无动画。
    final auxText =
        LyricPreferences.instance.displayMode == LyricDisplayMode.roma
        ? line.roma
        : line.translation;
    final double transAlpha = LyricLayout.translationOpacity * translationFade;
    if (transAlpha > 0.001 && auxText != null && auxText.isNotEmpty) {
      final transFontSize = LyricLayout.translationFontSize(fontSize);
      // currentY 是循环结束后的最后视觉行 Y。
      // 副行 Y = 最后视觉行底部 + 0.3em 间隙：单行用完整行高，
      // 多行时最后一行是换行行（0.8x 行高），与 measureLineHeight 压缩模型一致，
      // 避免翻译副行向下偏移与下一行歌词重叠。
      final double lastRowHeight = visualLineIndex > 0
          ? fontSize * LyricLayout.lineHeight * LyricLayout.wrapLineHeightFactor
          : fontSize * LyricLayout.lineHeight;
      // 副行"长出"偏移：translationExpand=0 时贴主行底（隐藏位），=1 时到正常位。
      // 先布局副行文本，再按**实际视觉行数**取副行高度：副行过长换行时高度随行数
      // 增长，与 AppleLyricsView 的逐行副行预留（LyricLayout.auxSubHeight）严格同式，
      // 否则预留槽位与副行终点错位（多出来的行压到下一行歌词上）。
      _translationPainter.text = TextSpan(
        text: auxText,
        style: TextStyle(
          color: Color.fromRGBO(textRed, textGreen, textBlue, transAlpha),
          fontSize: transFontSize,
          height: LyricLayout.translationLineHeight,
          fontFamily: LyricLayout.fontFamily,
          fontWeight: LyricLayout.fontWeight,
        ),
      );
      _translationPainter.layout(
        maxWidth: maxWidth == double.infinity ? double.infinity : maxWidth,
      );
      final int subRows = max(
        1,
        _translationPainter.computeLineMetrics().length,
      );
      final double subH = LyricLayout.auxSubHeight(fontSize, subRows);
      final double transY =
          currentY +
          lastRowHeight +
          transFontSize * 0.3 +
          subH * (translationExpand - 1.0);
      // 翻译副行与主行同左对齐
      final double transX = offset.dx;
      _paintTranslation(canvas, Offset(transX, transY));
    }
  }

  /// 绘制翻译副行（含日历式翻转）。
  ///
  /// [at] 为副行文本的绘制原点（左上角）。入场绕副行底边从下翻出、出场绕副行
  /// 顶边向上翻走（见 [LyricLayout.sublineFlipAngle]）。角度为 0 时不施加任何
  /// 画布变换，与改造前逐像素一致。
  void _paintTranslation(Canvas canvas, Offset at) {
    final double angle = LyricLayout.sublineFlipAngle(
      translationExpand,
      exiting: translationExiting,
    );
    if (angle == 0) {
      _translationPainter.paint(canvas, at);
      return;
    }
    // 锚点同时给出 x（= 副行水平中点，透视投影中心）与 y（旋转锚线）：
    // 只平移 y 会让透视除法绕画布左上角进行，翻转时副行整体左漂。
    final Offset anchor = LyricLayout.sublineFlipAnchor(
      transX: at.dx,
      sublineWidth: _translationPainter.width,
      transY: at.dy,
      sublineHeight: _translationPainter.height,
      exiting: translationExiting,
    );
    canvas.save();
    canvas.transform(
      LyricLayout.sublineFlipMatrix(angle: angle, anchor: anchor).storage,
    );
    _translationPainter.paint(canvas, at);
    canvas.restore();
  }

  /// 计算指定 X 坐标处的 alpha 值（行级渐变模型核心）。
  ///
  /// 过渡区 [transitionStart, transitionStart + transitionSpan]：
  /// - x <= transitionStart：bright（已播区）
  /// - x >= transitionStart + transitionSpan：dark（未播区）
  /// - 过渡区内：bright → dark 线性插值
  ///
  /// 通过此函数计算每个 word 左右边缘的 alpha，决定均匀绘制还是渐变 shader。
  /// 渐变边界随 maskX 移动跨越多个 word，自然实现"长字慢、短字快"。
  static double _alphaAtX(
    double x,
    double transitionStart,
    double transitionSpan,
    double bright,
    double dark,
  ) {
    if (transitionSpan <= 0) return x <= transitionStart ? bright : dark;
    if (x <= transitionStart) return bright;
    final double t = (x - transitionStart) / transitionSpan;
    if (t >= 1.0) return dark;
    return bright + (dark - bright) * t;
  }

  /// 整行降级绘制（无 word 时间戳时使用）。
  ///
  /// [maxWidth] 用于自动换行（默认 [double.infinity] 不换行）。
  /// 用临时 TextPainter 实例（仅在 fallback 路径，频率低不缓存）。
  void _paintSolidFallback(
    Canvas canvas,
    Offset offset,
    LyricLine line,
    double fontSize, {
    double maxWidth = double.infinity,
  }) {
    if (line.text.isEmpty) return;
    final double alpha = dynamicDarkAlpha;
    final int colorValue = LyricLayout.textColorValue;
    final painter = TextPainter(textDirection: TextDirection.ltr);
    painter.text = TextSpan(
      text: line.text,
      style: TextStyle(
        color: Color.fromRGBO(
          (colorValue >> 16) & 0xFF,
          (colorValue >> 8) & 0xFF,
          colorValue & 0xFF,
          alpha,
        ),
        fontSize: fontSize,
        height: LyricLayout.lineHeight,
        // 显式注入歌词 fontFamily，与 paintLine 路径保持一致
        fontFamily: LyricLayout.fontFamily,
        fontWeight: LyricLayout.fontWeight,
      ),
    );
    painter.layout(
      maxWidth: maxWidth == double.infinity ? double.infinity : maxWidth,
    );
    painter.paint(canvas, Offset(offset.dx, offset.dy));
    painter.dispose();
  }

  /// 临时调试：打印行换行分析（word 累加 vs TextPainter 行数），定位歌词重叠。
  void _debugLogWrap(LyricLine line, double fontSize, double maxWidth) {
    final StringBuffer sb = StringBuffer();
    sb.write(
      '[LyricWrap] WR hasWord=${line.hasWordTiming} '
      'text="${line.text}" maxW=${maxWidth.toStringAsFixed(1)} fs=$fontSize',
    );
    if (line.hasWordTiming) {
      // word 累加行数（与 paintLine / measureLineHeight 一致）
      double dx = 0;
      int rows = 1;
      for (int i = 0; i < _wordWidths.length; i++) {
        if (dx + _wordWidths[i] > maxWidth && dx > 0) {
          dx = 0;
          rows++;
        }
        dx += _wordWidths[i];
      }
      sb.write(' wordRows=$rows');
      // TextPainter 整行自动换行行数
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: line.text,
          style: TextStyle(
            fontSize: fontSize,
            height: LyricLayout.lineHeight,
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      sb.write(' tpRows=${tp.computeLineMetrics().length}');
      tp.dispose();
      sb.write(' words[');
      for (int i = 0; i < line.words.length; i++) {
        sb.write(
          '"${line.words[i].text}"(${_wordWidths[i].toStringAsFixed(1)}) ',
        );
      }
      sb.write(']');
    }
    // ignore: avoid_print
    if (kDebugMode) print(sb.toString());
  }

  /// 检测 line 切换并重置 alpha map，同时测量并缓存所有 word 宽度。
  ///
  /// 若传入的 line 与当前绑定不是同一对象引用（[identical] 失败），
  /// 或 fontSize 变化，重新初始化每个 word 的 alpha 为 [dynamicDarkAlpha]，
  /// 并测量每个 word 的宽度缓存到 [_wordWidths]。
  ///
  /// **v4 性能优化**：
  /// - 用 per-word TextPainter 实例列表替代共享 _painter
  /// - word 宽度只在此时测量一次，paintLine 用缓存宽度做换行判断
  /// - _lastSetAlphas 在 line 切换时清空，强制下次 paintLine 重新 set text + layout
  void _ensureBound(LyricLine line, double fontSize) {
    final sameLine = identical(_boundLine, line);
    final sameFontSize = _boundFontSize == fontSize;
    final sameFontWeight =
        _boundFontWeight == LyricPreferences.instance.fontWeightValue;
    final sameLineHeight = _boundLineHeight == LyricLayout.lineHeight;
    if (sameLine &&
        sameFontSize &&
        sameFontWeight &&
        sameLineHeight &&
        _wordPainters.length == line.words.length) {
      return; // 缓存命中
    }
    _boundLine = line;
    _boundFontSize = fontSize;
    _boundFontWeight = LyricPreferences.instance.fontWeightValue;
    _boundLineHeight = LyricLayout.lineHeight;
    // 注意：_wordAlphas/_wordYOffsets/_lastSetAlphas 不能用 .clear()，
    // 因为它们可能被 const <T>[] 初始化（不可修改）。后面会直接重新赋值，无需 clear。

    // 释放旧 per-word painter 与 per-char painter（line 缩短时避免泄漏）
    for (final painter in _wordPainters) {
      painter?.dispose();
    }

    final double dark = dynamicDarkAlpha;
    // 测量所有 word 宽度并初始化 per-word / per-char TextPainter
    _wordWidths = List<double>.filled(line.words.length, 0);
    _wordPainters = List<TextPainter?>.filled(line.words.length, null);
    // 预计算 word 起始 X 坐标（避免每帧 O(n²) 循环累加）
    _wordStartXs = List<double>.filled(line.words.length, 0);
    // 预分配 alpha / Y offset / lastSetAlphas 数组
    _wordAlphas = List<double>.filled(line.words.length, dark);
    _wordYOffsets = List<double>.filled(line.words.length, 0);
    _lastSetAlphas = List<int>.filled(line.words.length, -2);
    double accumWidth = 0;
    for (int i = 0; i < line.words.length; i++) {
      _wordPainters[i] = TextPainter(textDirection: TextDirection.ltr)
        ..text = TextSpan(
          text: line.words[i].text,
          style: TextStyle(
            fontSize: fontSize,
            height: LyricLayout.lineHeight,
            // 显式注入歌词 fontFamily，必须与 paintLine 渲染路径一致，
            // 否则 word 宽度测量会出错导致换行错位
            fontFamily: LyricLayout.fontFamily,
            fontWeight: LyricLayout.fontWeight,
          ),
        )
        ..layout();
      _wordWidths[i] = _wordPainters[i]!.width;
      _wordStartXs[i] = accumWidth;
      accumWidth += _wordWidths[i];
    }
    // 过渡区半宽固定为行内平均字宽（稳定，不随当前字变化，避免字切换闪烁）
    if (_wordWidths.isEmpty) {
      _transitionHalfWidth = 0;
    } else {
      double sum = 0;
      for (final w in _wordWidths) {
        sum += w;
      }
      _transitionHalfWidth = sum / _wordWidths.length;
    }
  }

  /// 重置状态：清空 alpha map、Y 偏移、归零 progress、scale 回到 inactive、isActive=false、解绑 line。
  ///
  /// **v4 优化**：dispose 所有 per-word TextPainter 实例避免内存泄漏。
  void reset() {
    _isActive = false;
    _scale = LyricLayout.inactiveScale;
    _boundLine = null;
    _boundFontSize = -1;
    _boundFontWeight = -1;
    _boundLineHeight = -1;
    _wordWidths = const <double>[];
    _wordStartXs = const <double>[];
    _currentWordIdx = -1;
    _intraWordProgress = 0.0;
    _maskX = -1.0;
    _transitionHalfWidth = 0;
    // v4 优化：dispose per-word TextPainter 实例
    for (final painter in _wordPainters) {
      painter?.dispose();
    }
    _wordPainters = const <TextPainter?>[];
    _wordAlphas = const <double>[];
    _wordYOffsets = const <double>[];
    _lastSetAlphas = const <int>[];
  }

  /// 最终释放渲染器；与可复用的 [reset] 不同，此后不再绘制。
  void dispose() {
    reset();
    _translationPainter.dispose();
  }
}
