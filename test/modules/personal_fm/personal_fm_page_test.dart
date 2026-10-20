/// 私人 FM 页 UI 统一回归测试（批次 18）。
///
/// FM 页由 Scaffold + ScrollAwareAppBar 折叠顶栏迁移到与其他三个 tab 页
/// （首页/音乐库/搜索）同款的 [SonifyTitleScaffold] 大标题骨架：
/// - 固定悬浮大标题「私人FM」（首 item 标题占位 + _PinnedLargeTitle）；
/// - 右上角常驻 [UserAvatarButton]（点击进设置页 /settings）；
/// - 原内容区（toolbar/hero/now panel/空态）整体收进业务 item 的固定高
///   「视口 − 状态栏 − 52」SizedBox 内的 SingleChildScrollView；
/// - ScrollAwareAppBar 及其 _scrollController 移除（不再有折叠顶栏）。
///
/// 测试最小可用：只断言骨架三要素 + 无 ScrollAwareAppBar，不追求全内容
/// 渲染（未登录态走空态分支，异步加载有限帧内跑完）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/modules/personal_fm/personal_fm_page.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/common/sonify_title_scaffold.dart';
import 'package:md3music/widgets/common/user_avatar_button.dart';
import 'package:md3music/widgets/scroll_aware_app_bar.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无 Provider 树），避免测试环境异常。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

/// 假音频服务：init 立即返回，其余方法经 noSuchMethod 抛错——使
/// PlayerProvider 的音频初始化快速走完内部 try/catch，不触发真实
/// just_audio 平台加载（Windows 宿主上可能挂起）。
class _FakeAudioService {
  Future<void> init() async {}

  // ignore: annotate_overrides
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '_FakeAudioService: 未实现的方法 ${invocation.memberName}',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('FM 页迁移 SonifyTitleScaffold：大标题 + 常驻头像 + 无 ScrollAwareAppBar',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    // 注入假音频服务，避免 PlayerProvider 触发真实音频平台初始化
    AudioServiceLoader.setTestOverride(() async => _FakeAudioService());
    // registerDeviceOnStart=false：构造期不发网络（未登录态 _restoreStrategy
    // 会提前 return，本就不打 FM 接口；此处双保险）
    final kugou = KugouProvider(registerDeviceOnStart: false);
    final player = PlayerProvider();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme,
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<KugouProvider>.value(value: kugou),
              ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ],
            child: const PersonalFmPage(),
          ),
        ),
      );
      // 首帧 + 若干帧：让 initState 的 postFrame（Player 监听挂载）、
      // _restoreStrategy 的 SharedPreferences 异步链路跑完
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // ① 固定悬浮大标题「私人FM」（_PinnedLargeTitle + 占位 item 同文案）
      expect(find.text('私人FM'), findsWidgets);
      // ② 右上角常驻用户头像（统一组件）
      expect(find.byType(UserAvatarButton), findsOneWidget);
      // ③ 旧的折叠顶栏已移除
      expect(find.byType(ScrollAwareAppBar), findsNothing);
      // 新骨架在位
      expect(find.byType(SonifyTitleScaffold), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      player.dispose();
      kugou.dispose();
      AudioServiceLoader.setTestOverride(null);
      uninstallFakeSecureStorage();
    }
  });
}
