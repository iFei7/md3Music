import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/player/apple_music_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';

/// AppleMusicLyricsView 跟随态交互测试（渐变焦点层 / 基准线 + 胶囊播放）。
///
/// 状态机：
/// - 跟随中：ShaderMask 渐变焦点层生效，无基准线/胶囊；
/// - 手动滚动中（拖动/惯性）：焦点层立即移除；
/// - 手动停止：基准线 + 胶囊播放按钮出现；
/// - 点胶囊：seek 到对齐行 startTime 并恢复跟随（焦点层回归、胶囊消失）；
/// - 3 秒无操作：恢复跟随。
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

  testWidgets('挂载后一帧内上报初始跟随态；跟随中挂焦点层、无基准线胶囊',
      (tester) async {
    final followLog = <bool>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position, followLog: followLog);
    await tester.pumpAndSettle();

    expect(followLog, [true], reason: '初始跟随态应在首帧后上报一次');
    expect(hasFocusFade(tester), isTrue, reason: '跟随中应有渐变焦点层');
    expect(find.byKey(AppleMusicLyricsView.capsulePlayKey), findsNothing,
        reason: '跟随中不应显示胶囊播放按钮');
  });

  testWidgets('手动拖动立即移除焦点层；滚动停止后出现基准线与胶囊',
      (tester) async {
    final followLog = <bool>[];
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await pumpView(tester, position, followLog: followLog);
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(followLog.last, false, reason: '拖动起手即上报非跟随');
    expect(hasFocusFade(tester), isFalse, reason: '手动滚动中应立即去模糊');
    expect(find.byKey(AppleMusicLyricsView.capsulePlayKey), findsOneWidget,
        reason: '滚动停止后应显示胶囊播放按钮');
  });

  testWidgets('点击胶囊播放按钮：seek 到对齐行并恢复自动跟随', (tester) async {
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
    expect(find.byKey(AppleMusicLyricsView.capsulePlayKey), findsNothing,
        reason: '恢复跟随后胶囊隐藏');
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
    expect(find.byKey(AppleMusicLyricsView.capsulePlayKey), findsNothing,
        reason: '恢复跟随后胶囊隐藏');
  });
}
