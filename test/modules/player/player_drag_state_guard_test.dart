/// 拖拽展开全局状态收口回归测试（批次 58e 严重 bug）。
///
/// 真机实测 bug：悬浮 Dock 与悬浮播放器**高概率整体半透明且不可点击，
/// 冷重启才恢复**。根因是全局拖拽状态机（`playerExpansion` /
/// `playerDragActive`）存在多条「失去收口者」路径，残留在
/// exp ∈ (0.2, 0.5] 且 dragActive = false 时，Dock 渲染为
/// `Opacity(1-exp)` + `IgnorePointer`——即「半透明且不可点击」。
///
/// 本文件覆盖三层收口防御的核心可断言行为：
/// 1. `resetStalePlayerDragState()` 纯函数：无活跃播放页路由时复位残留；
/// 2. `DraggablePlayerRoute.dispose` 收口：pop 过渡被中断（路由 finalize）
///    后微任务兜底复位，覆盖 didPop 归零被过渡期写回覆盖的场景；
/// 3. Dock State dispose 收口：Dock 卸载（pop 二级页触发 dock 重挂载）
///    打断拖拽或回归收敛动画时复位全局量——harness 复刻
///    secondary_dock_test 的 controller + observer + 仅播放器 Dock 装配
///    （该路径经既有用例验证 pump 稳定；pumpWidget 整树替换场景在
///    GlassDockPlayer 既有组件栈下会挂起，与本次修复无关，已二分排除）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/secondary_dock_controller.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/glass_dock_player.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _noopSelectTab(String id) {}

void _noopNavChanged(bool expanded) {}

/// 占位导航展开态（仅播放器形态不消费该值）。
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

/// 复刻 app.dart builder 装配的最小 harness：push 二级页挂出仅播放器
/// Dock（controller.visible=true），pop 即卸载 Dock（dispose 收口路径）。
class _DockHarness extends StatelessWidget {
  const _DockHarness({required this.controller});

  final SecondaryDockController controller;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider()),
        ChangeNotifierProvider<TabConfigProvider>(
          create: (_) => TabConfigProvider(),
        ),
      ],
      child: MaterialApp(
        navigatorObservers: [SecondaryDockRouteObserver(controller)],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('push-secondary'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const Scaffold(
                      body: Center(child: Text('二级页')),
                    ),
                  ),
                ),
                child: const Text('push 二级页'),
              ),
            ),
          ),
        ),
        builder: (context, child) {
          return ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return Stack(
                children: [
                  ?child,
                  if (controller.visible)
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
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 全局拖拽状态机复位（用例间互不残留）
    resetStalePlayerDragState();
    activePlayerRoute = null;
    playerDragOriginTop = 0.0;
  });

  group('resetStalePlayerDragState（纯函数收口）', () {
    test('无活跃播放页路由 + 残留状态 → 复位并返回 true', () {
      activePlayerRoute = null;
      playerExpansion.value = 0.3;
      playerDragActive.value = true;

      expect(resetStalePlayerDragState(), isTrue);
      expect(playerExpansion.value, 0.0);
      expect(playerDragActive.value, isFalse);
    });

    test('播放页路由引用失效（已移除未置空）→ 仍复位', () {
      // 模拟 activePlayerRoute 指向已不再栈中的旧路由（isActive=false）
      final staleRoute = DraggablePlayerRoute(
        builder: (_) => const SizedBox(),
      );
      activePlayerRoute = staleRoute;
      playerExpansion.value = 0.45;
      playerDragActive.value = true;

      expect(resetStalePlayerDragState(), isTrue);
      expect(playerExpansion.value, 0.0);
      expect(playerDragActive.value, isFalse);
    });
  });

  group('DraggablePlayerRoute.dispose 收口', () {
    testWidgets('路由移除后微任务兜底复位残留展开进度', (tester) async {
      // 模拟 pop 过渡被中断：didPop 入口归零后被过渡期写回覆盖，
      // 路由 finalize（dispose）时 exp 残留在中间值
      final route = DraggablePlayerRoute(builder: (_) => const SizedBox());
      activePlayerRoute = null;
      playerExpansion.value = 0.35;
      playerDragActive.value = true;

      route.dispose();
      // 微任务收口执行（dispose 内 scheduleMicrotask）
      await tester.pump(const Duration(milliseconds: 1));

      expect(playerExpansion.value, 0.0);
      expect(playerDragActive.value, isFalse);
    });
  });

  group('Dock State dispose 收口（重挂载打断拖拽/收敛动画）', () {
    testWidgets('pop 卸载 Dock 时复位残留的全局拖拽状态', (tester) async {
      final controller = SecondaryDockController();
      await tester.pumpWidget(_DockHarness(controller: controller));
      await tester.pumpAndSettle();

      // push 二级页 → 仅播放器 Dock 挂载（与真机二级页 Dock 同路径）
      await tester.tap(find.byKey(const ValueKey('push-secondary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('secondary_dock')), findsOneWidget);

      // 模拟拖拽/收敛被 Dock 重挂载打断：全局量卡在
      // 「半透明 + 不可点击」组合（exp ∈ (0.2, 0.5] + dragActive=false）
      playerExpansion.value = 0.3;
      playerDragActive.value = true;

      // pop 二级页 → Dock 卸载（dispose 收口）+ observer didPop 兜底
      // （双保险，任一生效即复位）
      final navigatorState = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigatorState.pop();
      await tester.pumpAndSettle();

      expect(playerExpansion.value, 0.0);
      expect(playerDragActive.value, isFalse);
    });

    testWidgets('残留中间值时 Dock 渲染为半透明且不可点击（症状复现基线）',
        (tester) async {
      final controller = SecondaryDockController();
      await tester.pumpWidget(_DockHarness(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('push-secondary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('secondary_dock')), findsOneWidget);

      playerExpansion.value = 0.3;
      playerDragActive.value = false;
      await tester.pump(const Duration(milliseconds: 1));

      // Dock 的全局包装层：Opacity(1-exp) + IgnorePointer(exp > 0.2)
      // ——bug 症状的直接来源。该行为本身是展开过渡的合法中间态（修复
      // 不改渲染语义），三层收口保证状态机不会停留在该区间。
      final ignoreFinder = find.byWidgetPredicate(
        (w) => w is IgnorePointer && w.ignoring,
      );
      expect(ignoreFinder, findsWidgets);
      expect(playerExpansion.value, 0.3);
      expect(playerDragActive.value, isFalse);
    });
  });
}
