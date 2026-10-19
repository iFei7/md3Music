import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/modules/settings/settings_page.dart';

/// 「电池优化白名单」行（BatteryOptimizationTile）测试：
/// 对接 native 通道 com.md3music.md3music/battery。
/// - 初始查询 isIgnoringBatteryOptimizations = false → 副标题「未豁免…」；
/// - 点击 → invoke requestIgnoreBatteryOptimizations 并刷新状态；
/// - 查询返回 true → 副标题「已豁免…」；null / 异常按「未豁免」处理。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.md3music.md3music/battery');

  late List<MethodCall> calls;
  late bool ignoring;

  setUp(() {
    calls = <MethodCall>[];
    ignoring = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'isIgnoringBatteryOptimizations':
              return ignoring;
            case 'requestIgnoreBatteryOptimizations':
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpTile(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: const [BatteryOptimizationTile()],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('初始未豁免：副标题提示后台播放可能被系统终止', (tester) async {
    ignoring = false;
    await pumpTile(tester);

    expect(find.text('电池优化白名单'), findsOneWidget);
    expect(find.text('未豁免，后台播放可能被系统终止'), findsOneWidget);
    // initState 主动查询一次真实状态
    expect(
      calls.where((c) => c.method == 'isIgnoringBatteryOptimizations').length,
      1,
    );
  });

  testWidgets('初始已豁免：副标题提示后台播放不会被系统清理', (tester) async {
    ignoring = true;
    await pumpTile(tester);

    expect(find.text('已豁免，后台播放不会被系统清理'), findsOneWidget);
    expect(find.text('未豁免，后台播放可能被系统终止'), findsNothing);
  });

  testWidgets('点击 → 拉起系统豁免对话框并刷新为已豁免', (tester) async {
    ignoring = false;
    await pumpTile(tester);

    // 模拟用户在系统对话框里点了允许（切回时真实状态已变）
    ignoring = true;
    await tester.tap(find.byType(BatteryOptimizationTile));
    await tester.pumpAndSettle();

    expect(
      calls.any((c) => c.method == 'requestIgnoreBatteryOptimizations'),
      isTrue,
    );
    // 拉起后重新查询 → 副标题切换为已豁免
    expect(
      calls.where((c) => c.method == 'isIgnoringBatteryOptimizations').length,
      2,
    );
    expect(find.text('已豁免，后台播放不会被系统清理'), findsOneWidget);
  });

  testWidgets('通道返回 null / 抛异常 → 一律按未豁免处理', (tester) async {
    // 查询返回 null；拉起抛异常 → 兜底 SnackBar，副标题保持未豁免
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'isIgnoringBatteryOptimizations':
              return null;
            case 'requestIgnoreBatteryOptimizations':
              throw PlatformException(code: 'native_error');
            default:
              return null;
          }
        });
    await pumpTile(tester);

    expect(find.text('未豁免，后台播放可能被系统终止'), findsOneWidget);

    await tester.tap(find.byType(BatteryOptimizationTile));
    await tester.pumpAndSettle();

    expect(
      calls.any((c) => c.method == 'requestIgnoreBatteryOptimizations'),
      isTrue,
    );
    // 未谎报已豁免；拉起失败给出兜底提示
    expect(find.text('未豁免，后台播放可能被系统终止'), findsOneWidget);
    expect(find.text('无法打开系统豁免设置，请在系统设置中手动允许后台运行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
