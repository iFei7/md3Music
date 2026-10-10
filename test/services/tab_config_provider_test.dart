import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/providers/tab_config_provider.dart';

/// 主页 Tab 默认配置测试。
///
/// 需求：默认 Tab 顺序为 发现(discover) → 收藏(favorites) →
/// 本地音乐(library) → 我的(user)；其余可选 Tab 默认隐藏。
void main() {
  testWidgets('全新安装：默认 Tab 为 发现/收藏/本地音乐/我的，其余可选隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump(); // 等待异步 _load 完成
    await tester.pump();

    // 可见 Tab 顺序：发现 → 收藏 → 本地音乐 → 我的
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'library', 'user'],
      reason: '默认 Tab 顺序应为 发现/收藏/本地音乐/我的',
    );
    // 可选 Tab（搜索/听歌识曲/设置）默认隐藏
    expect(
      provider.hiddenTabs,
      containsAll(['search', 'recognition', 'settings']),
      reason: '搜索/听歌识曲/设置 默认隐藏',
    );
    expect(provider.hiddenTabs, isNot(contains('library')));
    // 听书 / LaunchPad 已下线 tab 入口，不再出现在任何 tab 列表
    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('audiobook')),
      reason: '听书 tab 入口已下线（入口迁移至「我的」页）',
    );
    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('launchpad')),
      reason: 'LaunchPad tab 已下线',
    );
  });

  testWidgets('重置默认：恢复 发现/收藏/本地音乐/我的，其余可选隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 先把收藏手动隐藏，再重置，应恢复为显示
    await provider.toggleTabVisibility('favorites');
    expect(provider.hiddenTabs.contains('favorites'), isTrue, reason: '前置：收藏已手动隐藏');

    await provider.resetToDefault();
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'library', 'user'],
      reason: '重置后默认 Tab 顺序应为 发现/收藏/本地音乐/我的',
    );
    expect(
      provider.hiddenTabs,
      containsAll(['search', 'recognition', 'settings']),
      reason: '重置后可选 Tab 默认隐藏',
    );
  });

  testWidgets('升级迁移：清理旧版本遗留的收藏和本地音乐隐藏状态', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_tab_order': ['discover', 'favorites', 'launchpad', 'library', 'user'],
      'settings_hidden_tabs': ['favorites', 'library', 'fm'],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    expect(provider.visibleIndexOf('favorites'), greaterThanOrEqualTo(0));
    expect(provider.visibleIndexOf('library'), greaterThanOrEqualTo(0));
    expect(provider.hiddenTabs, isNot(contains('favorites')));
    expect(provider.hiddenTabs, isNot(contains('library')));
  });

  testWidgets('旧版本持久化顺序中的已下线 tab（launchpad/audiobook）被过滤', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_tab_order': [
        'discover',
        'favorites',
        'launchpad',
        'library',
        'audiobook',
        'user',
      ],
      'settings_hidden_tabs': <String>[],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('launchpad')),
      reason: 'LaunchPad tab 不应从持久化顺序中恢复',
    );
    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('audiobook')),
      reason: '听书 tab 不应从持久化顺序中恢复',
    );
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'library', 'user'],
      reason: '可见 tab 应只剩默认四项',
    );
  });
}
