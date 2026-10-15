import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/player/apple_music_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// AppleMusicLyricsView 跟随态交互测试（渐变焦点层 / 选中行高亮 / 常驻播放胶囊）。
///
/// 状态机：
/// - 跟随中：ShaderMask 渐变焦点层生效，当前行右侧常驻播放胶囊，无选中行高亮；
/// - 手动滚动中（拖动/惯性）：焦点层立即移除，胶囊跟随基准线对齐行移动；
/// - 手动停止：选中行（基准线对齐行）品牌红高亮，胶囊定格在该行；
/// - 点胶囊：seek 到该行 startTime 并恢复跟随（焦点层回归）；
/// - 3 秒无操作：恢复跟随。
///
/// 回归锁定（历史 bug）：跟随态焦点层在「ShaderMask 包裹 / 裸列表」两种树形间
/// 切换时，列表子树经 GlobalKey 原地转移——手动滚动后滚动偏移必须保持
/// （此前会重置为 0：歌词跳回顶部、滚动中途卡住），且滚动过程不得触发 seek。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  LyricLine lineAt(int i) => LyricLine(
        startTime: i * 5000,
        duration: 5000,
        text: 'Lyric line number $i for the follow interaction test',
      );

  Future<void> pumpView(
    WidgetTester tester,
    ValueNotifier<Duration> position, {
    ValueChanged<Duration>? onSeek,
    List<bool>? followLog,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: AppleMusicLyricsView(
              lyricLines: List.generate(20, lineAt),
              positionListenable: position,
              onSeek: onSeek ?? (_) {},
              isPlaying: false, // 不启动 Ticker，定位完全由上报驱动
              onFollowChanged: followLog == null
                  ? null
                  : (following) => followLog.add(following),
            ),
          ),
        ),
      ),
    );
  }

  /// 焦点层判定：包裹 ListView 的 ShaderMask（自动跟随渐变淡出）是否存在。
  /// 当前行扫色 ShaderMask 是 ListView 的后代，不会混入该判定。
  bool hasFocusFade(WidgetTester tester) => find
      .ancestor(of: find.byType(ListView), matching: find.byType(ShaderMask))
      .evaluate()
      .isNotEmpty;

  /// 歌词列表当前滚动偏移（根因回归断言用：手动滚动后不得重置为 0）。
  double scrollOffset(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!.offset;

  /// 选中行高亮行数：AnimatedDefaultTextStyle 目标文字色为 colorScheme.primary
  /// （品牌红）的行。跟随态/拖动中应为 0，手动停止态应恰为 1。
  int highlightedLineCount(WidgetTester tester) {
    final primary = Theme.of(
      tester.element(find.byType(AppleMusicLyricsView)),
    ).colorScheme.primary;
    return tester
        .widgetList<AnimatedDefaultTextStyle>(find.byType(AnimatedDefaultTextStyle))
        .where((w) => w.style.color == primary)
        .length;
  }

  testWidgets('挂载后一帧内上报初始跟随态；跟随中挂焦点层、当前行右侧常驻胶囊',
      (tester) async {
    final followLog = <bool>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position, followLog: followLog);
    await tester.pumpAndSettle();

    expect(followLog, [true], reason: '初始跟随态应在首帧后上报一次');
    expect(hasFocusFade(tester), isTrue, reason: '跟随中应有渐变焦点层');
    expect(find.byKey(AppleMusicLyricsView.capsulePlayKey), findsOneWidget,
        reason: '跟随中当前行右侧应常驻播放胶囊');
    expect(highlightedLineCount(tester), 0,
        reason: '跟随态无选中行高亮（当前行自有 32px 扫色强调）');
  });

  testWidgets('手动拖动立即移除焦点层；滚动停止后选中行高亮、胶囊定格',
      (tester) async {
    final followLog = <bool>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position, followLog: followLog);
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(followLog.last, false, reason: '拖动起手即上报非跟随');
    expect(hasFocusFade(tester), isFalse, reason: '手动滚动中应立即去模糊');
    expect(find.byKey(AppleMusicLyricsView.capsulePlayKey), findsOneWidget,
        reason: '滚动停止后胶囊应定格在选中行');
    expect(highlightedLineCount(tester), 1,
        reason: '滚动停止后选中行（基准线对齐行）应高亮');
    expect(scrollOffset(tester), greaterThan(250),
        reason: '根因回归：手动滚动后偏移必须保持，不得重置为 0');
  });

  testWidgets('点击胶囊播放按钮：seek 到该行并恢复自动跟随', (tester) async {
    final followLog = <bool>[];
    final seeks = <Duration>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(
      tester,
      position,
      onSeek: seeks.add,
      followLog: followLog,
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.byKey(AppleMusicLyricsView.capsulePlayKey), findsOneWidget);

    await tester.tap(find.byKey(AppleMusicLyricsView.capsulePlayKey));
    await tester.pumpAndSettle();

    expect(seeks, isNotEmpty, reason: '点胶囊应触发 seek');
    expect(seeks.first.inMilliseconds % 5000, 0,
        reason: 'seek 目标应为某行 startTime（5000ms 网格）');
    expect(followLog.last, true, reason: '点胶囊应恢复自动跟随');
    expect(hasFocusFade(tester), isTrue, reason: '恢复跟随后焦点层回归');
    expect(find.byKey(AppleMusicLyricsView.capsulePlayKey), findsOneWidget,
        reason: '胶囊常驻：恢复跟随后改挂当前行');
    expect(highlightedLineCount(tester), 0,
        reason: '恢复跟随后无选中行高亮');
  });

  testWidgets('手动滚动停止 3 秒无操作后恢复自动跟随', (tester) async {
    final followLog = <bool>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position, followLog: followLog);
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(followLog.last, false);

    // 推进假时钟越过 3 秒恢复延迟，再让 animateTo 收敛
    await tester.pump(const Duration(seconds: 3, milliseconds: 100));
    await tester.pumpAndSettle();

    expect(followLog.last, true, reason: '3 秒无操作应恢复跟随');
    expect(hasFocusFade(tester), isTrue, reason: '恢复跟随后焦点层回归');
    expect(find.byKey(AppleMusicLyricsView.capsulePlayKey), findsOneWidget,
        reason: '胶囊常驻：恢复跟随后改挂当前行');
    expect(highlightedLineCount(tester), 0,
        reason: '恢复跟随后无选中行高亮');
    // 恢复跟随应把列表滚回当前行（第 0 行）锚点：初始偏移 10（视口 1/3 处）。
    // 此前焦点层树形切换会在 animateTo 途中重挂列表、丢掉动画，
    // 恢复后列表停在错误位置。
    expect(scrollOffset(tester), closeTo(10, 1),
        reason: '恢复跟随后列表应滚回当前行锚点');
  });

  testWidgets('手动滚动不改变播放进度：拖动与 fling 均不 seek、偏移保持',
      (tester) async {
    final seeks = <Duration>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position, onSeek: seeks.add);
    await tester.pumpAndSettle();

    // 大位移拖动：纯浏览，不得触发 seek、不得丢偏移
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(seeks, isEmpty, reason: '手动拖动不得触发 seek（进度重置根因）');
    expect(scrollOffset(tester), greaterThan(250),
        reason: '拖动后偏移应保持（此前焦点层树形切换会重置为 0）');

    // 反向 fling：同样只浏览
    await tester.fling(find.byType(ListView), const Offset(0, 200), 1000);
    await tester.pumpAndSettle();
    expect(seeks, isEmpty, reason: '手动 fling 不得触发 seek');
  });

  testWidgets('慢速分步拖动跨越焦点层切换（250ms）不重置偏移、不中断滚动',
      (tester) async {
    final seeks = <Duration>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position, onSeek: seeks.add);
    await tester.pumpAndSettle();

    // 每步 50px、间隔 100ms，共 6 步（300px / 500ms）——跨越 250ms 淡出
    // 动画的树形切换点，验证列表子树被原地转移而非卸载重挂。
    // 注：拖动增量到下一帧才应用到 offset（手势竞技场首帧只分出胜负），
    // 因此断言「单调不回退」而非每步严格增长。
    final center = tester.getCenter(find.byType(ListView));
    final gesture = await tester.startGesture(center);
    var previousOffset = scrollOffset(tester);
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, -50));
      await tester.pump(const Duration(milliseconds: 100));
      expect(seeks, isEmpty, reason: '慢速滚动过程中不得触发 seek');
      final offset = scrollOffset(tester);
      expect(offset, greaterThanOrEqualTo(previousOffset),
          reason: '偏移不得回退/重置（第 $i 步，此前焦点层树形切换会清零）');
      previousOffset = offset;
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(seeks, isEmpty, reason: '慢速滚动全程不得触发 seek');
    expect(scrollOffset(tester), greaterThan(250),
        reason: '慢速滚动累计 300px 后偏移应保持');
  });

  testWidgets('从播放胶囊上起手的滚动正常滚动（胶囊不吞拖拽、不误触 seek）',
      (tester) async {
    final seeks = <Duration>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position, onSeek: seeks.add);
    await tester.pumpAndSettle();

    final capsule = find.byKey(AppleMusicLyricsView.capsulePlayKey);
    expect(capsule, findsOneWidget, reason: '跟随态当前行右侧应常驻胶囊');
    final before = scrollOffset(tester);
    await tester.drag(capsule, const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(seeks, isEmpty, reason: '从胶囊上起手的拖动是滚动，不得 seek');
    expect(scrollOffset(tester), greaterThan(before + 150),
        reason: '从胶囊上起手的拖动应正常滚动歌词列表');
  });

  testWidgets('点行 seek 到该行并恢复自动跟随', (tester) async {
    final followLog = <bool>[];
    final seeks = <Duration>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(
      tester,
      position,
      onSeek: seeks.add,
      followLog: followLog,
    );
    await tester.pumpAndSettle();

    // 初始定位第 0 行为当前行；点第 3 行（同屏可见的非当前行）
    await tester.tap(find.textContaining('number 3 '));
    await tester.pumpAndSettle();

    expect(seeks, [const Duration(milliseconds: 15000)],
        reason: '点行应 seek 到该行 startTime');
    expect(followLog.last, true, reason: '点行应恢复自动跟随');
  });
}
