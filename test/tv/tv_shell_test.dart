import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/layout/tv_nav_focus_bridge.dart';
import 'package:md3music/core/layout/tv_shell.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/tv/design/tv_design.dart';
import 'package:md3music/widgets/common/liquid_glass_surface.dart';

/// 批次43：TvMainShell 壳层渲染单测。
///
/// 普通通道（无 dart-define）下 kTvBuild=false，但 TvMainShell 本身是纯
/// widget（不依赖编译期分支），可直接 pump 钉住视觉与焦点语义：
/// - Rail 项数 = visibleTabs.length + 设置（固定追加在末尾）；
/// - 聚焦即选中：获焦项文字变白、品牌色指示条出现（120ms 淡入）；
/// - Rail 为玻璃材质（LiquidGlassSurface）；
/// - 内容占位随选中项切换。
///
/// 焦点注入走生产同款通道：Rail 项构建时把焦点节点登记进
/// [TvNavFocusBridge] 节点池，测试经 `nodeFor(i).requestFocus()` 模拟
/// 遥控方向键把焦点移到某导航项。
void main() {
  const tabs = [
    TabItem(id: 'search', label: '搜索'),
    TabItem(id: 'discover', label: '首页'),
    TabItem(id: 'library', label: '音乐库'),
    TabItem(id: 'fm', label: 'FM'),
  ];

  /// TV 布局按 1920 设计宽换算，测试面设为 1920×1080（dpr=1 → scale=1）。
  void prepareView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpShell(WidgetTester tester) async {
    prepareView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: TvLayoutScale(child: TvMainShell(visibleTabs: tabs)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Rail 子树内的文字（区别于内容占位区的同名文字）。
  Finder railText(String label) => find.descendant(
    of: find.byType(LiquidGlassSurface),
    matching: find.text(label),
  );

  testWidgets('Rail 项数 = visibleTabs.length + 设置（固定追加末尾）', (
    tester,
  ) async {
    await pumpShell(tester);

    // 四个可见 tab 按 TV 口径换名 + 固定追加的设置。
    expect(railText('搜索'), findsOneWidget);
    expect(railText('推荐'), findsOneWidget, reason: 'discover → 推荐');
    expect(railText('我的音乐'), findsOneWidget, reason: 'library → 我的音乐');
    expect(railText('现场电台'), findsOneWidget, reason: 'fm → 现场电台');
    expect(railText('设置'), findsOneWidget, reason: '设置固定追加在 Rail 末尾');

    // Rail 导航项（不含内容占位与登录位）恰好 5 个 DpadFocusable。
    final railFocusables = find.descendant(
      of: find.byType(LiquidGlassSurface),
      matching: find.byType(DpadFocusable),
    );
    expect(railFocusables.evaluate().length, tabs.length + 1);
  });

  testWidgets('Rail 为玻璃材质（LiquidGlassSurface，无实色底）', (tester) async {
    await pumpShell(tester);
    expect(find.byType(LiquidGlassSurface), findsOneWidget);
  });

  testWidgets('聚焦即选中：获焦项文字变白 + 指示条出现，失焦项回灰', (tester) async {
    await pumpShell(tester);

    // 首项 autofocus：初始即选中（白字）。
    expect(
      tester.widget<Text>(railText('搜索')).style?.color,
      Colors.white,
      reason: '首项 autofocus 后聚焦即选中',
    );

    // 模拟遥控把焦点移到第 2 项（discover → 推荐）：经生产同款节点池。
    final node = TvNavFocusBridge.instance.nodeFor(1);
    expect(node, isNotNull, reason: 'Rail 项构建时必须登记焦点节点到桥接池');
    node!.requestFocus();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      tester.widget<Text>(railText('推荐')).style?.color,
      Colors.white,
      reason: '聚焦即选中：无需 OK 确认',
    );
    expect(
      tester.widget<Text>(railText('搜索')).style?.color,
      const Color(0xFF8E929E),
      reason: '失焦项回常态灰',
    );

    // 指示条：选中项的 120ms 淡入完成后 opacity == 1，且仅 1 项处于选中。
    final opacities = tester
        .widgetList<AnimatedOpacity>(
          find.descendant(
            of: find.byType(LiquidGlassSurface),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .toList();
    expect(opacities.where((o) => o.opacity == 1.0).length, 1);
  });

  testWidgets('内容占位随选中项切换', (tester) async {
    await pumpShell(tester);

    // 初始选中第 1 项：占位显示「搜索」与批次44 提示。
    expect(find.text('TV 内容流批次44'), findsOneWidget);

    // 切到第 2 项：占位文字跟随变化。
    TvNavFocusBridge.instance.nodeFor(1)!.requestFocus();
    await tester.pump(const Duration(milliseconds: 200));

    // 「推荐」此时在 Rail 与内容占位各出现一次。
    expect(find.text('推荐'), findsNWidgets(2));
  });

  testWidgets('Rail 项右方向键 → 焦点移交内容区', (tester) async {
    await pumpShell(tester);

    // 内容占位是 DpadRegion 内的可聚焦节点（shell 持其 FocusNode，Rail 项
    // 的 onDirection(right) 消费按键并请求该节点）。DpadFocusable 的 State
    // 私有，这里经其内部 Focus widget 拿到节点，钉住「内容区可承接焦点」
    // 这一桥接前提（Rail→内容的完整按键链路由真机/集成测试覆盖）。
    final focusWidget = tester.widget<Focus>(
      find
          .descendant(
            of: find.byType(DpadRegion),
            matching: find.byWidgetPredicate(
              // 跳过 DpadRegion 自身的 FocusTraversalGroup（不可获焦），
              // 只取真正的可获焦 Focus（内容占位的 DpadFocusable 内部节点）。
              (w) =>
                  w is Focus &&
                  w.focusNode != null &&
                  w.focusNode!.canRequestFocus,
            ),
          )
          .first,
    );
    final contentNode = focusWidget.focusNode!;
    contentNode.requestFocus();
    await tester.pump();
    expect(contentNode.hasFocus, isTrue, reason: '内容区占位可承接焦点');
  });
}
