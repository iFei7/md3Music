import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:md3music/modules/user/sign_in_calendar_page.dart';
import 'package:md3music/modules/user/sign_in_mini_card.dart';
import 'package:md3music/providers/kugou_provider.dart';

import 'fake_kugou_provider.dart';

/// 设置页签到迷你日历卡（SignInMiniCard）测试：
/// - 未签态显示「签到」按钮，点击调 manualSignIn 并 SnackBar 反馈；
/// - 已签态按钮禁用（「今日已签到」）；
/// - 点击卡体 → 跳转 SignInCalendarPage；
/// - 本月已签天数 = 服务端记录（svip）+ 本地兜底合并。
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

  Future<void> pumpCard(WidgetTester tester, FakeKugouProvider kugou) async {
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
    await tester.pumpAndSettle();
  }

  testWidgets('未签态：显示「签到」按钮与本月已签 0 天', (tester) async {
    final kugou = FakeKugouProvider();
    await pumpCard(tester, kugou);

    expect(find.text('签到日历'), findsOneWidget);
    expect(find.text('本月已签 0 天'), findsOneWidget);
    expect(find.text('签到'), findsOneWidget);
    expect(find.text('今日已签到'), findsNothing);
  });

  testWidgets('点击「签到」→ 调 manualSignIn 并 SnackBar 反馈结果', (tester) async {
    final kugou = FakeKugouProvider(
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

  testWidgets('签到失败：SnackBar 显示 provider 返回的失败原因', (tester) async {
    final kugou = FakeKugouProvider(
      signInResult: (false, '请先登录'),
    );
    await pumpCard(tester, kugou);

    await tester.tap(find.text('签到'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(kugou.manualSignInCalls, 1);
    expect(find.text('请先登录'), findsOneWidget);
  });

  testWidgets('今日已签：按钮禁用并显示「今日已签到」', (tester) async {
    final kugou = FakeKugouProvider(todaySigned: true);
    await pumpCard(tester, kugou);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '今日已签到'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('点击卡体 → 跳转签到日历页（SignInCalendarPage）', (tester) async {
    final kugou = FakeKugouProvider(todaySigned: true);
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
      vipMonthRecord: record,
      localSignedDays: {dayKey(now.day)},
    );
    await pumpCard(tester, kugou);

    expect(find.text('本月已签 $expectedCount 天'), findsOneWidget);
  });
}
