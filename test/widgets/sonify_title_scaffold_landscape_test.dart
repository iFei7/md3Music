/// 批次 35：横屏「上滑隐藏顶栏」回归测试。
///
/// 设计意图（用户原话）：「横屏设备高度小，所以尽可能减少页面纵向上的
/// 遮挡，页面如果存在顶栏，横屏时尽可能上滑隐藏顶栏。」
///
/// 覆盖：
/// ① 横屏骨架宿主 offset > 0 → 顶栏整体（大标题 + 渐变模糊带 + 头像 +
///    actions）translateY = −（状态栏 + 52dp 标题区）并淡出，动画
///    180ms easeOut 收敛（本文件以 200ms 断言）；
/// ② 回顶（offset ≤ 0）→ 整栏滑回恢复；
/// ③ 竖屏 offset > 0 → 顶栏仍在原处（既有固定悬浮路径，不挂滑出壳）；
/// ④ 单固定高 item 页面（音乐库 hub / 本地音乐形态）经既有
///    [ContentScrollSignal] → barBackgroundVisible 链路，外部信号驱动
///    横屏顶栏隐藏 / 回顶恢复；
/// ⑤ 搜索页横屏坍缩态（outer offset ≥ 52）→ overlay 整栏滑出、展开
///    态滑回。
///
/// 竖屏既有路径的回归锁在 test/widgets/sonify_title_scaffold_test.dart
/// （该文件宿主已按批次 35 口径钉死竖屏——flutter test 默认窗口
/// 800×600 即横屏）。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/modules/search/search_page.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/common/content_scroll_signal.dart';
import 'package:md3music/widgets/common/sonify_title_scaffold.dart';

import '../test_helpers/fake_secure_storage.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无 Provider 树），避免测试环境异常。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

/// 横屏 / 竖屏 MediaQuery（批次 35 起测试文件必须显式钉方向：flutter
/// test 默认窗口 800×600 即横屏）。宿主无系统 inset（status bar = 0）。
const _landscapeMQ = MediaQueryData(size: Size(800, 600));
const _portraitMQ = MediaQueryData(size: Size(400, 800));

/// 整栏滑出壳的 AnimatedOpacity 目标值：标题的最近 AnimatedOpacity 祖先
/// （栏背景那枚在 [_TopBar] 兄弟子树里，不是标题祖先）。
double _barShellOpacity(WidgetTester tester, String title) => tester
    .widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.text(title).last,
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

/// 整栏滑出壳的 Transform.translate 竖向位移：标题的最近 Transform 祖先。
double _barSlideDy(WidgetTester tester, String title) => tester
    .widget<Transform>(
      find
          .ancestor(of: find.text(title).last, matching: find.byType(Transform))
          .first,
    )
    .transform
    .getTranslation()
    .y;

/// 模糊带（key 'sonify_bar_blur'）的最近 Transform 祖先竖向位移：用于
/// 断言「带与整栏同拍随行」，不出「带还在、标题走了」的分裂。
double _bandSlideDy(WidgetTester tester) => tester
    .widget<Transform>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('sonify_bar_blur')),
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform
    .getTranslation()
    .y;

/// 骨架测试宿主：返回 widget + 外部 ScrollController（供滚动注入）。
/// [landscape] 控制 MediaQuery 方向；[barBackgroundVisible] 模拟
/// hub/本地音乐页的外部滚动信号注入（单固定高 item 页面）；
/// [trailing] 顶栏右侧常驻内容（随整栏一同滑出的第三要素）。
(Widget, ScrollController) _host({
  required String title,
  required bool landscape,
  int itemCount = 30,
  ValueNotifier<bool>? barBackgroundVisible,
  Widget? trailing,
}) {
  final controller = ScrollController();
  final widget = MediaQuery(
    data: landscape ? _landscapeMQ : _portraitMQ,
    child: MaterialApp(
      theme: _testTheme,
      home: SonifyTitleScaffold(
        title: title,
        itemCount: itemCount,
        controller: controller,
        barBackgroundVisible: barBackgroundVisible,
        trailing: trailing,
        itemBuilder: (context, index) => SizedBox(
          height: 100,
          child: ListTile(title: Text('item $index')),
        ),
      ),
    ),
  );
  return (widget, controller);
}

void main() {
  group('批次35 横屏上滑隐藏顶栏（SonifyTitleScaffold）', () {
    testWidgets('①横屏 offset>0：整栏上滑 −（状态栏+52）并淡出，200ms 后生效',
        (tester) async {
      final (widget, controller) = _host(
        title: '发现',
        landscape: true,
        trailing: const Icon(Icons.person),
      );
      await tester.pumpWidget(widget);
      await tester.pump();

      // 初始态（回顶）：顶栏在原位，壳无位移、不淡出
      expect(tester.getTopLeft(find.text('发现').last), const Offset(20, 8));
      expect(_barSlideDy(tester, '发现'), 0);
      expect(_barShellOpacity(tester, '发现'), 1);

      // 横屏 + 离开顶部：隐藏信号翻转
      controller.jumpTo(100);
      await tester.pump();

      // 动画进行中（50ms / 180ms）：既非原位也未到位——是动画不是跳变
      await tester.pump(const Duration(milliseconds: 50));
      final midDy = tester.getTopLeft(find.text('发现').last).dy;
      expect(midDy, lessThan(8), reason: '已开始上滑');
      expect(midDy, greaterThan(8 - 52), reason: '尚未滑到位');

      // 200ms 后收敛：整栏 translateY = −(0 + 52)（宿主无状态栏），
      // 标题被带出屏（dy = 8 − 52 = −44 < 0）
      await tester.pump(const Duration(milliseconds: 150));
      expect(_barSlideDy(tester, '发现'), -52);
      expect(tester.getTopLeft(find.text('发现').last), const Offset(20, -44));
      expect(_barShellOpacity(tester, '发现'), 0);

      // 模糊带与整栏同拍随行（不出「带还在、标题走了」的分裂）
      expect(find.byKey(const ValueKey('sonify_bar_blur')), findsOneWidget);
      expect(_bandSlideDy(tester), -52,
          reason: '模糊带与标题同 Translation 位移');

      // 右上头像 / actions 同属整栏壳，随行出屏（trailing 也在壳内）
      final trailingTransform = tester.widget<Transform>(
        find
            .ancestor(
              of: find.byIcon(Icons.person),
              matching: find.byType(Transform),
            )
            .first,
      );
      expect(trailingTransform.transform.getTranslation().y, -52);

      // 隐藏态命中断开：栏体已出屏，不再吸收点按
      expect(find.byIcon(Icons.person).hitTestable(), findsNothing);
    });

    testWidgets('②横屏回顶（offset<=0）：整栏滑回恢复', (tester) async {
      final (widget, controller) = _host(
        title: '发现',
        landscape: true,
        trailing: const Icon(Icons.person),
      );
      await tester.pumpWidget(widget);
      await tester.pump();

      controller.jumpTo(120);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getTopLeft(find.text('发现').last), const Offset(20, -44));

      controller.jumpTo(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_barSlideDy(tester, '发现'), 0);
      expect(tester.getTopLeft(find.text('发现').last), const Offset(20, 8));
      expect(_barShellOpacity(tester, '发现'), 1);
      // 恢复后可命中
      expect(find.byIcon(Icons.person).hitTestable(), findsOneWidget);
    });

    testWidgets('③竖屏 offset>0：顶栏仍在原处（既有路径，不挂滑出壳）',
        (tester) async {
      final (widget, controller) = _host(title: '发现', landscape: false);
      await tester.pumpWidget(widget);
      await tester.pump();
      final before = tester.getTopLeft(find.text('发现').last);

      controller.jumpTo(120);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 标题原地不动（固定悬浮，既有行为）
      expect(tester.getTopLeft(find.text('发现').last), before);
      // 竖屏不挂滑出壳：标题无 Transform / AnimatedOpacity 外壳
      // （栏背景淡入那枚在 _TopBar 兄弟子树，不是标题祖先）
      expect(
        find.ancestor(
          of: find.text('发现').last,
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.text('发现').last,
          matching: find.byType(AnimatedOpacity),
        ),
        findsNothing,
      );
      // 竖屏栏背景仍按既有 offset>0 浮现（行为与批次 35 前一致）
      expect(
        tester
            .widget<AnimatedOpacity>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('sonify_bar_blur')),
                    matching: find.byType(AnimatedOpacity),
                  )
                  .first,
            )
            .opacity,
        1,
      );
    });

    testWidgets('④单固定高 item 页面：ContentScrollSignal 外部信号驱动横屏隐藏',
        (tester) async {
      // 与音乐库 hub / 本地音乐同款结构：外层骨架单固定高 item、自身
      // 不滚动，内层列表滚动经 ContentScrollSignal 上传到
      // barBackgroundVisible（批次 24/25 既有链路）。
      final signal = ValueNotifier<bool>(false);
      final controller = ScrollController();
      await tester.pumpWidget(
        MediaQuery(
          data: _landscapeMQ,
          child: MaterialApp(
            theme: _testTheme,
            home: SonifyTitleScaffold(
              title: '音乐库',
              itemCount: 1,
              controller: controller,
              barBackgroundVisible: signal,
              itemBuilder: (context, index) {
                // 固定高度 = 视口 − 状态栏 − 标题区（8+36+8=52，与占位
                // item 同口径，对齐 library_hub_page）
                final height =
                    MediaQuery.sizeOf(context).height -
                    MediaQuery.paddingOf(context).top -
                    52;
                return ContentScrollSignal(
                  signal: signal,
                  child: SizedBox(
                    height: height,
                    child: ListView.builder(
                      itemCount: 30,
                      itemBuilder: (context, i) => SizedBox(
                        height: 100,
                        child: ListTile(title: Text('song $i')),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 初始态：顶栏在原位（外层骨架 offset 恒 0，外部信号 false）
      expect(tester.getTopLeft(find.text('音乐库').last), const Offset(20, 8));

      // 内层列表上滑：ContentScrollSignal 上传信号 → 顶栏隐藏
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(signal.value, isTrue, reason: '内层列表离开顶部，信号应翻转');
      expect(_barSlideDy(tester, '音乐库'), -52);
      expect(tester.getTopLeft(find.text('音乐库').last), const Offset(20, -44));
      expect(_barShellOpacity(tester, '音乐库'), 0);

      // 内层回顶：信号复位 → 顶栏恢复
      await tester.drag(find.byType(ListView), const Offset(0, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(signal.value, isFalse);
      expect(tester.getTopLeft(find.text('音乐库').last), const Offset(20, 8));
      expect(_barShellOpacity(tester, '音乐库'), 1);
    });
  });

  group('批次35 横屏上滑隐藏顶栏（搜索页 overlay）', () {
    late HttpClientAdapter previousAdapter;

    setUpAll(() {
      installFakeSecureStorage();
    });

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      final apiClient = KugouApiClient();
      previousAdapter = apiClient.dio.httpClientAdapter;
      apiClient.dio.httpClientAdapter = _FailingAdapter();
    });

    tearDown(() {
      KugouApiClient().dio.httpClientAdapter = previousAdapter;
    });

    tearDownAll(() {
      uninstallFakeSecureStorage();
    });

    /// 搜索页宿主：KugouProvider（UserAvatarButton 的 Selector 源）+
    /// ThemeProvider + PlayerProvider；横屏 MediaQuery。收尾推进 ≥8s
    /// fake 时间冲净本地服务就绪等待的 8s 超时 Timer（与
    /// search_page_avatar_test 同款处理）。
    Future<void> pumpSearchHost(WidgetTester tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: _landscapeMQ,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<ThemeProvider>(
                create: (_) => ThemeProvider(initialUseBackgroundImage: false),
              ),
              ChangeNotifierProvider<KugouProvider>(
                create: (_) => KugouProvider(),
              ),
              ChangeNotifierProvider<PlayerProvider>(
                create: (_) => PlayerProvider(),
              ),
            ],
            child: MaterialApp(theme: _testTheme, home: const SearchPage()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(tester.takeException(), isNull);
    }

    testWidgets('⑤搜索页横屏坍缩态（offset>=52）：overlay 整栏滑出，回顶恢复',
        (tester) async {
      await pumpSearchHost(tester);

      final titleFinder = find.text('搜索').last;
      expect(tester.getTopLeft(titleFinder), const Offset(20, 8));

      final outerScrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(NestedScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // outer offset ≥ 坍缩阈值 52：坍缩态 = 顶栏隐藏
      outerScrollable.position.jumpTo(60);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_barSlideDy(tester, '搜索'), -52);
      expect(
        tester.getTopLeft(titleFinder).dy,
        lessThan(0),
        reason: '坍缩态整栏（标题 + 头像 + 坍缩搜索钮）滑出屏幕',
      );
      expect(_barShellOpacity(tester, '搜索'), 0);
      // 坍缩搜索圆钮此时已在树（_collapsed 驱动 actions），但随整栏出屏
      expect(find.byKey(const ValueKey('search-collapsed-icon')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('search-collapsed-icon'))).dy,
        lessThan(0),
        reason: '坍缩圆钮随整栏一同出屏',
      );

      // 回顶展开：整栏滑回恢复
      outerScrollable.position.jumpTo(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_barSlideDy(tester, '搜索'), 0);
      expect(tester.getTopLeft(titleFinder), const Offset(20, 8));
      expect(_barShellOpacity(tester, '搜索'), 1);

      await tester.pump(const Duration(seconds: 10));
    });
  });
}

/// 网络隔离（与 search_page_avatar_test 同款）：请求一律快速失败，走
/// 离线路径，不触发真实网络。
class _FailingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'offline test adapter',
    );
  }
}
