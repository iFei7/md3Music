import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/modules/settings/settings_search_index.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 批次 3 新增设置项回归：
/// - Dock 展开胶囊「左右滑切歌」开关（批次 5 起默认开）
/// - 设置搜索索引与新增/迁移条目同步（左右滑切歌 / 开发者子页）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dock 左右滑切歌开关', () {
    test('默认开启（批次 5 由默认关改为默认开）', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await SettingsRepository().getDockSwipeToSwitchTrack(),
        isTrue,
      );
      expect(SettingsRepository.dockSwipeToSwitchTrack.value, isTrue);
    });

    test('可写入并读回', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.setDockSwipeToSwitchTrack(true);
      expect(await repo.getDockSwipeToSwitchTrack(), isTrue);
      // 写入即同步内存缓存：Dock 拖拽松手判定同步读取该值
      expect(SettingsRepository.dockSwipeToSwitchTrack.value, isTrue);
      await repo.setDockSwipeToSwitchTrack(false);
      expect(SettingsRepository.dockSwipeToSwitchTrack.value, isFalse);
    });

    test('持久化 key 为 settings_dock_swipe_to_switch_track', () async {
      SharedPreferences.setMockInitialValues({});
      await SettingsRepository().setDockSwipeToSwitchTrack(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings_dock_swipe_to_switch_track'), isTrue);
    });
  });

  group('设置搜索索引（批次 3 同步）', () {
    test('左右滑切歌可检索且归属播放行为子页', () {
      final entry = kSettingsSearchIndex.firstWhere(
        (e) => e.label == '左右滑切歌',
      );
      expect(entry.category, '播放');
      expect(entry.subpage, '播放行为');
      expect(entry.aliases, contains('切歌'));
    });

    test('本地数据接口 / 数据迁移已迁入开发者子页', () {
      for (final label in ['本地数据接口', '数据迁移（修复数据混乱）']) {
        final entry = kSettingsSearchIndex.firstWhere((e) => e.label == label);
        expect(entry.category, '缓存与数据');
        expect(entry.subpage, '开发者');
      }
      // 开发者子页自身条目存在，搜索直达三级页
      expect(
        kSettingsSearchIndex.where((e) => e.subpage == '开发者').length,
        greaterThanOrEqualTo(3),
      );
    });
  });
}
