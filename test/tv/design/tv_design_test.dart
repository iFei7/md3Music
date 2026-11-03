// 批次43：TV 设计令牌单元测试。
// 覆盖 TvLayoutScale 换算（含 clamp 边界）、TvType 字号表、TvMotion 动效常量、
// TvColors 色板与 TvSafeArea 安全区常量。规范值钉死，防回归。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/tv/design/tv_design.dart';

void main() {
  group('TvLayoutScale 换算', () {
    Future<double> pumpScaleAt(WidgetTester tester, Size logicalSize) async {
      tester.view.physicalSize = logicalSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      double? scale;
      await tester.pumpWidget(
        MaterialApp(
          home: TvLayoutScale(
            child: Builder(builder: (context) {
              scale = TvLayoutScale.of(context);
              return const SizedBox.shrink();
            }),
          ),
        ),
      );
      return scale!;
    }

    testWidgets('800 宽宿主 → clamp 下限 0.5（800/1920≈0.4167 被抬到 0.5）', (
      tester,
    ) async {
      expect(await pumpScaleAt(tester, const Size(800, 600)), 0.5);
    });

    testWidgets('1920 宽 → scale = 1.0', (tester) async {
      expect(await pumpScaleAt(tester, const Size(1920, 1080)), 1.0);
    });

    testWidgets('3840 宽 → clamp 上限 2.0', (tester) async {
      expect(await pumpScaleAt(tester, const Size(3840, 1080)), 2.0);
    });

    testWidgets('px() 按 scale 换算设计 px；不在作用域内兜底 1.0', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      double? converted;
      double? fallback;
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              TvLayoutScale(
                child: Builder(
                  builder: (context) {
                    converted = TvLayoutScale.px(context, 48);
                    return const SizedBox.shrink();
                  },
                ),
              ),
              Builder(
                builder: (context) {
                  fallback = TvLayoutScale.of(context);
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      );
      expect(converted, 48.0); // 1920 宽 → scale 1.0
      expect(fallback, 1.0); // 作用域外兜底
    });
  });

  group('TvType 字号表（design px）', () {
    test('歌名 48 Bold', () {
      final s = TvType.songTitle(1.0);
      expect(s.fontSize, 48);
      expect(s.fontWeight, FontWeight.w700);
    });
    test('当前歌词 42 Medium', () {
      final s = TvType.currentLyric(1.0);
      expect(s.fontSize, 42);
      expect(s.fontWeight, FontWeight.w500);
    });
    test('行标题 32 Bold', () {
      final s = TvType.sectionTitle(1.0);
      expect(s.fontSize, 32);
      expect(s.fontWeight, FontWeight.w700);
    });
    test('导航与普通歌词 26', () {
      final s = TvType.body(1.0);
      expect(s.fontSize, 26);
    });
    test('歌手专辑 24 次要灰', () {
      final s = TvType.subtitle(1.0);
      expect(s.fontSize, 24);
      expect(s.color, TvColors.secondary);
    });
    test('时长 20 Light', () {
      final s = TvType.duration(1.0);
      expect(s.fontSize, 20);
      expect(s.fontWeight, FontWeight.w300);
    });
    test('数量标签 18', () {
      final s = TvType.countLabel(1.0);
      expect(s.fontSize, 18);
    });
    test('scale 参数内乘换算', () {
      expect(TvType.songTitle(2.0).fontSize, 96);
      expect(TvType.subtitle(0.5).fontSize, 12);
    });
  });

  group('TvMotion 动效常量', () {
    test('规范落地值', () {
      expect(TvMotion.bgSwitch, const Duration(milliseconds: 600));
      expect(TvMotion.focus, const Duration(milliseconds: 150));
      expect(TvMotion.controlBarAutoHide, const Duration(milliseconds: 3500));
      expect(TvMotion.controlBarFade, const Duration(milliseconds: 600));
      expect(TvMotion.lyricsScroll, const Duration(milliseconds: 300));
      expect(TvMotion.vinylRevolution, const Duration(seconds: 18));
    });
  });

  group('TvColors 色板', () {
    test('规范落地值（基底非纯黑）', () {
      expect(TvColors.base, const Color(0xFF08090C));
      expect(TvColors.white, const Color(0xFFFFFFFF));
      expect(TvColors.secondary, const Color(0xFF8E929E));
      expect(TvColors.disabled, const Color(0xFF4E515A));
      expect(TvColors.track, const Color(0xFF2A2D37));
    });
  });

  group('TvSafeArea 安全区', () {
    test('5% 比例与 1080p 安全区边界', () {
      expect(TvSafeArea.kTvSafeFraction, 0.05);
      expect(TvSafeArea.designWidth, 1920);
      expect(TvSafeArea.designHeight, 1080);
      expect(TvSafeArea.safeLeft, 96);
      expect(TvSafeArea.safeTop, 96);
      expect(TvSafeArea.safeRight, 1824);
      expect(TvSafeArea.safeBottom, 984);
    });
  });
}
