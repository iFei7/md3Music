import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/bootstrap_common.dart' show appNavigatorKey;
import 'package:md3music/modules/update/update_prompt.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('updateBadgeVisible（批次58d：检查更新入口红点判定）', () {
    test('无待处理身份（空串）不显示红点', () {
      expect(
        updateBadgeVisible(pendingIdentity: '', currentVersion: '5.6.0'),
        isFalse,
      );
    });

    test('正式通道：待处理版本 ≠ 当前版本时显示红点', () {
      expect(
        updateBadgeVisible(pendingIdentity: '5.6.5', currentVersion: '5.6.0'),
        isTrue,
      );
    });

    test('用户已更新到该版本（待处理身份 = 当前版本）不显示红点', () {
      expect(
        updateBadgeVisible(pendingIdentity: '5.6.5', currentVersion: '5.6.5'),
        isFalse,
      );
    });

    test('Beta 快照 tag 含当前 versionName 时视为已处理（不显示红点）', () {
      expect(
        updateBadgeVisible(
          pendingIdentity: 'v5.9.27-lite-abc1234',
          currentVersion: '5.9.27',
        ),
        isFalse,
      );
    });

    test('Beta 快照 tag 与当前 versionName 不同代时显示红点', () {
      expect(
        updateBadgeVisible(
          pendingIdentity: 'v5.9.27-lite-abc1234',
          currentVersion: '5.9.20',
        ),
        isTrue,
      );
    });

    test('当前版本未知（空串）时宁可提示（显示红点）', () {
      expect(
        updateBadgeVisible(pendingIdentity: '5.6.5', currentVersion: ''),
        isTrue,
      );
    });
  });

  group('showUpdateAvailablePrompt（批次58d：启动发现新版本弹窗）', () {
    testWidgets('弹窗含标题、远端与当前版本文案，「下次再说」仅关闭', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );

      final dialogFuture = showUpdateAvailablePrompt(
        remoteVersion: 'v5.6.5',
        currentVersion: '5.6.0',
      );
      await tester.pumpAndSettle();

      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.textContaining('v5.6.5'), findsWidgets);
      expect(find.textContaining('5.6.0'), findsWidgets);
      expect(find.text('立即更新'), findsOneWidget);
      expect(find.text('下次再说'), findsOneWidget);

      await tester.tap(find.text('下次再说'));
      await dialogFuture;
      await tester.pumpAndSettle();

      expect(find.text('发现新版本'), findsNothing);
    });

    testWidgets('「立即更新」关闭弹窗并跳转 /settings', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigatorKey,
          routes: {
            '/settings': (_) => const Scaffold(body: Text('设置页占位')),
          },
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );

      final dialogFuture = showUpdateAvailablePrompt(
        remoteVersion: 'v5.6.5',
        currentVersion: '5.6.0',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('立即更新'));
      await dialogFuture;
      await tester.pumpAndSettle();

      expect(find.text('发现新版本'), findsNothing);
      expect(find.text('设置页占位'), findsOneWidget);
    });

    testWidgets('navigator 不可用时静默跳过（不抛异常、无弹窗）', (tester) async {
      // 不把 appNavigatorKey 挂到任何 MaterialApp 上，currentState 为 null
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      await showUpdateAvailablePrompt(
        remoteVersion: 'v5.6.5',
        currentVersion: '5.6.0',
      );
      await tester.pumpAndSettle();

      expect(find.text('发现新版本'), findsNothing);
    });
  });
}
