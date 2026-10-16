import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';

void main() {
  group('预设种子色重排（sonify 红 #F54047 置索引 0）', () {
    test('索引 0 = sonify 红，且为默认种子色', () {
      expect(AppTheme.presetSeedColors.first, const Color(0xFFF54047));
      expect(AppTheme.defaultSeedColor, const Color(0xFFF54047));
    });

    test('原 8 色全部保留（降序为备选，无丢失）', () {
      const originals = [
        Color(0xFF0061A4), // 蓝（原默认）
        Color(0xFF6750A4), // 紫
        Color(0xFF006A6A), // 青绿
        Color(0xFF386A20), // 绿
        Color(0xFF7E5700), // 黄
        Color(0xFF8C4A00), // 橙
        Color(0xFFB3261E), // 红
        Color(0xFF984061), // 粉
      ];
      for (final c in originals) {
        expect(AppTheme.presetSeedColors.contains(c), isTrue,
            reason: '原预设色 ${c.toARGB32()} 应保留');
      }
      expect(AppTheme.presetSeedColors.length, originals.length + 1);
    });

    test('sonifyPrimaryDark = #E64366（Color.kt:9）', () {
      expect(AppTheme.sonifyPrimaryDark, const Color(0xFFE64366));
    });
  });

  group('SonifyColors 语义槽位（0.3 色板表）', () {
    test('浅色槽位对齐 sonify 浅色取值', () {
      final colors = SonifyColors.fromScheme(
        ColorScheme.fromSeed(seedColor: AppTheme.defaultSeedColor),
        isLight: true,
      );
      expect(colors.background, const Color(0xFFFFFFFF)); // Color.kt:12
      expect(colors.onBackground, const Color(0xFF000000)); // Theme.kt:23
      expect(colors.textSecondary, const Color(0xFF88878E)); // Color.kt:10
      expect(colors.surfaceGroup, const Color(0xFFF2F1F6)); // Color.kt:15
      expect(colors.surfaceCard, const Color(0xFFFFFFFF)); // Color.kt:17
      expect(colors.scrim, Colors.black.withValues(alpha: 0.5));
    });

    test('深色槽位对齐 sonify 深色取值', () {
      final colors = SonifyColors.fromScheme(
        ColorScheme.fromSeed(seedColor: AppTheme.defaultSeedColor),
        isLight: false,
      );
      expect(colors.background, const Color(0xFF000000)); // Color.kt:13
      expect(colors.onBackground, const Color(0xFFFFFFFF)); // Theme.kt:33
      expect(colors.textSecondary, const Color(0xFF8E8D93)); // Color.kt:11
      expect(colors.surfaceGroup, const Color(0xFF000002)); // Color.kt:16
      expect(colors.surfaceCard, const Color(0xFF1C1C1E)); // Color.kt:18
      expect(colors.scrim, Colors.white.withValues(alpha: 0.5));
    });

    test('primary 跟随种子色（自定义种子色全 app 生效的兼容语义）', () {
      final seed = const Color(0xFF123456);
      final scheme = ColorScheme.fromSeed(seedColor: seed);
      expect(
        SonifyColors.fromScheme(scheme, isLight: true).primary,
        scheme.primary,
      );
    });

    test('注册进 AppTheme.lightTheme / darkTheme 的 extensions', () {
      expect(AppTheme.lightTheme.extension<SonifyColors>(), isNotNull);
      expect(AppTheme.darkTheme.extension<SonifyColors>(), isNotNull);
      expect(AppTheme.darkTheme.extension<SonifyColors>()!.background,
          const Color(0xFF000000));
    });

    testWidgets('of() 在未注册主题（裸 ThemeData）下按亮度兜底', (tester) async {
      late SonifyColors caught;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Builder(
            builder: (context) {
              caught = SonifyColors.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(caught.background, const Color(0xFF000000));
      expect(caught.surfaceCard, const Color(0xFF1C1C1E));
    });

    test('lerp / copyWith 基本行为', () {
      final a = SonifyColors.fromScheme(
          ColorScheme.fromSeed(seedColor: AppTheme.defaultSeedColor),
          isLight: true);
      final b = SonifyColors.fromScheme(
          ColorScheme.fromSeed(seedColor: AppTheme.defaultSeedColor),
          isLight: false);
      final mid = a.lerp(b, 0.5);
      expect(
        mid.surfaceCard.toARGB32(),
        Color.lerp(a.surfaceCard, b.surfaceCard, 0.5)!.toARGB32(),
      );
      expect(a.copyWith(textSecondary: const Color(0xFF111111)).textSecondary,
          const Color(0xFF111111));
    });
  });

  group('SonifyTextStyles（0.3 排印表）', () {
    test('textLargeTitle：20sp Bold lineHeight 36（与 36dp 头像等高）', () {
      const s = SonifyTextStyles.largeTitle;
      expect(s.fontSize, 20);
      expect(s.fontWeight, FontWeight.w700);
      expect(s.height, 36 / 20);
    });

    test('textBarTitle：18.5sp Bold（Title.kt:1063-1067）', () {
      const s = SonifyTextStyles.barTitle;
      expect(s.fontSize, 18.5);
      expect(s.fontWeight, FontWeight.w700);
    });

    test('textBody：16sp lh21 ls0.0618（Type.kt:9-14）', () {
      const s = SonifyTextStyles.body;
      expect(s.fontSize, 16);
      expect(s.height, 21 / 16);
      expect(s.letterSpacing, 0.0618);
    });

    test('textListItem 13sp / textCardTitle 16 Medium / textSectionTitle 18 Bold',
        () {
      expect(SonifyTextStyles.listItem.fontSize, 13);
      expect(SonifyTextStyles.cardTitle.fontSize, 16);
      expect(SonifyTextStyles.cardTitle.fontWeight, FontWeight.w500);
      expect(SonifyTextStyles.sectionTitle.fontSize, 18);
      expect(SonifyTextStyles.sectionTitle.fontWeight, FontWeight.w700);
    });

    test('排印样式不写死颜色与字体族（跟随主题/自定义字体）', () {
      for (final s in [
        SonifyTextStyles.largeTitle,
        SonifyTextStyles.barTitle,
        SonifyTextStyles.body,
        SonifyTextStyles.listItem,
        SonifyTextStyles.cardTitle,
        SonifyTextStyles.sectionTitle,
      ]) {
        expect(s.color, isNull);
        expect(s.fontFamily, isNull);
      }
    });
  });

  group('SonifySpacing / SonifyMotion（0.3 间距与动效表）', () {
    test('间距 token 取值', () {
      expect(SonifySpacing.cardMargin, 16.5); // YosRoundColumn.kt:22
      expect(SonifySpacing.titleMargin, 20); // Title.kt:203
      expect(SonifySpacing.groupMargin, 32); // Title.kt:202
      expect(SonifySpacing.gridH, 15); // Title.kt:416-417
      expect(SonifySpacing.gridV, 20);
      expect(SonifySpacing.gridEdge, 18); // Title.kt:419-420
      expect(SonifySpacing.topBar, 54); // Title.kt:989
      expect(SonifySpacing.coverRailMin, 150); // AdaptiveImageLayout.kt:9
    });

    test('动效 token 取值', () {
      expect(SonifyMotion.barFade, const Duration(milliseconds: 120));
      expect(SonifyMotion.glassAlpha, const Duration(milliseconds: 150));
    });
  });
}
