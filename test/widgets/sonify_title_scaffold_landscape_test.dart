/// 批次 36：横屏「收窄顶栏」回归测试（取代批次 35 的「上滑隐藏」）。
///
/// 设计意图（用户原话）：「所有含顶栏的页面：上滑时顶部不隐藏，做收窄
/// 处理，即高度变窄，顶栏按钮标题等保留。」
///
/// 收窄形态（批次 37 定值，批次 36 再降一档，见 scaffold 常量族）：
/// - 标题区高度 52dp（8+36+8）→ 32dp（5+22+5）；
/// - 大标题字号 20sp（行高 36）→ 13sp（行高 22）；
/// - 右上头像（36dp）、actions 钮、渐变模糊带（状态栏 + 54dp）全部
///   保留且保持原尺寸/原位置（只收标题区）；
/// - 动画 180ms easeOut（kSonifyTopBarCompactDuration），回顶恢复。
///
/// 覆盖：
/// ① 横屏骨架宿主 offset > 0 → 标题区收窄为紧凑态（高度/字号/顶距），
///    头像 / actions / 模糊带全部仍在原位，动画中间态可观测；
/// ② 回顶（offset ≤ 0）→ 恢复展开态（52dp / 20sp / 顶距 8dp）；
/// ③ 竖屏 offset > 0 → 顶栏仍在原处（既有固定悬浮路径，不挂收窄壳）；
/// ④ 单固定高 item 页面（音乐库 hub / 本地音乐形态）经既有
///    [ContentScrollSignal] → barBackgroundVisible 链路，外部信号驱动
///    横屏收窄 / 回顶恢复；
/// ⑤ 搜索页横屏坍缩态（outer offset ≥ 52）→ overlay 收窄（不出屏）、
///    坍缩搜索钮仍在场，展开态恢复。
///
/// 竖屏既有路径的回归锁在 test/widgets/sonify_title_scaffold_test.dart
/// （该文件宿主已按竖屏口径钉死——flutter test 默认窗口 800×600 即
/// 横屏）。
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
import 'package:md3music/widgets/common/user_avatar_button.dart';

import '../test_helpers/fake_secure_storage.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无 Provider 树），避免测试环境异常。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

/// 横屏 / 竖屏 MediaQuery（批次 36 起测试文件必须显式钉方向：flutter
/// test 默认窗口 800×600 即横屏）。宿主无系统 inset（status bar = 0）。
const _landscapeMQ = MediaQueryData(size: Size(800, 600));
const _portraitMQ = MediaQueryData(size: Size(400, 800));

/// 收窄两态锚点（与 scaffold 私有常量同口径，测试侧显式钉死防漂移）：
/// 展开态 = 顶距 8 + 行高 36 + 底距 8（标题区 52）；紧凑态 = 5 + 22 + 5
/// （标题区 32，批次 37）。字号 20sp → 13sp。
const _expandedTop = 8.0;
const _expandedLineHeight = 36.0;
const _compactTop = 5.0;
const _compactLineHeight = 22.0;
const _expandedFontSize = 20.0;
const _compactFontSize = 13.0;

/// 固定悬浮大标题的屏幕矩形（可见标题 = 树中最后一个同文本 widget）。
Rect _titleRect(WidgetTester tester, String title) =>
    tester.getRect(find.text(title).last);

/// 固定悬浮大标题的样式字号（收窄两态的核心断言量）。
double _titleFontSize(WidgetTester tester, String title) =>
    tester.widget<Text>(find.text(title).last).style?.fontSize ?? -1;

/// 模糊带（key 'sonify_bar_blur'）的 AnimatedOpacity 目标值：收窄态下
/// 渐变带仍随滚动浮现（「渐变模糊带保留」）。
double _bandOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('sonify_bar_blur')),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

/// 骨架测试宿主：返回 widget + 外部 ScrollController（供滚动注入）。
/// [landscape] 控制 MediaQuery 方向；[barBackgroundVisible] 模拟
/// hub/本地音乐页的外部滚动信号注入（单固定高 item 页面）；
/// [trailing] 顶栏右侧常驻内容（收窄态须仍在场的第三要素）。
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
  group('批次36 横屏收窄顶栏（SonifyTitleScaffold）', () {
    testWidgets('①横屏 offset>0：标题区收窄（32dp/13sp/顶距5），头像/actions/模糊带全保留',
        (tester) async {
      final (widget, controller) = _host(
        title: '发现',
        landscape: true,
        trailing: const Icon(Icons.person),
      );
      await tester.pumpWidget(widget);
      await tester.pump();

      // 初始态（回顶/展开态）：标题区 52dp 口径（顶距 8 + 行高 36）
      expect(_titleRect(tester, '发现').topLeft, const Offset(20, _expandedTop));
      expect(_titleRect(tester, '发现').height, _expandedLineHeight);
      expect(_titleFontSize(tester, '发现'), _expandedFontSize);
      expect(find.byKey(const ValueKey('sonify_bar_blur')), findsOneWidget);
      expect(_bandOpacity(tester), 0, reason: '回顶态渐变带未浮现');

      // 横屏 + 离开顶部（小 offset，保证业务 item 0 仍在场可断言）：
      // 收窄信号翻转
      controller.jumpTo(10);
      await tester.pump();

      // 动画进行中（50ms / 180ms easeOut）：字号在两端值之间——是动画
      // 不是跳变
      await tester.pump(const Duration(milliseconds: 50));
      final midFontSize = _titleFontSize(tester, '发现');
      expect(midFontSize, lessThan(_expandedFontSize), reason: '已开始收窄');
      expect(midFontSize, greaterThan(_compactFontSize), reason: '尚未收到位');

      // 200ms 后收敛：紧凑态 = 顶距 5 + 行高 22（13sp），标题区 32dp
      await tester.pump(const Duration(milliseconds: 150));
      expect(_titleFontSize(tester, '发现'), _compactFontSize);
      expect(_titleRect(tester, '发现').topLeft, const Offset(20, _compactTop));
      expect(_titleRect(tester, '发现').height, _compactLineHeight);

      // 渐变模糊带保留：仍在树、仍在屏幕最顶、仍随滚动浮现（不出屏）
      expect(find.byKey(const ValueKey('sonify_bar_blur')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('sonify_bar_blur'))).topLeft,
        Offset.zero,
        reason: '模糊带不从屏幕顶消失（收窄而非滑出）',
      );
      expect(_bandOpacity(tester), 1, reason: '滚动态渐变带继续出带');

      // 右上头像 / actions 全部保留且可命中（无滑出壳、无 IgnorePointer
      // 整栏遮蔽——收窄态栏体仍可交互）
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(find.byIcon(Icons.person).hitTestable(), findsOneWidget);

      // 占位 item 同步收窄：业务 item 0 盒顶从「52 − offset」上移到
      // 「32 − offset」——滚动态内容区增高 20dp（「减少遮挡」）。
      // 取 item 盒（SizedBox 100）而非其内 ListTile 文本——文本距盒顶
      // 有 ListTile 内部 16px 内边距，不能代表内容区起点。
      final itemBox = find
          .ancestor(of: find.text('item 0'), matching: find.byType(SizedBox))
          .first;
      expect(
        tester.getTopLeft(itemBox).dy,
        closeTo(32 - 10, 0.5),
        reason: '占位收窄后 item 0 盒顶 = 紧凑标题区 32 − offset 10',
      );
    });

    testWidgets('②横屏回顶（offset<=0）：恢复展开态（52dp/20sp/顶距8）', (tester) async {
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
      // 先确认已收窄
      expect(_titleFontSize(tester, '发现'), _compactFontSize);
      expect(_titleRect(tester, '发现').height, _compactLineHeight);

      controller.jumpTo(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // 恢复展开态：顶距 8、行高 36、字号 20sp（与批次 36 前逐像素一致）
      expect(_titleFontSize(tester, '发现'), _expandedFontSize);
      expect(_titleRect(tester, '发现').topLeft, const Offset(20, _expandedTop));
      expect(_titleRect(tester, '发现').height, _expandedLineHeight);
      // 渐变带回顶消失、头像仍可命中
      expect(_bandOpacity(tester), 0);
      expect(find.byIcon(Icons.person).hitTestable(), findsOneWidget);
      // 业务 item 0 盒顶回到展开态起点（52 − 0）
      final itemBox = find
          .ancestor(of: find.text('item 0'), matching: find.byType(SizedBox))
          .first;
      expect(tester.getTopLeft(itemBox).dy, closeTo(52, 0.5));
    });

    testWidgets('③竖屏 offset>0：顶栏仍在原处（既有路径，不挂收窄壳）',
        (tester) async {
      final (widget, controller) = _host(title: '发现', landscape: false);
      await tester.pumpWidget(widget);
      await tester.pump();
      final before = _titleRect(tester, '发现');

      controller.jumpTo(120);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 标题原地不动（固定悬浮，既有行为）：展开态几何不随滚动变化
      expect(_titleRect(tester, '发现'), before);
      expect(_titleRect(tester, '发现').topLeft, const Offset(20, _expandedTop));
      expect(_titleFontSize(tester, '发现'), _expandedFontSize);
      // 竖屏不挂收窄动画壳：标题无 Transform / AnimatedOpacity / Tween
      // 外壳（栏背景淡入那枚在 _TopBar 兄弟子树，不是标题祖先）
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
      expect(
        find.ancestor(
          of: find.text('发现').last,
          matching: find.byType(TweenAnimationBuilder),
        ),
        findsNothing,
      );
      // 竖屏栏背景仍按既有 offset>0 浮现（行为与批次 36 前一致）
      expect(_bandOpacity(tester), 1);
    });

    testWidgets('④单固定高 item 页面：ContentScrollSignal 外部信号驱动横屏收窄',
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
                // 固定高度 = 视口 − 状态栏 − 标题区（8+36+8=52，与展开态
                // 占位 item 同口径，对齐 library_hub_page；该常量口径不随
                // 收窄态折算——见交付报告「固定高 item 处理决策」）
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
      expect(_titleRect(tester, '音乐库').topLeft, const Offset(20, _expandedTop));
      expect(_titleFontSize(tester, '音乐库'), _expandedFontSize);

      // 内层列表上滑：ContentScrollSignal 上传信号 → 顶栏收窄（不出屏）
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(signal.value, isTrue, reason: '内层列表离开顶部，信号应翻转');
      expect(_titleFontSize(tester, '音乐库'), _compactFontSize);
      expect(_titleRect(tester, '音乐库').topLeft, const Offset(20, _compactTop));
      expect(_titleRect(tester, '音乐库').height, _compactLineHeight);
      // 渐变带与头像保留（收窄而非隐藏）
      expect(find.byKey(const ValueKey('sonify_bar_blur')), findsOneWidget);
      expect(_bandOpacity(tester), 1);

      // 内层回顶：信号复位 → 顶栏恢复展开态
      await tester.drag(find.byType(ListView), const Offset(0, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(signal.value, isFalse);
      expect(_titleRect(tester, '音乐库').topLeft, const Offset(20, _expandedTop));
      expect(_titleFontSize(tester, '音乐库'), _expandedFontSize);
      expect(_titleRect(tester, '音乐库').height, _expandedLineHeight);
    });
  });

  group('批次36 横屏收窄顶栏（搜索页 overlay）', () {
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

    testWidgets('⑤搜索页横屏坍缩态（offset>=52）：overlay 收窄不出屏，回顶恢复',
        (tester) async {
      await pumpSearchHost(tester);

      // 展开态：标题区 52dp 口径（顶距 8 + 行高 36、20sp）
      expect(_titleRect(tester, '搜索').topLeft, const Offset(20, _expandedTop));
      expect(_titleFontSize(tester, '搜索'), _expandedFontSize);

      final outerScrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(NestedScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // outer offset ≥ 坍缩阈值 52：坍缩态 = 顶栏收窄（不出屏）
      outerScrollable.position.jumpTo(60);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_titleFontSize(tester, '搜索'), _compactFontSize);
      expect(_titleRect(tester, '搜索').topLeft, const Offset(20, _compactTop));
      expect(_titleRect(tester, '搜索').height, _compactLineHeight);
      // 坍缩搜索圆钮此时已在树（_collapsed 驱动 actions）且仍可命中
      // （收窄态无滑出壳，栏体不出屏）
      expect(find.byKey(const ValueKey('search-collapsed-icon')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('search-collapsed-icon')).hitTestable(),
        findsOneWidget,
        reason: '收窄态坍缩圆钮仍可交互（不同于批次 35 的出屏）',
      );
      // 头像与渐变模糊带保留
      expect(find.byType(UserAvatarButton), findsOneWidget);
      expect(find.byKey(const ValueKey('sonify_bar_blur')), findsOneWidget);

      // 回顶展开：恢复展开态几何
      outerScrollable.position.jumpTo(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_titleRect(tester, '搜索').topLeft, const Offset(20, _expandedTop));
      expect(_titleFontSize(tester, '搜索'), _expandedFontSize);
      expect(_titleRect(tester, '搜索').height, _expandedLineHeight);

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
    Future<void>? cancelToken,
  ) async {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'offline test adapter',
    );
  }
}
