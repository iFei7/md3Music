import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_offload_status.dart';

void main() {
  // 批次45：硬解真实状态回传的 Dart 侧解析。
  group('AudioOffloadStatus.fromMap 真值表', () {
    test('offloaded=true / sleeping=false → 硬解生效但主循环未停摆', () {
      final status = AudioOffloadStatus.fromMap({
        'offloaded': true,
        'sleeping': false,
      });
      expect(status, isNotNull);
      expect(status!.offloaded, isTrue);
      expect(status.sleepingForOffload, isFalse);
    });

    test('offloaded=false / sleeping=true → 未 offload 但已在省电调度', () {
      final status = AudioOffloadStatus.fromMap({
        'offloaded': false,
        'sleeping': true,
      });
      expect(status, isNotNull);
      expect(status!.offloaded, isFalse);
      expect(status.sleepingForOffload, isTrue);
    });

    test('空 Map（缺键）→ 两字段默认 false，且不抛异常', () {
      // 缺键按 false 处理：Java 侧固定发两个键，缺键只可能是协议裁剪，
      // 此时另一字段仍可信，所以不整条丢弃。
      final status = AudioOffloadStatus.fromMap(<String, dynamic>{});
      expect(status, isNotNull);
      expect(status!.offloaded, isFalse);
      expect(status.sleepingForOffload, isFalse);
    });

    test('null → null（未知，不是软解）', () {
      expect(AudioOffloadStatus.fromMap(null), isNull);
    });

    test('非 Map（字符串 "junk"）→ null', () {
      expect(AudioOffloadStatus.fromMap('junk'), isNull);
    });

    test('类型错 {offloaded:"yes"} → 整条丢弃返回 null（不做安全降级）', () {
      // 选择「整条丢弃」而不是「把坏字段当 false」的理由：
      // 类型不符说明载荷不是我们理解的协议，此时若把另一字段当真，
      // 会把 offloaded 静默变成 false，UI 显示"确认软解"——这比"未知"
      // 错得更严重（用户会据此关掉硬解开关）。整条丢弃则保持上一个已知值。
      expect(
        AudioOffloadStatus.fromMap({'offloaded': 'yes', 'sleeping': false}),
        isNull,
      );
      expect(
        AudioOffloadStatus.fromMap({'offloaded': true, 'sleeping': 1}),
        isNull,
      );
    });

    test('值相等 → == / hashCode 一致，toString 含两个字段', () {
      const a = AudioOffloadStatus(offloaded: true, sleepingForOffload: false);
      const b = AudioOffloadStatus(offloaded: true, sleepingForOffload: false);
      const c = AudioOffloadStatus(offloaded: true, sleepingForOffload: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.toString(), contains('offloaded: true'));
      expect(a.toString(), contains('sleepingForOffload: false'));
    });
  });

  group('AudioOffloadStatusService', () {
    final service = AudioOffloadStatusService.instance;

    setUp(() {
      // 单例的 ValueNotifier 会跨用例污染，逐条复位到「未知」。
      service.status.value = null;
    });

    tearDown(() {
      service.status.value = null;
      service.stop();
    });

    test('instance 是单例', () {
      expect(identical(service, AudioOffloadStatusService.instance), isTrue);
    });

    test('初始状态为 null（未知，UI 不能显示成软解）', () {
      expect(service.status.value, isNull);
    });

    test('收到事件后 status.value 更新', () {
      service.handleMessageForTest({'offloaded': true, 'sleeping': true});
      expect(
        service.status.value,
        const AudioOffloadStatus(offloaded: true, sleepingForOffload: true),
      );

      // 同一首歌内状态可能来回变（例如从播放切到暂停后 sleeping 回落）。
      service.handleMessageForTest({'offloaded': true, 'sleeping': false});
      expect(
        service.status.value,
        const AudioOffloadStatus(
          offloaded: true,
          sleepingForOffload: false,
        ),
      );
    });

    test('畸形消息不覆盖上一个已知值', () {
      service.handleMessageForTest({'offloaded': true, 'sleeping': false});
      service.handleMessageForTest('junk');
      expect(
        service.status.value,
        const AudioOffloadStatus(
          offloaded: true,
          sleepingForOffload: false,
        ),
      );
      service.handleMessageForTest(null);
      expect(service.status.value, isNotNull);
    });

    test('start 在测试环境（非 Android）不注册、也不抛', () {
      // 测试宿主是 host 平台，start() 应直接 return，不触碰通道。
      expect(() => service.start(), returnsNormally);
      expect(() => service.stop(), returnsNormally);
    });
  });
}
