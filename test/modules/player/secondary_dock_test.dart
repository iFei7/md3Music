/// 二级路由悬浮播放器控制器测试（批次 24）。
///
/// 用户口径：二级 push 页面**不显示悬浮导航但显示悬浮播放器**（且恒
/// 展开）；设置页（/settings 路由）不显示悬浮栏；完整播放页
/// （DraggablePlayerRoute，本身就是播放器）也不显示。
///
/// 本测试复刻 app.dart `MaterialApp.builder` 的装配（控制器 +
/// RouteObserver + 仅播放器 Dock），验证控制器的路由栈深度/排除项
/// 语义。主布局内的一级 tab 页 Dock（导航 + 播放器）不受影响，由
/// dock_nav_library_test / dock_player_collapse_test 等既有用例覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/secondary_dock_controller.dart';
import 'package:md3music/modules/player/glass_dock_player.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 占位导航展开态（仅播放器形态不消费该值，恒展开由 GlassDockPlayer
/// 内部保证）。const 常量以便 Dock 构造可入 const 上下文。
const ValueListenable<bool> _kNavPlaceholder = _ConstNavListenable();

class _ConstNavListenable implements ValueListenable<bool> {
  const _ConstNavListenable();

  @override
  bool get value => true;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

void _noopSelectTab(String id) {}

void _noopNavChanged(bool expanded) {}

Future<void> _pumpHarness(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final controller = SecondaryDockController();
  final observer = SecondaryDockRouteObserver(controller);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        // GlassDockPlayer 依赖（仅播放器形态同样读取）
        ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider()),
        ChangeNotifierProvider<TabConfigProvider>(
          create: (_) => TabConfigProvider(),
        ),
      ],
      child: MaterialApp(
        navigatorObservers: [observer],
        routes: {
          // 与 app.dart 同名命名路由：按名排除悬浮栏的用例目标
          '/settings': (_) => const Scaffold(body: Center(child: Text('设置页'))),
        },
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    key: const ValueKey('push-secondary'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            const Scaffold(body: Center(child: Text('二级页'))),
                      ),
                    ),
                    child: const Text('push 二级页'),
                  ),
                  TextButton(
                    key: const ValueKey('push-settings'),
                    onPressed: () =>
                        Navigator.of(context).pushNamed('/settings'),
                    child: const Text('push 设置页'),
                  ),
                  TextButton(
                    key: const ValueKey('push-player'),
                    onPressed: () => Navigator.of(context).push<void>(
                      DraggablePlayerRoute(builder: (_) => const SizedBox()),
                    ),
                    child: const Text('push 播放页'),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 复刻 app.dart builder：二级态在 Navigator 之上挂仅播放器 Dock
        // （app.dart 用 ListenableBuilder 监听控制器，这里同款）
        builder: (context, child) {
          return ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return Stack(
                children: [
                  if (child != null) child!,
                  if (controller.visible)
                    // 与 app.dart 同款：全屏 Overlay 承载 Tooltip（有界），
                    // Dock 自身 Align(bottomCenter) 钉在屏底
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Overlay(
                          initialEntries: [
                            OverlayEntry(
                              builder: (_) => GlassDockPlayer(
                                key: const ValueKey('secondary_dock'),
                                selectedTabId: '',
                                onSelectTab: _noopSelectTab,
                                navExpanded: _kNavPlaceholder,
                                onNavExpandedChanged: _noopNavChanged,
                                showNav: false,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('一级路由（栈深 1）：不挂悬浮播放器', (tester) async {
    await _pumpHarness(tester);
    expect(find.byType(GlassDockPlayer), findsNothing);
  });

  testWidgets('push 二级页：挂出仅播放器 Dock（showNav=false）；pop 后消失', (tester) async {
    await _pumpHarness(tester);
    await tester.tap(find.byKey(const ValueKey('push-secondary')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final dock = find.byType(GlassDockPlayer);
    expect(dock, findsOneWidget, reason: '二级页应挂仅播放器悬浮 Dock');
    expect(
      tester.widget<GlassDockPlayer>(dock).showNav,
      isFalse,
      reason: '二级页 Dock 应为仅播放器形态（无导航）',
    );

    // 返回一级页：Dock 消失
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(GlassDockPlayer),
      findsNothing,
      reason: '回到一级页不应再有仅播放器 Dock',
    );
  });

  testWidgets('push /settings（命名路由）：不挂悬浮播放器', (tester) async {
    await _pumpHarness(tester);
    await tester.tap(find.byKey(const ValueKey('push-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(GlassDockPlayer),
      findsNothing,
      reason: '设置页不显示悬浮栏（排除名单）',
    );
  });

  testWidgets('push 完整播放页（DraggablePlayerRoute）：不挂悬浮播放器', (tester) async {
    await _pumpHarness(tester);
    await tester.tap(find.byKey(const ValueKey('push-player')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(GlassDockPlayer),
      findsNothing,
      reason: '完整播放页本身就是播放器，排除悬浮栏',
    );
  });

  testWidgets('二级页持续存在时 Dock 持续可见', (tester) async {
    await _pumpHarness(tester);
    await tester.tap(find.byKey(const ValueKey('push-secondary')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(GlassDockPlayer), findsOneWidget);
    // 再推几帧：Dock 不因动画/重建闪没
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(GlassDockPlayer), findsOneWidget);
  });
}
