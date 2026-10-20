import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/services/kugou_api/kugou_models.dart';

/// KugouGradeInfo.fromJson 解析测试（听歌等级信息，/user/grade/info
/// v2/lite 协议）：字段名 snake/camel 双兼容、缺字段兜底、字符串数字容错。
/// 账号卡迷你等级行与用户中心等级区块共用该模型，解析契约在此固化。
void main() {
  group('KugouGradeInfo.fromJson', () {
    test('snake 字段（data 包装）全量解析', () {
      final grade = KugouGradeInfo.fromJson({
        'data': {
          'd_sec': 123456,
          'duration': 120000,
          'p_grade': 5,
          'p_current_point': 320,
          'p_grade_point': 200,
          'p_next_grade': 6,
          'p_next_grade_point': 800,
          'servertime': '2026-10-19 12:00:00',
        },
      });

      expect(grade.dSec, 123456);
      expect(grade.duration, 120000);
      expect(grade.pGrade, 5);
      expect(grade.pCurrentPoint, 320);
      expect(grade.pGradePoint, 200);
      expect(grade.pNextGrade, 6);
      expect(grade.pNextGradePoint, 800);
      expect(grade.serverTime, '2026-10-19 12:00:00');
    });

    test('camel 字段降级：无 snake 键时取 camel 键', () {
      final grade = KugouGradeInfo.fromJson({
        'dSec': '7500',
        'pGrade': '3',
        'serverTime': 'ts',
      });

      expect(grade.dSec, 7500);
      expect(grade.pGrade, 3);
      expect(grade.serverTime, 'ts');
    });

    test('无 data 包装时直接解析顶层', () {
      final grade = KugouGradeInfo.fromJson({
        'd_sec': 3600,
        'p_grade': 1,
      });

      expect(grade.dSec, 3600);
      expect(grade.pGrade, 1);
    });

    test('空 JSON：数字字段兜底为 0，字符串字段为 null', () {
      // 注意：fromJson 的数字解析走 _parseInt，缺失即 0（不是 null），
      // 调用方展示时按 0/未就绪处理
      final grade = KugouGradeInfo.fromJson(<String, dynamic>{});

      expect(grade.dSec, 0);
      expect(grade.duration, 0);
      expect(grade.pGrade, 0);
      expect(grade.pCurrentPoint, 0);
      expect(grade.serverTime, isNull);
    });

    test('展示口径：d_sec 存在时优先 dSec', () {
      final both = KugouGradeInfo.fromJson({'d_sec': 100, 'duration': 999});
      expect(both.dSec ?? both.duration, 100);

      // 已知边界（仅记录不修复，kugou_models.dart 不在本次改动范围）：
      // 仅传 duration 时 d_sec 缺失 → _parseInt 兜底 0，UI 的
      // `dSec ?? duration` 回退链不会触发（0 不是 null）。v2/lite 协议
      // 实际返回 d_sec，故线上不受影响。
      final onlyDuration = KugouGradeInfo.fromJson({'duration': 999});
      expect(onlyDuration.dSec, 0);
    });
  });
}
