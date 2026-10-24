import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/utils/landscape_dock_side.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 批次36：悬浮 Dock 左右位置（`settings_landscape_dock_side`）持久化测试。
///
/// 用户口径：「支持设置选择悬浮 dock 在左在右（在哪哪边内容就要避让）。」
/// 默认必须为 right = 改造前（批次35 起）的右侧纵条行为；历史脏值 /
/// 手改配置不得让启动崩溃，一律回落 right。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('landscapeDockSide', () {
    test('未写入时默认 right（= 改造前右侧纵条行为）', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      expect(await repo.getLandscapeDockSide(), LandscapeDockSide.right);
    });

    test('setLandscapeDockSide(left) 后可回读 left', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.setLandscapeDockSide(LandscapeDockSide.left);
      expect(await repo.getLandscapeDockSide(), LandscapeDockSide.left);
    });

    test('往返切换 right ↔ left 均正确，键名与存储值符合约定', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();

      await repo.setLandscapeDockSide(LandscapeDockSide.left);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('settings_landscape_dock_side'), 'left');

      await repo.setLandscapeDockSide(LandscapeDockSide.right);
      expect(await repo.getLandscapeDockSide(), LandscapeDockSide.right);
      expect(prefs.getString('settings_landscape_dock_side'), 'right');
    });

    test('未知 / 脏值回落 right', () async {
      SharedPreferences.setMockInitialValues({
        'settings_landscape_dock_side': 'up',
      });
      final repo = SettingsRepository();
      expect(await repo.getLandscapeDockSide(), LandscapeDockSide.right);
    });

    test('fromStorage 对 null / 空串回落 right，对合法值原样解析', () {
      expect(LandscapeDockSide.fromStorage(null), LandscapeDockSide.right);
      expect(LandscapeDockSide.fromStorage(''), LandscapeDockSide.right);
      expect(LandscapeDockSide.fromStorage('left'), LandscapeDockSide.left);
      expect(LandscapeDockSide.fromStorage('right'), LandscapeDockSide.right);
    });
  });
}
