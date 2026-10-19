import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/providers/player_provider.dart';

/// 「上传听歌时长」开关（用户批次14：修复「本地听歌时长未上传」）。
///
/// 覆盖两组回归：
/// 1. 开关默认值：`settings_upload_listening_duration` 未存值时默认**开启**
///    （根因①：默认关闭导致用户不手动开则零上报）；已存偏好优先于默认值
///    （老用户手动关过的保持关闭）。
/// 2. 累计门禁：PlayerProvider 推给听歌等级服务的 playingOnline 放宽为
///    「播放中（不分音源）」——本地文件播放也累计（根因②）。
///
/// 说明：ListeningGradeService 是 Android-only 单例（心跳定时器仅主
/// isolate 创建、字段私有无观察 seam），测试环境无法驱动其累计逻辑，
/// 故链路 A 的「开关默认开启时累计」在本文件中退化为对 settings 默认值
/// + PlayerProvider 门禁传参的断言（批次14 交付报告已说明取舍）。
Song _song({required bool isOnline}) => Song(
  id: isOnline ? 'kugouhash' : '/sdcard/Music/a.flac',
  title: 't',
  artist: 'a',
  album: 'b',
  duration: const Duration(seconds: 10),
  isOnline: isOnline,
);

void main() {
  group('settings_upload_listening_duration 默认值', () {
    test('未设置过时默认开启（修复「本地听歌时长未上传」根因①）', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await SettingsRepository().getUploadListeningDuration(),
        isTrue,
        reason: '默认关闭时用户不手动开则零上报，故默认改为开启',
      );
    });

    test('已存偏好优先于默认值：老用户手动关过的仍为 false', () async {
      SharedPreferences.setMockInitialValues({
        'settings_upload_listening_duration': false,
      });
      expect(
        await SettingsRepository().getUploadListeningDuration(),
        isFalse,
        reason: 'prefs 已存值优先于默认值，尊重老用户的关闭选择',
      );
    });

    test('写入后可读回', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.setUploadListeningDuration(false);
      expect(await repo.getUploadListeningDuration(), isFalse);
      await repo.setUploadListeningDuration(true);
      expect(await repo.getUploadListeningDuration(), isTrue);
    });
  });

  group('听歌等级累计门禁（用户批次14：播放中即累计，不分音源）', () {
    test('本地歌曲播放中 → 累计（修复根因②：本地时长不再被丢弃）', () {
      expect(
        PlayerProvider.shouldAccumulateListeningDuration(
          currentSong: _song(isOnline: false),
          isPlaying: true,
        ),
        isTrue,
        reason: '本地文件听歌时长也计入等级时长上报（用户批次14要求）',
      );
    });

    test('在线歌曲播放中 → 累计（与原语义一致）', () {
      expect(
        PlayerProvider.shouldAccumulateListeningDuration(
          currentSong: _song(isOnline: true),
          isPlaying: true,
        ),
        isTrue,
      );
    });

    test('暂停中（不分音源）→ 不累计', () {
      expect(
        PlayerProvider.shouldAccumulateListeningDuration(
          currentSong: _song(isOnline: false),
          isPlaying: false,
        ),
        isFalse,
        reason: '暂停不计入，与音源无关',
      );
      expect(
        PlayerProvider.shouldAccumulateListeningDuration(
          currentSong: _song(isOnline: true),
          isPlaying: false,
        ),
        isFalse,
      );
    });
  });
}
