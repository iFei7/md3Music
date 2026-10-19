import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/user/sign_in_calendar_page.dart';
import 'package:md3music/modules/user/sign_in_mini_card.dart';
import 'package:md3music/providers/kugou_provider.dart';

import 'fake_kugou_provider.dart';

/// 设置页签到迷你日历卡（SignInMiniCard）测试：
/// - 未登录态显示「登录后签到」按钮（可点，进登录页）；
/// - 登录未签 → 「签到」调 manualSignIn 并 SnackBar 反馈；
/// - 登录已签 → 「今日已签到」可点，进签到日历页；
/// - 签到中 → 「签到中」禁用；
/// - 点击卡体 → 跳转 SignInCalendarPage；
/// - 本月已签天数 = 服务端记录（svip）+ 本地兜底合并；
/// - provider 的 hasSignedToday 与概念版徽章语义解耦。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // SignInCalendarPage 用 DateFormat('yyyy 年 M 月', 'zh_CN') 渲染月份，
  // 与 App 启动时 main.dart 的 initializeDateFormatting('zh_CN') 同口径；
  // 测试环境不会自动加载 locale 数据，须显式初始化。
  setUpAll(() async {
    await initializeDateFormatting('zh_CN');
  });

  /// 当天日期键（与 KugouProvider._markSignedToday 同格式）。
  String dayKey(int day) {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = day.toString().padLeft(2, '0');
    return '${now.year}-$m-$d';
  }

  /// 今日日期键（yyyy-MM-dd）。
  String todayKey() => dayKey(DateTime.now().day);

  Future<void> pumpCard(
    WidgetTester tester,
    FakeKugouProvider kugou, {
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<KugouProvider>.value(
        value: kugou,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: const [SignInMiniCard()],
              ),
            ),
          ),
        ),
      ),
    );
    // 签到中态有无限循环的 loading 动画，pumpAndSettle 会超时
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('未登录态：显示「登录后签到」按钮且可点击', (tester) async {
    final kugou = FakeKugouProvider();
    await pumpCard(tester, kugou);

    expect(find.text('签到日历'), findsOneWidget);
    expect(find.text('本月已签 0 天'), findsOneWidget);
    expect(find.text('登录后签到'), findsOneWidget);
    expect(find.text('签到'), findsNothing);
    expect(find.text('今日已签到'), findsNothing);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '登录后签到'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('登录未签：点击「签到」→ 调 manualSignIn 并 SnackBar 反馈', (tester) async {
    final kugou = FakeKugouProvider(
      loggedIn: true,
      signInResult: (true, '签到成功（概念版会员）'),
    );
    await pumpCard(tester, kugou);

    await tester.tap(find.text('签到'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(kugou.manualSignInCalls, 1);
    // 成功后 SnackBar 反馈（本地已签 / 服务端记录刷新由 provider 内部完成）
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('签到成功（概念版会员）'), findsOneWidget);
  });

  testWidgets('登录未签签到失败：SnackBar 显示 provider 返回的失败原因', (tester) async {
    final kugou = FakeKugouProvider(
      loggedIn: true,
      signInResult: (false, '升级概念版失败'),
    );
    await pumpCard(tester, kugou);

    await tester.tap(find.text('签到'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(kugou.manualSignInCalls, 1);
    expect(find.text('升级概念版失败'), findsOneWidget);
  });

  testWidgets('登录+今日已签：按钮可点，点击进入签到日历页', (tester) async {
    final kugou = FakeKugouProvider(loggedIn: true, hasSignedToday: true);
    await pumpCard(tester, kugou);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '今日已签到'),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.text('今日已签到'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SignInCalendarPage), findsOneWidget);
    expect(kugou.manualSignInCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('签到中：显示「签到中」且按钮禁用', (tester) async {
    final kugou = FakeKugouProvider(loggedIn: true, signInRunning: true);
    await pumpCard(tester, kugou, settle: false);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '签到中'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('点击卡体 → 跳转签到日历页（SignInCalendarPage）', (tester) async {
    final kugou = FakeKugouProvider(loggedIn: true, hasSignedToday: true);
    await pumpCard(tester, kugou);

    // 点标题区域（卡体内、按钮外）→ 整卡进入签到日历页
    await tester.tap(find.text('签到日历'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SignInCalendarPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本月已签天数 = 服务端 svip 记录 + 本地兜底合并', (tester) async {
    final now = DateTime.now();
    // 服务端：一条 svip（计入）+ 一条 tvip（过滤）。
    // 月初（day<3）时不放 svip 条目，避免构造出跨月非法日期。
    final svipDay = now.day >= 3 ? now.day - 2 : null;
    final expectedCount = (svipDay != null ? 1 : 0) + 1;
    final record = <String, dynamic>{
      'data': <String, dynamic>{
        'list': <dynamic>[
          if (svipDay != null)
            <String, dynamic>{'day': dayKey(svipDay), 'vip_type': 'svip'},
          <String, dynamic>{'day': dayKey(now.day - 1), 'vip_type': 'tvip'},
        ],
      },
    };
    // 本地：今天已签（兜底，服务端记录不及时时保证立即打点）
    final kugou = FakeKugouProvider(
      localSignedDays: {dayKey(now.day)},
      vipMonthRecord: record,
    );
    await pumpCard(tester, kugou);

    expect(find.text('本月已签 $expectedCount 天'), findsOneWidget);
  });

  testWidgets('hasSignedToday 口径：本地已签含今日且服务端记录为空 → 今日已签到', (
    tester,
  ) async {
    final kugou = FakeKugouProvider(
      loggedIn: true,
      localSignedDays: {todayKey()},
    );
    await pumpCard(tester, kugou);

    expect(find.text('今日已签到'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '今日已签到'),
    );
    expect(button.onPressed, isNotNull);
  });

  test('provider hasSignedToday：本地已签含今日 → true，与概念版徽章解耦', () async {
    SharedPreferences.setMockInitialValues({
      'settings_signed_days': <String>[todayKey()],
    });
    final provider = KugouProvider(registerDeviceOnStart: false);
    addTearDown(provider.dispose);
    // 构造函数内异步加载本地已签，等一个事件循环
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(provider.vipMonthRecord, isNull);
    expect(provider.hasSignedToday, isTrue);
    // 本地已签同样代表今日概念版已激活（既有语义保留）
    expect(provider.isTodayYouthVip, isTrue);
  });

  test('provider hasSignedToday：本地只有昨日 → false；昨日不影响今日徽章', () async {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final yesterdayKey =
        '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-'
        '${yesterday.day.toString().padLeft(2, '0')}';
    SharedPreferences.setMockInitialValues({
      'settings_signed_days': <String>[yesterdayKey],
    });
    final provider = KugouProvider(registerDeviceOnStart: false);
    addTearDown(provider.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(provider.hasSignedToday, isFalse);
    expect(provider.isTodayYouthVip, isFalse);
  });
}
