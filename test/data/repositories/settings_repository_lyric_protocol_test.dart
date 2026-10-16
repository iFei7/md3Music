import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricInfo 推送通道恒定关闭的回归测试。
///
/// 背景：协议键历史上存在 fork 默认值 'lyric_info'（静默底层恒推），
/// 用户明确要求始终关闭 LyricInfo 后：
/// - 新装/无残留：协议默认 'none'；
/// - 旧版安装残留 'lyric_info'：按 'none' 处理，不得启用任何通道；
/// - 'super_lyric'：正常回读（SuperLyric 通道行为不变）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('getLyricPushProtocol', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('未写入协议键时默认 none（不再回落 lyric_info）', () async {
      final repo = SettingsRepository();
      expect(await repo.getLyricPushProtocol(), 'none');
    });

    test('旧版安装残留 lyric_info 按 none 处理', () async {
      SharedPreferences.setMockInitialValues({
        'lyric_push_protocol': 'lyric_info',
      });
      final repo = SettingsRepository();
      expect(await repo.getLyricPushProtocol(), 'none');
    });

    test('super_lyric 正常回读', () async {
      SharedPreferences.setMockInitialValues({
        'lyric_push_protocol': 'super_lyric',
      });
      final repo = SettingsRepository();
      expect(await repo.getLyricPushProtocol(), 'super_lyric');
    });

    test('none 与未知值均按 none 处理', () async {
      SharedPreferences.setMockInitialValues({
        'lyric_push_protocol': 'none',
      });
      final repo = SettingsRepository();
      expect(await repo.getLyricPushProtocol(), 'none');

      SharedPreferences.setMockInitialValues({
        'lyric_push_protocol': 'unknown_protocol',
      });
      expect(await repo.getLyricPushProtocol(), 'none');
    });

    test('setLyricPushProtocol 写入后可回读', () async {
      final repo = SettingsRepository();
      await repo.setLyricPushProtocol('super_lyric');
      expect(await repo.getLyricPushProtocol(), 'super_lyric');
      await repo.setLyricPushProtocol('none');
      expect(await repo.getLyricPushProtocol(), 'none');
    });
  });
}
