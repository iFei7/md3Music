import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/player/apple_music_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// AppleMusicLyricsView 滚动锚定行为测试。
///
/// 回归背景：`_ensureLayout` 曾按「当前行样式」（32 / w900）测量所有行高，
/// 而非当前行实际按「非当前行样式」（26 / w700）渲染 → 每行系统性高估
/// 32×1.3 − 26×1.3 ≈ 7.8px（长行在 32px 下多换行时更多），行 j 的滚动偏移
/// = 行 0..j-1 高度和，误差随行号线性累积，数十行累计数百 px，当前行被
/// 推出视窗。修复后测量样式与非当前态逐字段一致。
void main() {
  // 每行足够长：在 800px 宽表面（内容宽 752px）下 26px 字号需换行多行，
  // 使逐行测量误差可观（修复前每行至少 +7.8px，30 行累计远超一个视口）。
  // 注：测试环境默认字体（FlutterTest）每字形 1em 宽，行高比真机大得多，
  // 因此使用 800×2000 的大视口，保证当前行（32px 态）完整落在视口内。
  LyricLine lineAt(int i) => LyricLine(
        startTime: i * 5000,
        duration: 5000,
        text: 'Lyric line number $i with plenty of English words to force '
            'the text into wrapping across multiple rendered lines '
            'inside the Apple Music lyrics view for this regression test',
      );

  Future<void> pumpView(WidgetTester tester, ValueNotifier<Duration> position) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 2000,
            child: AppleMusicLyricsView(
              lyricLines: List.generate(40, lineAt),
              positionListenable: position,
              onSeek: (_) {},
              isPlaying: false, // 不启动 Ticker，定位完全由上报驱动
            ),
          ),
        ),
      ),
    );
  }

  void useLargeSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('播放至第 30 行时当前行仍锚定在视口上部 1/3（行高测量与渲染样式一致性）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    useLargeSurface(tester);

    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position);
    await tester.pumpAndSettle();

    // 跳到第 30 行（index 30）中段，触发自动跟随滚动
    position.value = Duration(milliseconds: 30 * 5000 + 2500);
    await tester.pumpAndSettle();

    final viewportRect = tester.getRect(find.byType(ListView));
    final currentLineRect = tester.getRect(find.textContaining('number 30 '));

    // 当前行顶边不得高于视口顶（修复前误差随行号线性累积，会把当前行
    // 漂移出视窗）
    expect(currentLineRect.top, greaterThanOrEqualTo(viewportRect.top - 1),
        reason: '当前行顶边不得高于视口顶');

    // 锚定精度：当前行 top 应接近视口上部 1/3（2000 × 1/3 ≈ 667px）。
    // 修复前第 30 行累计误差数百 px，远超该容差。
    final anchorTop = viewportRect.top + viewportRect.height / 3;
    expect(currentLineRect.top, closeTo(anchorTop, 60),
        reason: '当前行应锚定在视口上部 1/3 附近（top=${currentLineRect.top}, '
            '期望≈$anchorTop）');

    // 当前行（32px 态）完整落在视口内（大视口下必然成立）
    expect(currentLineRect.bottom, lessThanOrEqualTo(viewportRect.bottom + 1),
        reason: '当前行底边不得低于视口底');
  });

  testWidgets('非当前行渲染样式与行高测量样式逐字段一致（26 / w700 / wght700 / 1.3）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    useLargeSurface(tester);

    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position);
    await tester.pumpAndSettle();

    // 初始态：第 0 行为当前行，第 1 行为非当前行（同屏可见）。
    // 字段级断言：非当前行的 AnimatedDefaultTextStyle 目标样式必须为
    // 26 / w700 / wght700 / height 1.3 —— 与 `_ensureLayout` 的测量样式
    // 逐字段一致（本测试与实现的契约；若改动任一侧需同步另一侧）。
    final animatedStyle = tester
        .widget<AnimatedDefaultTextStyle>(
          find
              .ancestor(
                of: find.textContaining('number 1 '),
                matching: find.byType(AnimatedDefaultTextStyle),
              )
              .first,
        )
        .style;
    expect(animatedStyle.fontSize, 26.0);
    expect(animatedStyle.fontWeight, FontWeight.w700);
    expect(animatedStyle.height, 1.3);
    final wght =
        animatedStyle.fontVariations!.firstWhere((v) => v.axis == 'wght');
    expect(wght.value, 700.0);

    // 相邻行 top 差 = 第 0 行实际渲染总高，应显著大于非当前态单行文本高
    //（测试字体下第 0 行为当前态且多行换行，必然远大于 33.8）
    final line0Rect = tester.getRect(find.textContaining('number 0 '));
    final line1Rect = tester.getRect(find.textContaining('number 1 '));
    expect(line1Rect.top - line0Rect.top, greaterThan(26 * 1.3),
        reason: '行 0 → 行 1 的 top 间距应大于单行文本高');
  });
}
