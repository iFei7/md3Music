import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_offload_config.dart';

/// 批次45：设置页硬解状态说明文案的纯函数覆盖。
///
/// 五个分支的语义边界（顺序即判定优先级）：
/// 1. 开关关闭 → 直接说软解，不看上报状态；
/// 2. 开关开 + offloaded == null（还没收到事件）+ 未播放 → 「未播放」；
/// 3. 开关开 + offloaded == null + 正在播 → 「正在起播」（还在等首条事件）；
/// 4. offloaded == true → 硬解，sleeping 决定是否带低功耗后缀；
/// 5. offloaded == false → **确认**软解（Media3 每次建 AudioTrack 都会回调，
///    所以 false 是可信结论，不是未知）。
void main() {
  group('AudioOffloadConfig.describePlaybackState', () {
    test('开关关闭时固定提示软解（即使 offloaded 为 true 也不看）', () {
      expect(
        AudioOffloadConfig.describePlaybackState(
          offloaded: null,
          sleeping: false,
          isPlaying: false,
          switchEnabled: false,
        ),
        '开关已关闭，当前使用软件解码',
      );
      // 防御性断言：关闭状态下上报值不参与文案。
      expect(
        AudioOffloadConfig.describePlaybackState(
          offloaded: true,
          sleeping: true,
          isPlaying: true,
          switchEnabled: false,
        ),
        '开关已关闭，当前使用软件解码',
      );
    });

    test('开关开、未知状态、未播放 → 未播放提示', () {
      expect(
        AudioOffloadConfig.describePlaybackState(
          offloaded: null,
          sleeping: false,
          isPlaying: false,
          switchEnabled: true,
        ),
        '未播放，起播后可查看实际解码方式',
      );
    });

    test('开关开、未知状态、正在播 → 正在起播提示', () {
      expect(
        AudioOffloadConfig.describePlaybackState(
          offloaded: null,
          sleeping: false,
          isPlaying: true,
          switchEnabled: true,
        ),
        '正在起播，等待确认解码方式',
      );
    });

    test('硬解生效 → 硬解中；停摆时带低功耗后缀', () {
      expect(
        AudioOffloadConfig.describePlaybackState(
          offloaded: true,
          sleeping: false,
          isPlaying: true,
          switchEnabled: true,
        ),
        '硬解中',
      );
      expect(
        AudioOffloadConfig.describePlaybackState(
          offloaded: true,
          sleeping: true,
          isPlaying: true,
          switchEnabled: true,
        ),
        '硬解中（已进入低功耗停摆）',
      );
    });

    test('确认软解（offloaded == false）→ 软解中', () {
      expect(
        AudioOffloadConfig.describePlaybackState(
          offloaded: false,
          sleeping: false,
          isPlaying: true,
          switchEnabled: true,
        ),
        '软解中（设备或格式不支持硬解）',
      );
      // sleeping 为 true 但 offloaded 为 false 时仍按软解描述：
      // 停摆标记只在硬解生效时才有意义（避免输出矛盾文案）。
      expect(
        AudioOffloadConfig.describePlaybackState(
          offloaded: false,
          sleeping: true,
          isPlaying: true,
          switchEnabled: true,
        ),
        '软解中（设备或格式不支持硬解）',
      );
    });
  });

  // 批次46：硬解与音效互斥联动（纯函数）
  group('AudioOffloadConfig.dspConflictsForOffload', () {
    test('三项全关 → 空列表（无需联动）', () {
      expect(
        AudioOffloadConfig.dspConflictsForOffload(
            viper: false, equalizer: false, normalization: false),
        isEmpty,
      );
    });
    test('仅均衡器 → 只含均衡器', () {
      expect(
        AudioOffloadConfig.dspConflictsForOffload(
            viper: false, equalizer: true, normalization: false),
        ['均衡器'],
      );
    });
    test('仅蝰蛇 → 只含蝰蛇母带', () {
      expect(
        AudioOffloadConfig.dspConflictsForOffload(
            viper: true, equalizer: false, normalization: false),
        ['蝰蛇母带'],
      );
    });
    test('仅音量均衡 → 只含音量均衡', () {
      expect(
        AudioOffloadConfig.dspConflictsForOffload(
            viper: false, equalizer: false, normalization: true),
        ['音量均衡'],
      );
    });
    test('三项全开 → 顺序固定：均衡器、蝰蛇母带、音量均衡', () {
      expect(
        AudioOffloadConfig.dspConflictsForOffload(
            viper: true, equalizer: true, normalization: true),
        ['均衡器', '蝰蛇母带', '音量均衡'],
      );
    });
  });
}
