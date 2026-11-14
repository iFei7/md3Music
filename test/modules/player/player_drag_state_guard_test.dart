/// 拖拽展开全局状态清理回归测试（批次 58e-r2：交互点自愈）。
///
/// 真机实测 bug：悬浮 Dock 与悬浮播放器**高概率整体半透明且不可点击，
/// 冷重启才恢复**。根因是全局拖拽状态机（`playerExpansion` /
/// `playerDragActive`）的「失去收口者」路径——Dock State 重挂载（横竖屏
/// 切换 / 一级 ↔ 二级页 Dock 实例切换）发生在上滑拖拽或回归收敛动画
/// （200ms 窗口）中，收敛动画随 State 销毁中断，全局量永卡中间值；
/// exp ∈ (0.2, 0.5] 且 dragActive = false 时 Dock 渲染为
/// `Opacity(1-exp)` + `IgnorePointer`——即「半透明且不可点击」。
///
/// 方案演变：58e 首版用 dispose / 路由观察者钩子自动收口，真机实测引入
/// 「二级页上滑/点击悬浮播放器打不开播放页」回归（整体 revert）。r2 改为
/// **交互点自愈**：只在用户主动发起新交互的入口（openFullPlayer / Dock
/// 拖拽 start）清理脏残留，完整播放页活跃时跳过——零回归风险，残留
/// 在下一次交互时自愈，不再需要冷重启。
///
/// 本文件覆盖：
/// 1. `resetStalePlayerDragState()` 纯函数：无活跃播放页路由时复位残留，
///    路由引用失效（已移除未置空）时同样复位；
/// 2. 症状复现基线：残留中间值时 Dock 渲染为半透明且不可点击
///    （IgnorePointer(ignoring:true)）——清理接线（openFullPlayer /
///    _onPlayerDragStart）由代码调用点保证，见两处入口注释。
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
/// Dock（controller.visible=true），pop 即卸载 Dock——Dock 卸载时若拖拽
/// / 回归收敛动画进行中即产生全局脏残留（本次修复针对的场景）。
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

  group('resetStalePlayerDragState（交互点自愈纯函数）', () {
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

    test('无残留时为幂等 no-op（返回 false）', () {
      activePlayerRoute = null;
      playerExpansion.value = 0.0;
      playerDragActive.value = false;

      expect(resetStalePlayerDragState(), isFalse);
      expect(playerExpansion.value, 0.0);
      expect(playerDragActive.value, isFalse);
    });
  });

  group('症状复现基线（残留中间值时的 Dock 渲染表现）', () {
    testWidgets('exp ∈ (0.2, 0.5] 且 dragActive=false → Dock 半透明不可点击',
        (tester) async {
      final controller = SecondaryDockController();
      await tester.pumpWidget(_DockHarness(controller: controller));
      await tester.pumpAndSettle();

      // push 二级页 → 仅播放器 Dock 挂载（与真机二级页 Dock 同路径）
      await tester.tap(find.byKey(const ValueKey('push-secondary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('secondary_dock')), findsOneWidget);

      // 模拟拖拽/收敛被 Dock 重挂载打断：全局量卡在
      // 「半透明 + 不可点击」组合
      playerExpansion.value = 0.3;
      playerDragActive.value = false;
      await tester.pump(const Duration(milliseconds: 1));

      // Dock 的全局包装层：Opacity(1-exp) + IgnorePointer(exp > 0.2)
      // ——bug 症状的直接来源。该渲染语义本身是展开过渡的合法中间态
      // （r2 不改渲染行为），交互点自愈保证状态机不会停留在该区间：
      // 用户下一次点击/拖拽（openFullPlayer / _onPlayerDragStart 入口）
      // 即复位。
      final ignoreFinder = find.byWidgetPredicate(
        (w) => w is IgnorePointer && w.ignoring,
      );
      expect(ignoreFinder, findsWidgets);
      expect(playerExpansion.value, 0.3);
      expect(playerDragActive.value, isFalse);
    });
  });
}
