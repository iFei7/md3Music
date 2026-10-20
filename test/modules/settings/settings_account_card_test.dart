import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:md3music/data/models/kugou_account.dart';
import 'package:md3music/modules/settings/settings_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

import 'fake_kugou_provider.dart';

/// 设置页账号卡（SettingsAccountCard）测试：
/// - 登录 + 有 gradeInfo → 「Lv.{等级} · 听歌 {时长}」在场；
/// - 未登录 / 登录但无 gradeInfo → 占位文案在场；
/// - 点击卡片 → 「账号管理」底部面板出现（面板内可登录新账号）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 测试 harness：material_ui 的 MaterialApp（项目约定），账号卡单独挂载，
  /// 只注入它消费的 Provider。
  Future<void> pumpCard(WidgetTester tester, FakeKugouProvider kugou) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<KugouProvider>.value(value: kugou),
          ChangeNotifierProvider<FavoritesProvider>.value(
            value: FavoritesProvider(syncOnStart: false),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: const [SettingsAccountCard()],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('账号卡：等级 / 听歌时长行', () {
    testWidgets('登录且有 gradeInfo → 显示 Lv. 与累计听歌时长', (tester) async {
      final kugou = FakeKugouProvider(
        loggedIn: true,
        userInfo: const KugouUserDetail(nickname: '测试用户'),
        // 7500 秒 = 2 小时 5 分
        gradeInfo: const KugouGradeInfo(dSec: 7500, pGrade: 3),
      );
      await pumpCard(tester, kugou);

      expect(find.text('测试用户'), findsOneWidget);
      expect(find.text('已登录'), findsOneWidget);
      // 等级行：格式与用户中心等级区块共用（formatGradeSeconds）
      expect(find.text('Lv.3 · 听歌 2小时5分'), findsOneWidget);
      expect(find.text('登录后查看等级与听歌时长'), findsNothing);
    });

    testWidgets('未登录 → 显示占位文案与「点击登录」', (tester) async {
      final kugou = FakeKugouProvider();
      await pumpCard(tester, kugou);

      expect(find.text('点击登录'), findsOneWidget);
      expect(find.text('登录后同步收藏与歌单'), findsOneWidget);
      expect(find.text('登录后查看等级与听歌时长'), findsOneWidget);
      expect(find.textContaining('Lv.'), findsNothing);
    });

    testWidgets('登录但 gradeInfo 未就绪（冷启动）→ 占位文案兜底', (tester) async {
      final kugou = FakeKugouProvider(
        loggedIn: true,
        userInfo: const KugouUserDetail(nickname: '已登录用户'),
      );
      await pumpCard(tester, kugou);

      expect(find.text('已登录'), findsOneWidget);
      expect(find.text('登录后查看等级与听歌时长'), findsOneWidget);
    });
  });

  group('账号卡：点击弹出账号管理面板', () {
    testWidgets('点击卡片 → 「账号管理」底部面板出现（含账号列表）', (tester) async {
      final kugou = FakeKugouProvider(
        loggedIn: true,
        userInfo: const KugouUserDetail(nickname: '当前账号'),
        savedAccounts: [
          KugouAccount(userid: '1001', nickname: '大号', loginTime: 200),
          KugouAccount(userid: '1002', nickname: '小号', loginTime: 100),
        ],
      );
      await pumpCard(tester, kugou);

      await tester.tap(find.byType(SettingsAccountCard));
      // 面板内容在路由首帧即入树（入场动画只影响位移/透明度），
      // 不等动画 settle，避免对弹簧时长敏感
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 面板标题与账号计数
      expect(find.text('账号管理'), findsOneWidget);
      expect(find.text('2 个账号'), findsOneWidget);
      // 已保存账号进入列表（头像为空 → 昵称首字回退，不走网络图）
      expect(find.text('大号'), findsOneWidget);
      expect(find.text('小号'), findsOneWidget);
      // 面板内可登录新账号（未登录态同样可用，与 /user 等价）
      expect(find.text('登录新账号'), findsOneWidget);
    });

    testWidgets('未登录点击卡片 → 同样弹出账号管理面板（空态引导）', (tester) async {
      final kugou = FakeKugouProvider();
      await pumpCard(tester, kugou);

      await tester.tap(find.byType(SettingsAccountCard));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('账号管理'), findsOneWidget);
      expect(find.text('暂无已保存的账号'), findsOneWidget);
      expect(find.text('登录新账号'), findsOneWidget);
    });
  });
}
