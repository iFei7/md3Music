import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:md3music/tv_ui/core/layout/responsive_layout.dart';
import 'package:md3music/tv_ui/core/services/desktop_lyric_service.dart';
import 'package:md3music/tv_ui/data/repositories/settings_repository.dart';
import 'package:md3music/tv_ui/providers/car_mode_provider.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/tv_ui/providers/cloud_upload_provider.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/shortcut_config_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/tv_ui/utils/landscape_immersive.dart';
import 'package:md3music/tv_ui/services/depth_cover_service.dart';
import 'package:md3music/tv_ui/modules/player/mini_player.dart';
import 'package:md3music/tv_ui/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:md3music/tv_ui/widgets/md3_lyric_preferences.dart';
import 'package:md3music/tv_ui/widgets/player_seek_bar.dart';
import 'package:md3music/tv_ui/widgets/player_top_bar_actions.dart';
import 'package:md3music/tv_ui/widgets/player_top_bar_tab_dots.dart';
import 'package:md3music/tv_ui/modules/coverflow/coverflow_source.dart';
import 'package:md3music/tv_ui/modules/mcp/mcp_service.dart';
import 'package:md3music/tv_ui/modules/player/player_cover_shadow.dart';
import 'package:md3music/tv_ui/compat/compat_library_comment.dart';
import 'package:md3music/tv_ui/compat/compat_player_provider.dart';
import 'package:md3music/tv_ui/compat/compat_theme_provider.dart';

/// 在布局可能因还原而销毁设置页之前，捕获需要同步的运行态。
/// 只由 Windows 的还原入口调用，不改变其它平台的设置加载和存储方式。
class WindowsSettingsRuntime {
  WindowsSettingsRuntime.capture(BuildContext context)
    : theme = context.read<ThemeProvider>(),
      device = context.read<DeviceProvider?>(),
      car = context.read<CarModeProvider?>(),
      tabs = context.read<TabConfigProvider?>(),
      shortcuts = context.read<ShortcutConfigProvider?>(),
      player = context.read<PlayerProvider?>(),
      mcp = context.read<McpService?>(),
      gridColumns = context.read<GridColumnsProvider?>(),
      commentDisplay = context.read<CommentDisplayProvider?>(),
      cloudUpload = context.read<CloudUploadProvider?>(),
      library = context.read<LibraryProvider?>();

  final ThemeProvider theme;
  final DeviceProvider? device;
  final CarModeProvider? car;
  final TabConfigProvider? tabs;
  final ShortcutConfigProvider? shortcuts;
  final PlayerProvider? player;
  final McpService? mcp;
  final GridColumnsProvider? gridColumns;
  final CommentDisplayProvider? commentDisplay;
  final CloudUploadProvider? cloudUpload;
  final LibraryProvider? library;

  Future<void> reset() async {
    if (!Platform.isWindows) return;
    // 启动读取/迁移必须先完成，否则它们可能在清空后重新写回旧配置。
    await Future.wait<void>([
      theme.windowsSettingsReady,
      if (device != null) device!.settingsReady,
      if (car != null) car!.settingsReady,
      if (tabs != null) tabs!.settingsReady,
      if (shortcuts != null) shortcuts!.settingsReady,
      if (player != null) player!.audioReady,
      if (mcp != null) mcp!.settingsReady,
      if (gridColumns != null) gridColumns!.settingsReady,
      if (commentDisplay != null) commentDisplay!.settingsReady,
      LyricPreferences.instance.load(),
      Md3LyricPreferences.instance.load(),
    ]);
    library?.prepareWindowsSettingsReset();
    cloudUpload?.prepareWindowsSettingsReset();
    final repo = SettingsRepository();
    await repo.resetAllSettingsToDefaults();
    await theme.reloadWindowsSettings();
    await device?.reloadWindowsSettings();
    await car?.reloadWindowsSettings();
    await tabs?.resetToDefault();
    await shortcuts?.resetToDefault();
    await LyricPreferences.instance.reset();
    await Md3LyricPreferences.instance.reset();
    await player?.reloadWindowsSettings();
    await mcp?.reloadWindowsSettings();
    await gridColumns?.reloadWindowsSettings();
    await commentDisplay?.reloadWindowsSettings();
    await cloudUpload?.reloadWindowsSettings();
    await library?.reloadWindowsSettings();
    await DesktopLyricService.instance.reloadWindowsSettings();

    kWindowsTwoPaneEnabled.value = await repo.getWindowsTwoPaneEnabled();
    kDesktopModeEnabled.value = await repo.getDesktopModeEnabled();
    kSecondaryPlayerEnabled.value = await repo.getSecondaryPlayerEnabled();
    kSecondaryPlayerProgressEnabled.value = await repo
        .getSecondaryPlayerProgress();
    kSecondaryPlayerOpacity.value = await repo.getSecondaryPlayerOpacity();
    kSecondaryPlayerOnPrimaryPages.value = await repo
        .getSecondaryPlayerOnPrimary();
    kHideNavBarOnSecondaryPages.value = await repo
        .getHideNavBarOnSecondaryPages();
    final isPad =
        device?.deviceType == DeviceType.pad ||
        (device?.deviceType != DeviceType.phone &&
            WidgetsBinding
                        .instance
                        .platformDispatcher
                        .views
                        .first
                        .physicalSize
                        .shortestSide /
                    WidgetsBinding
                        .instance
                        .platformDispatcher
                        .views
                        .first
                        .devicePixelRatio >=
                600);
    kSecondaryPlayerDock.value =
        SecondaryPlayerDockSide.tryParse(
          await repo.getSecondaryPlayerDockRaw(),
        ) ??
        (isPad
            ? SecondaryPlayerDockSide.right
            : SecondaryPlayerDockSide.center);
    SettingsRepository.lyricTimeOffsetMs.value = await repo
        .getLyricTimeOffset();
    kLandscapeImmersiveEnabled = await repo.getLandscapeImmersiveEnabled();
    DepthCoverService.enabledSignal.value = await repo.getDepthCoverEnabled();
    miniPlayerSwipeSwitchEnabled.value = await repo
        .getMiniPlayerSwipeSwitchEnabled();
    kSeekBarWaveEnabled.value = await repo.getSeekBarWaveEnabled();
    kCoverShadowIntensity.value = await repo.getCoverShadowStrength();
    kLandscapeDetachedControlsEnabled.value = await repo
        .getLandscapeDetachedControls();
    kSymmetricWidePaneEnabled.value = await repo.getSymmetricWidePane();
    kWidePaneMarginOverride.value = await repo.getWidePaneMargin();
    kWidePaneIgnoreCutoutEnabled.value = await repo.getWidePaneIgnoreCutout();
    kTopBarPillCollapseEnabled.value = await repo.getTopBarPillCollapse();
    kTopBarTabDotsEnabled.value = await repo.getTopBarTabDots();
    kPlaylistCoverTransitionEnabled.value = await repo
        .getPlaylistCoverTransitionEnabled();
    kCoverFlowSource.value = CoverFlowSource.tryParse(
      await repo.getCoverFlowSourceRaw(),
    );
    SettingsRepository.windowsLiveSettingsRevision.value++;
  }
}
