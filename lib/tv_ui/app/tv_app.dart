// 批次51：纯 TV 应用入口（上游 rust-local-force lib/app.dart 的 TV 装配形态
// 全量迁移）。用户决策：①TV 构建完全使用上游 Md3Music UI，彻底去除 TV 版
// 自定义 UI/接线；②TV 构建断开手机 UI 可达性（纯 TV 入口，手机 Dart 从 TV
// 包 AOT 剔除）。本文件由 main.dart 的 kTvBuild 分支 runApp（main.dart 批次51
// 段），app.dart 退役全部 kTvBuild 接线、恢复纯手机形态。
//
// 本文件的 import 闭包**不含任何手机 UI**（不 import lib/app.dart、不 import
// lib/modules/**、不 import lib/widgets/** 的手机页面）：数据层/服务层复用
// lite（providers / core/theme / core/utils / services / main.dart 的
// appNavigatorKey），渲染层全部取 lib/tv_ui/（上游 UI 体系）。依赖方向
// tv_ui → lite 数据层与批次50 既有约定一致；手机 UI（app.dart 的页面闭包）
// 不可达 —— TV AOT 包里手机 10 万行 Dart 由 main.dart 的 const 分支消除
// 剔除（kTvBuild=true 时 runApp(TvApp()) 之后的手机装配整段不可达）。
//
// 装配链（与上游 app.dart 对齐的来源行号标注在各段）：
//   TvApp（上游 MyApp :213-232 形态，TV-only）
//     → MultiProvider（lite providers 全量 + TV-only providers，
//        上游 :235-352 对应物；RemoteControlProvider 对应上游 :244-247）
//     → _TvAppView → MaterialApp（theme 取 lite AppTheme，路由表取上游
//        :1047-1057 TV 消费面，onGenerateRoute '/' → _UpFadeMainRoute）
//     → builder（上游 :928-993 的 TV 形态）：DisplayScaleScope →
//       SafeInsetsGuard → Stack[AppBackground, MaterialUiCompatibilityBridge(
//       _tvMediaKeyFallback(_tvContentScope(...))), DlnaCastingOverlay]
//     → home _TvMainLayout（上游 _MainLayout :1294+ 的 TV 等价物）：
//       根 PopScope 返回链 + TvMainShell + ResponsiveShell + 页面映射。
library;

import 'dart:async';
import 'package:dpad/dpad.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/build_flags.dart' show kTvMinTextScale;
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/core/utils/artwork_color_extractor.dart';
import 'package:md3music/main.dart' show appNavigatorKey;
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/dlna_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/shortcut_config_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_server.dart';
import 'package:md3music/tv_ui/core/layout/responsive_shell.dart';
import 'package:md3music/tv_ui/core/layout/tv_shell.dart' show TvMainShell;
import 'package:md3music/tv_ui/core/layout/ui_density.dart'
    show
        DisplayScaleScope,
        kDefaultDisplayScale,
        kMaxSystemTextScale;
import 'package:md3music/tv_ui/core/remote/tv_exit_confirm_dialog.dart'
    show TvExitAction, showTvExitConfirmDialog;
import 'package:md3music/tv_ui/core/remote/tv_focus_highlight.dart'
    show TvFocusHighlight, TvFocusHighlightState;
import 'package:md3music/tv_ui/core/remote/tv_ime_guard.dart' show TvImeGuard;
import 'package:md3music/tv_ui/core/remote/tv_ime_proxy_bridge.dart'
    show TvImeProxyBridge;
import 'package:md3music/tv_ui/core/remote/tv_key_repeat.dart'
    show TvKeyRepeatLayer;
import 'package:md3music/tv_ui/core/remote/tv_player_back_focus.dart'
    show TvPlayerBackFallback;
import 'package:md3music/tv_ui/core/widgets/app_background.dart';
import 'package:md3music/tv_ui/core/widgets/safe_insets_guard.dart';
import 'package:md3music/tv_ui/modules/audiobook/audiobook_page.dart';
import 'package:md3music/tv_ui/modules/discover/discover_page.dart';
import 'package:md3music/tv_ui/modules/library/library_page.dart';
import 'package:md3music/tv_ui/modules/personal_fm/personal_fm_page.dart';
import 'package:md3music/tv_ui/modules/player/full_player.dart';
import 'package:md3music/tv_ui/modules/player/full_player_route.dart'
    show isFullPlayerOnTop, playerDragActive, playerExpansion;
import 'package:md3music/tv_ui/modules/playlist/playlist_page.dart'
    show PlaylistPage;
import 'package:md3music/tv_ui/modules/recognition/song_recognition_page.dart';
import 'package:md3music/tv_ui/modules/search/search_page.dart';
import 'package:md3music/tv_ui/modules/settings/settings_page.dart';
import 'package:md3music/tv_ui/modules/user/favorites_page.dart';
import 'package:md3music/tv_ui/modules/user/play_history_page.dart';
import 'package:md3music/tv_ui/modules/user/user_center_page.dart';
import 'package:md3music/tv_ui/providers/blacklist_provider.dart';
import 'package:md3music/tv_ui/providers/car_mode_provider.dart';
import 'package:md3music/tv_ui/providers/cloud_upload_provider.dart';
import 'package:md3music/tv_ui/providers/listen_stats_provider.dart';
import 'package:md3music/tv_ui/providers/listen_together_provider.dart';
import 'package:md3music/tv_ui/providers/local_listen_stats_provider.dart';
import 'package:md3music/tv_ui/providers/remote_control_provider.dart';
import 'package:md3music/tv_ui/providers/song_match_provider.dart';
import 'package:md3music/tv_ui/widgets/app_animation.dart' show ContentEntrance;
import 'package:md3music/tv_ui/widgets/dlna_casting_overlay.dart';
import 'package:md3music/data/models/playlist.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

/// 主页（`/`）专用的 [MaterialPageRoute] 子类（上游 app.dart :164-211 原样
/// 搬运，playerExpansion 取 tv_ui full_player_route.dart :26 同名量）。
///
/// 重写 [buildTransitions]：当 FullPlayer 在栈顶（[playerExpansion] > 0.5）
/// 且 [secondaryAnimation] 驱动时，让主页向上偏移 15% + 淡出（Apple Music
/// 经典效果）；其他路由 push 时走默认 transitions。
class _UpFadeMainRoute<T> extends MaterialPageRoute<T> {
  _UpFadeMainRoute({required super.builder});

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 入场动画走默认（主页是 initialRoute，入场无动画）
    // 离场动画（被覆盖）：监听 playerExpansion，> 0.5 时 up-fade，否则默认
    return AnimatedBuilder(
      animation: Listenable.merge([secondaryAnimation, playerExpansion]),
      builder: (context, _) {
        if (playerExpansion.value <= 0.5) {
          return super.buildTransitions(
            context,
            animation,
            secondaryAnimation,
            child,
          );
        }
        // FullPlayer 在栈顶：主页向上偏移 15% + 淡出
        final offset =
            Tween<Offset>(
              begin: Offset.zero,
              end: const Offset(0, -0.15),
            ).animate(
              CurvedAnimation(
                parent: secondaryAnimation,
                curve: Curves.easeOutCubic,
              ),
            );
        final fade = Tween<double>(begin: 1.0, end: 0.0).animate(
          CurvedAnimation(
            parent: secondaryAnimation,
            curve: Curves.easeOutCubic,
          ),
        );
        return FadeTransition(
          opacity: fade,
          child: SlideTransition(position: offset, child: child),
        );
      },
    );
  }
}

/// 纯 TV 应用入口（批次51）。
///
/// 上游 `MyApp`（rust-local-force lib/app.dart :213-232）的 TV-only 等价物：
/// MultiProvider 装配 → [_TvAppView]（MaterialApp + builder 焦点包装）。
/// 无 onboarding / 用户协议路由——TV 构建为纯 TV 入口，不引入手机 UI 页面
/// （协议页/引导页属手机 UI 闭包，TV 包不可达，见文件头可达性说明）。
class TvApp extends StatelessWidget {
  const TvApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 上游 app.dart :235-352 MultiProvider 的 lite 对应物：
    // - lite providers 全量（与手机 MyApp 同一套数据层，tv_ui 经 compat 消费，
    //   批次50 已验证签名兼容）；
    // - TV-only providers（lite 无对应类，取 tv_ui 版本）：
    //   RemoteControlProvider（上游 :244-247 位置）+ 上游 :287-349 的
    //   SongMatch / CloudUpload / Blacklist / ListenStats /
    //   LocalListenStats / CarMode / ListenTogether。
    // - 上游 :249-286 的 MusicHapticsService listener 与 McpService：lite
    //   无对应物（MusicHapticsService 精简移除 / TV 无 MCP），不装配。
    return MultiProvider(
      providers: <SingleChildWidget>[
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        // TV 构建：遥控器模式总开关（上游 :244-247 原位对应）。
        ChangeNotifierProvider(create: (_) => RemoteControlProvider()),
        ChangeNotifierProvider(create: (_) => GridColumnsProvider()),
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => KugouProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        // 跨页面广播「收藏的歌单」变更（详情页 → 我的收藏 tab 立即刷新）
        ChangeNotifierProvider(create: (_) => PlaylistCollectionNotifier()),
        // 主页 Tab 配置（显示/隐藏、排序）
        ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        // 桌面快捷方式配置（Android 长按图标入口的显示/隐藏、排序）
        ChangeNotifierProvider(create: (_) => ShortcutConfigProvider()),
        // DLNA 投屏
        ChangeNotifierProvider(create: (_) => DlnaProvider()),
        // 评论显示设置（字号等）
        ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
        // 本地歌曲 ↔ 在线歌曲匹配（上游 :339-340）
        ChangeNotifierProvider(create: (_) => SongMatchProvider()),
        // 车机模式（上游 :341-342）
        ChangeNotifierProvider(create: (_) => CarModeProvider()),
        // 云盘上传队列：应用级常驻，页面退出不中断上传（上游 :287-289）
        ChangeNotifierProvider(create: (_) => CloudUploadProvider()),
        // 内容黑名单（上游 :291-302）：登录态/账号变化时清空缓存，
        // 防止跨账号串状态；黑名单接口按 token/userid 作用域，缓存不能跨
        // 会话复用。
        ChangeNotifierProxyProvider<KugouProvider, BlacklistProvider>(
          create: (_) => BlacklistProvider(),
          update: (_, kugou, blacklist) {
            blacklist!.syncLoginState(
              loggedIn: kugou.isLoggedIn,
              userid: kugou.userid,
            );
            return blacklist;
          },
        ),
        // 云端听歌统计（上游 :303-314）：按 token/userid 作用域，登录态/
        // 账号变化时清空缓存防跨账号串状态。
        ChangeNotifierProxyProvider<KugouProvider, ListenStatsProvider>(
          create: (_) => ListenStatsProvider(),
          update: (_, kugou, stats) {
            stats!.syncLoginState(
              loggedIn: kugou.isLoggedIn,
              userid: kugou.userid,
            );
            return stats;
          },
        ),
        // 本地听歌统计（上游 :315-326）：按登录态/账号作用域，账号变化时
        // 清缓存，防止跨账号串状态。
        ChangeNotifierProxyProvider<KugouProvider, LocalListenStatsProvider>(
          create: (_) => LocalListenStatsProvider(),
          update: (_, kugou, stats) {
            stats!.syncLoginState(
              loggedIn: kugou.isLoggedIn,
              userid: kugou.userid,
            );
            return stats;
          },
        ),
        // 一起听（众乐房）：广场列表 + 房间会话（上游 :348-349）
        ChangeNotifierProvider(create: (_) => ListenTogetherProvider()),
      ],
      child: const _TvAppView(),
    );
  }
}

/// TvApp 的 MaterialApp 宿主（上游 _MAppView 的 TV 形态）。
///
/// 持有封面动态取色桥接（上游 _MainLayout :580-598 同款——上游把它放在
/// _MainLayout，这里放 MaterialApp 宿主层，行为一致：监听 PlayerProvider
/// 切歌 → 提取封面主色 → 注入 ThemeProvider）。
class _TvAppView extends StatefulWidget {
  const _TvAppView();

  @override
  State<_TvAppView> createState() => _TvAppViewState();
}

class _TvAppViewState extends State<_TvAppView> {
  // 封面动态取色桥接：监听 PlayerProvider 切歌 → 提取封面主色 → 注入
  // ThemeProvider（上游 _MainLayout :580-598）。持有引用以便 dispose 时移除
  // listener（provider 销毁顺序晚于本 State）。
  PlayerProvider? _playerProvider;
  // 上一次已提取/正在提取的封面 url：同一首歌反复 notify 不重复提取，
  // 且异步提取期间切歌时丢弃过期结果（上游 _lastCoverUrl 同款）。
  String? _lastCoverUrl;

  // tv: 焦点红框的唤醒入口（上游 _MAppView :399 同款）。播放列表「自动滚到
  // 当前曲」等程序化滚动不触发 FocusManager 通知，静音后的 Ticker 不会跟随，
  // 红框会滞留旧位置；由 [_tvContentScope] 的 NotificationListener 唤醒。
  final GlobalKey<TvFocusHighlightState> _tvFocusFrameKey =
      GlobalKey<TvFocusHighlightState>();

  @override
  void initState() {
    super.initState();
    // 延迟一帧再建立封面取色桥接：ChangeNotifierProvider 惰性 create，
    // 此时 provider 实例已就绪，且不影响首帧渲染（lite _AppView 同款时序）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupCoverColorBridge();
    });
  }

  /// 建立封面动态取色桥接（上游 _MainLayout :581-587 原样搬运）。
  void _setupCoverColorBridge() {
    final player = context.read<PlayerProvider>();
    _playerProvider = player;
    player.addListener(_onPlayerChanged);
    // 启动时按当前歌曲提取一次（若 App 有恢复播放）
    _onPlayerChanged();
  }

  /// 切歌回调：当前歌曲封面 url 变化时异步提取主色并注入 ThemeProvider
  /// （上游 :590-598 原样搬运）。
  Future<void> _onPlayerChanged() async {
    final url = context.read<PlayerProvider>().currentSong?.artworkUri;
    if (url == null || url == _lastCoverUrl) return;
    _lastCoverUrl = url;
    final color = await ArtworkColorExtractor.extract(url);
    // 过期校验：提取期间已切歌则丢弃结果（参考 AM 歌词动态取色模式）
    if (context.read<PlayerProvider>().currentSong?.artworkUri != url) return;
    context.read<ThemeProvider>().setCoverSeedColor(color);
  }

  @override
  void dispose() {
    _playerProvider?.removeListener(_onPlayerChanged);
    super.dispose();
  }

  /// TV 返回键收口（上游 app.dart :675-683 原样搬运）。能 pop 则 pop
  /// （返回 true 表示已消费）；根路由返回 false 交回系统默认 —— 由
  /// [_TvMainLayout] 根 [PopScope] 走退出流程（回首页 → TV 退出确认菜单）。
  ///
  /// **pop 之前先询问播放页**（上游 2026-10-20 真机补的兜底）：播放页内的
  /// TvPlayerBackInterceptor 靠「焦点节点 → ancestors 向上」收按键，焦点
  /// 一旦丢回路由自己的 FocusScope（primaryFocus 变成 _ModalScopeState
  /// Focus Scope）它就收不到了，返回键会直接把播放页 pop 掉 —— 用户看到的
  /// 是「焦点在列表上按返回键，播放页直接关了」。这里先让播放页把焦点交还
  /// 播放键并消费这次返回（tv_ui FullPlayer 自带拦截器装配）；它没救（不在
  /// 播放页 / 焦点已在控制区）才真正 pop。
  bool _handleTvBack() {
    if (TvPlayerBackFallback.instance.requestPlayFocus()) return true;
    final navigator = appNavigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return true;
    }
    return false;
  }

  /// tv: TV 构建下的内容子树作用域（上游 app.dart :707-773 原版实现照抄，
  /// 仅 TvApp builder 调用；lite app.dart 批次43 自写适配版随批次51 退役）。
  /// 由外到内四层：
  ///
  /// 1. [TvImeProxyBridge]：输入法会话桥。把「输入框是否持焦」
  ///    (kTextInputFocused) 转发给原生代理 View (TvImeProxyView)，让低内存
  ///    Android TV（config_preventImeStartupUnlessTextEditor=true，Flutter
  ///    #177360）肯给本窗口绑定输入法会话——否则遥控器按键一个都到不了软
  ///    键盘，无法选字。lite 无原生代理端时 invokeMethod 失败被 catchError
  ///    静默吞掉（增强失败即退回原行为），无害。
  /// 2. [MediaQuery]：正文缩放下限 [kTvMinTextScale]（10-foot 可读性）。
  ///    上游 [DisplayScaleScope] 已把系统字体缩放钉在
  ///    [1.0, kMaxSystemTextScale]，本层在其结果上再抬下限 → 有效区间
  ///    [1.15, 1.30]。必须在 Builder 内取继承的 MediaQuery（拿到的是显示
  ///    大小缩放后的数据），copyWith 只改 textScaler、其余字段原样透传。
  /// 3. [Dpad.wrap]：dpad 遍历引擎（onBack 收口到 [_handleTvBack]；焦点
  ///    视觉只保留自绘 [TvFocusHighlight] 描边框，effects 传空列表，不叠加
  ///    dpad 自带辉光，避免与描边不同步/遮细线）。
  /// 4. [TvImeGuard] + [TvKeyRepeatLayer]：输入法保活守卫包在 Dpad 之内、
  ///    连发层之外——输入框持焦时把四方向键就地吃掉，防止 dpad「单行输入框
  ///    上下键=移出字段」的逃逸把 TextField 挤失焦、连带收起系统输入法
  ///    （退出输入框靠 BACK）；连发层再往内。
  ///
  /// [TvFocusHighlight] 以 Positioned.fill 叠在最上层（IgnorePointer 不拦
  /// 按键），替代 dpad 的 debugOverlay（整体开关、release 自动关闭）；滚动
  /// 通知经 NotificationListener 唤醒静音中的红框 Ticker。
  Widget _tvContentScope(BuildContext context, Widget? child) {
    return TvImeProxyBridge(
      child: Builder(
        builder: (mqContext) {
          final mq = MediaQuery.of(mqContext);
          return MediaQuery(
            data: mq.copyWith(
              textScaler: mq.textScaler.clamp(
                minScaleFactor: kTvMinTextScale,
                maxScaleFactor: kMaxSystemTextScale,
              ),
            ),
            child: Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: (_) {
                    _tvFocusFrameKey.currentState?.wake();
                    return false;
                  },
                  child: Dpad.wrap(
                    theme: const DpadThemeData(
                      effects: <DpadEffect>[],
                      scrollPadding: 64,
                    ),
                    onBack: _handleTvBack,
                  )(
                    mqContext,
                    TvImeGuard(
                      child: TvKeyRepeatLayer(
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: TvFocusHighlight(key: _tvFocusFrameKey),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// tv: 遥控媒体键兜底（上游 app.dart :780-794 原样搬运）。播放中的媒体键
  /// 正常由前台 media3 会话消费，不会走到这里；本层覆盖「无活跃会话 / 媒体
  /// 通知 controller 未连接」时按键落到 Activity 窗口、进入 Flutter 按键
  /// 管线的情形。播放控制方法与上游同源（_playerProvider 复用封面取色桥接
  /// 的引用，上游 :796-835）。
  Widget _tvMediaKeyFallback(Widget child) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
            _tvMediaTogglePlay,
        const SingleActivator(LogicalKeyboardKey.mediaPlay): _tvMediaPlay,
        const SingleActivator(LogicalKeyboardKey.mediaPause): _tvMediaPause,
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
            _tvMediaSkip(next: true),
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
            _tvMediaSkip(next: false),
      },
      child: child,
    );
  }

  void _tvMediaTogglePlay() {
    final p = _playerProvider;
    if (p == null || p.currentSong == null) return;
    debugPrint('[TvMediaKey] playPause isPlaying=${p.isPlaying}');
    // ignore: discarded_futures
    p.isPlaying ? p.pause() : p.resume();
  }

  void _tvMediaPlay() {
    final p = _playerProvider;
    if (p == null || p.currentSong == null) return;
    if (p.isPlaying) return;
    debugPrint('[TvMediaKey] play');
    // ignore: discarded_futures
    p.resume();
  }

  void _tvMediaPause() {
    final p = _playerProvider;
    if (p == null || p.currentSong == null) return;
    if (!p.isPlaying) return;
    debugPrint('[TvMediaKey] pause');
    // ignore: discarded_futures
    p.pause();
  }

  void _tvMediaSkip({required bool next}) {
    final p = _playerProvider;
    if (p == null || p.currentSong == null) return;
    debugPrint('[TvMediaKey] skip ${next ? 'next' : 'previous'}');
    // ignore: discarded_futures
    if (next) {
      p.next();
    } else {
      p.previous();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    return MaterialApp(
      title: 'Grace Music',
      debugShowCheckedModeBanner: false,
      // theme/darkTheme/themeMode 与手机 MyApp 同构（lite AppTheme + lite
      // ThemeProvider，任务口径「与 lite 对齐」；上游 :866-926 的 displayScale/
      // fontFamily 等参数为上游 ThemeProvider 专属，lite 侧无此体系）。
      theme: AppTheme.lightThemeFromSeed(
        themeProvider.effectiveSeedColor,
        labelBehavior: themeProvider.navLabelBehavior,
      ),
      darkTheme: AppTheme.darkThemeFromSeed(
        themeProvider.effectiveSeedColor,
        useOledBlack: themeProvider.useOledBlack,
        labelBehavior: themeProvider.navLabelBehavior,
      ),
      themeMode: themeProvider.themeMode,
      builder: (context, child) {
        // 全局「显示大小」：档位恒默认 1.0（与手机 builder 同构，上游 :935-937
        // 的 DisplayScaleScope 挂点）。TV 无 MCP 宿主层（上游 McpConfirmationDialogHost
        // :934 为上游 MCP 体系专属，lite 无对应物）与 WindowsWindowFrame
        // （上游 :941-946 Windows 背景层，TV 是 Android 平台不进入）。
        return DisplayScaleScope(
          scale: kDefaultDisplayScale,
          child: SafeInsetsGuard(
            child: Stack(
              children: [
                // 全局背景层（主页/底层背景）：tv_ui AppBackground（上游
                // :949 同点挂载）。二级页面由路由过渡内嵌 AppBackground。
                Positioned.fill(child: AppBackground()),
                // material_ui 兼容桥（上游 :961-963 + lite builder 同款）：
                // 第三方包仍 import package:flutter/material.dart，其
                // Theme.of 取不到 material_ui 主题，本桥补发。
                MaterialUiCompatibilityBridge(
                  // 批次51：TV 在 Navigator 之外叠加媒体键兜底 + TV 内容
                  // 作用域（上游 :984-988 kTvBuild 分支的恒真形态——本文件
                  // 整体只在 TV 构建装配，无需 kTvBuild 判断）。
                  child: _tvMediaKeyFallback(
                    _tvContentScope(context, child),
                  ),
                ),
                const DlnaCastingOverlay(),
              ],
            ),
          ),
        );
      },
      navigatorKey: appNavigatorKey,
      // 路由表 = 上游 :1047-1057 的 TV 消费面（页面全部换 tv_ui 版）。
      routes: {
        '/search': (_) => const SearchPage(),
        '/library': (_) => const LibraryPage(),
        '/settings': (_) => const SettingsPage(),
        // 发现页右上角头像点击跳转入口（上游 :1053-1054）
        '/user': (_) => const UserCenterPage(),
        '/player': (_) => const FullPlayer(),
        '/personal_fm': (_) => const PersonalFmPage(),
      },
      onGenerateRoute: (settings) {
        // '/' 不在 routes 注册，改在 onGenerateRoute 用 _UpFadeMainRoute
        // 创建，以便 push FullPlayer 时主页面向上淡出（仅 FullPlayer 生效，
        // 上游 :1048-1049 同款）。TV 主入口的播放页打开走顶栏 MiniPlayer
        // OK → tv_ui openFullPlayer（full_player_route.dart :402，自带防
        // 重复入栈与可拖拽路由），本命名路由保留给既有 '/player' 调用点。
        if (settings.name == '/') {
          return _UpFadeMainRoute<void>(builder: (_) => const _TvMainLayout());
        }
        if (settings.name == '/playlist') {
          // 歌单详情（tv_ui PlaylistPage；上游 :1090-1098 同款 FadeTransition）。
          final playlist = settings.arguments as Playlist;
          return PageRouteBuilder(
            pageBuilder: (_, _, _) => PlaylistPage(playlist: playlist),
            transitionsBuilder: (_, animation, _, child) {
              return FadeTransition(opacity: animation, child: child);
            },
          );
        }
        return null;
      },
    );
  }
}

/// TV 主布局（上游 app.dart `_MainLayout` :1294+ 的 TV 等价物，批次51）。
///
/// 保留 TV 构建实际消费的骨架：选中 tab 状态、根返回链（PopScope →
/// [_dispatchBack]）、壳层装配（TvMainShell + ResponsiveShell）与页面映射。
/// 上游桌面壳层/底栏形态交棒/沉浸同步/退出动画等手机桌面专属机制不在 TV
/// 装配面内，不搬运。
class _TvMainLayout extends StatefulWidget {
  const _TvMainLayout();

  @override
  State<_TvMainLayout> createState() => _TvMainLayoutState();
}

class _TvMainLayoutState extends State<_TvMainLayout> {
  int _selectedIndex = 0;
  final _responsiveShellKey = GlobalKey<ResponsiveShellState>();

  /// tv: 退出确认菜单防重入（返回键在根路由连按不会叠出多个对话框；
  /// lite app.dart 批次43 同款字段，随迁移进入 TvApp）。
  bool _tvExitDialogShowing = false;

  /// 统一「返回」链路（上游 app.dart :3045-3092 `_dispatchBack` 的 TV 等价
  /// 收口，桌面/沉浸/退出动画分支不在 TV 装配面内）：
  /// 上滑拖拽展开中 → 根栈顶页 → 当前 Tab 的壳层栈 → 回首页 → TV 退出确认。
  /// [allowExitAtRoot] 到根页面时才起作用。
  Future<bool> _dispatchBack({required bool allowExitAtRoot}) async {
    // 上滑拖拽展开中：返回键先收起覆盖层，回到 MiniPlayer。
    if (playerDragActive.value) {
      playerDragActive.value = false;
      playerExpansion.value = 0.0;
      return true;
    }
    final NavigatorState? rootNav = appNavigatorKey.currentState;
    // 根栈上还盖着别的页面（完整播放页等）：交给它自己的返回语义。播放页
    // 的 PopScope 已排好「退 Zen → 退出编辑 → 收起播放页」的优先级。
    // 判据只能是 canPop：本 State 的 route 是根栈第一条，canPop=false 时
    // 说明顶栏就是它，才继续往壳层走。
    if (rootNav != null && rootNav.canPop()) {
      // ignore: discarded_futures
      await rootNav.maybePop();
      return true;
    }
    if (await _responsiveShellKey.currentState?.maybePop() ?? false) {
      return true;
    }
    if (!mounted) return false;
    if (_selectedIndex != 0) {
      // 主导航页面先返回首页，只有首页继续执行 TV 退出确认。
      debugPrint('[MainNavigation] back tab=$_selectedIndex -> home');
      setState(() => _selectedIndex = 0);
      return true;
    }
    if (!allowExitAtRoot) return false;
    _onTvBackAtRoot();
    return true;
  }

  /// TV 根路由返回：弹退出确认三选一菜单（上游 `_onBackPressedForExit`
  /// :3618-3623 的 kTvBuild 分支语义）。
  ///
  /// - cancel：留在 App；
  /// - background：挂后台（lite `_doExit` 语义：flushPersistence + 原生
  ///   `moveToBack` 通道，异常兜底 SystemNavigator.pop）；
  /// - exitApp：停本地 Rust 服务（lite 有 [KugouApiServer.stop]）后结束
  ///   任务回桌面。lite 无上游 `stopForAppExit` 媒体会话收尾链路（TV 真机
  ///   遗留项：退出后 media3 通知由系统会话收口），以 SystemNavigator.pop
  ///   由引擎走标准 Activity.finish 收尾。
  Future<void> _onTvBackAtRoot() async {
    if (_tvExitDialogShowing) return;
    final dialogContext = appNavigatorKey.currentContext;
    if (dialogContext == null) return;
    _tvExitDialogShowing = true;
    try {
      final TvExitAction action =
          await showTvExitConfirmDialog(dialogContext);
      if (!mounted) return;
      switch (action) {
        case TvExitAction.cancel:
        case TvExitAction.background:
          // 挂后台：不杀进程、不停播放器、不停本地 Rust 服务器（lite
          // _doExit 同款；批次43 注释占位的后台化在此落地）。
          try {
            await context.read<PlayerProvider>().flushPersistence();
          } catch (_) {}
          try {
            await const MethodChannel(
              'com.md3music.md3music/task',
            ).invokeMethod<void>('moveToBack');
          } catch (_) {
            await SystemNavigator.pop();
          }
          break;
        case TvExitAction.exitApp:
          // 停本地服务（幂等，失败继续退出）→ 结束任务回桌面。
          try {
            await KugouApiServer.stop();
          } catch (_) {}
          await SystemNavigator.pop();
          break;
      }
    } finally {
      _tvExitDialogShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabConfig = context.watch<TabConfigProvider>();
    final visibleTabs = tabConfig.visibleTabs;

    // 安全守卫：如果当前选中索引超出可见 tab 范围，重置到最后一个
    // （上游 :2853-2857 同款）。
    if (_selectedIndex >= visibleTabs.length) {
      _selectedIndex = visibleTabs.length - 1;
      if (_selectedIndex < 0) _selectedIndex = 0;
    }

    // 一级页面返回拦截（上游 :2899-2905 PopScope 形态）：系统返回手势 /
    // 物理返回键到根 PopScope，允许走到 TV 退出确认菜单，不允许一下退出。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        // ignore: discarded_futures
        await _dispatchBack(allowExitAtRoot: true);
      },
      // 壳层选择（上游 :2946-2963 kTvBuild 分支的恒真形态）：TV 版主壳层
      // ——顶部双层导航（tv_shell.dart：第一层账号胶囊 / MiniPlayer / 搜索
      // 钮，第二层横向 tab「聚焦即选中」，item 体系 = 上游 TvTabBarItem，
      // 由 TvMainShell 内部经 railDestinations 图标构造）。
      child: TvMainShell(
        visibleTabs: visibleTabs,
        selectedIndex: _selectedIndex,
        railDestinations:
            visibleTabs.map(_buildTvRailDestination).toList(),
        onDestinationSelected: (index) {
          // 守卫同上游 :2954-2955：FullPlayer 在栈顶时（展开进度 > 0.5）
          // 忽略 tab 切换，避免与播放页转场叠加导致状态混乱。
          if (isFullPlayerOnTop) return;
          setState(() {
            _selectedIndex = index;
          });
        },
        shellKey: _responsiveShellKey,
        body: _buildTvBody(context, visibleTabs),
      ),
    );
  }

  /// tv: TV 构建的 body（上游 app.dart :3533-3551 `_buildBody` kTvBuild
  /// 分支原样形态）。
  ///
  /// Column[Expanded(ResponsiveShell)]。不传 persistentBarBuilder——底部
  /// 常驻条已随 MiniPlayer 移顶退场（tv_shell.dart），每 tab 再挂一条会与
  /// 顶栏重复，并触发 residentRect 多点并发结算；onSecondaryRouteChanged /
  /// onPageRouteEvent 上游用于底栏形态交棒，TV 构建该体系整段惰性（上游
  /// :3174 kTvBuild 钉死），不传（null）。本地 API 故障只写后台诊断日志并
  /// 由服务层自动重试（上游 :3532 注释同款语义），不摆横幅。
  Widget _buildTvBody(BuildContext context, List<TabItem> visibleTabs) {
    return Column(
      children: [
        Expanded(
          child: ResponsiveShell(
            key: _responsiveShellKey,
            visibleTabs: visibleTabs,
            selectedIndex: _selectedIndex,
            pageBuilder: _buildTvPageForTab,
          ),
        ),
      ],
    );
  }

  /// 根据 tab id 构建对应页面 Widget（上游 app.dart :1456-1529
  /// `_buildPageForTab` 的 lite 值域版）。
  ///
  /// 统一在 tab 页外层包 ContentEntrance：向上淡入滑动（上游 :1457-1460
  /// 同款注释）。映射域 = lite [kAllAvailableTabs] 的 9 个 tab id（上游
  /// launchpad/coverflow/charts/ip/scene/channel/sheet/brush/
  /// listen_together 等 tab 不在 lite TabConfigProvider 值域内，不注册）；
  /// 「歌单/专辑/歌手」类 lite 历史子 tab id（持久化残留，v7 起被剔除回写）
  /// 落 tv_ui FavoritesPage/LibraryPage 对应页。默认 SizedBox.shrink()
  /// （上游 :1525-1526 同款）。
  Widget _buildTvPageForTab(String tabId) {
    Widget page;
    switch (tabId) {
      case 'discover':
        page = const DiscoverPage();
        break;
      case 'library':
        page = const LibraryPage();
        break;
      case 'favorites':
        page = const FavoritesPage();
        break;
      case 'recent':
        page = const PlayHistoryPage();
        break;
      case 'fm':
        page = const PersonalFmPage();
        break;
      case 'search':
        page = const SearchPage();
        break;
      case 'recognition':
        page = const SongRecognitionPage();
        break;
      case 'audiobook':
        page = const AudiobookPage();
        break;
      case 'settings':
        page = const SettingsPage();
        break;
      // lite 历史子 tab id（歌单/专辑/歌手/文件夹/本地收藏，v7 起不再下发，
      // 持久化残留防御性映射；tv_ui 页无 initialTab 参数，落默认页签）。
      case 'playlists':
      case 'albums':
      case 'artists':
        page = const FavoritesPage();
        break;
      case 'folders':
      case 'local_favorites':
        page = const LibraryPage();
        break;
      default:
        page = const SizedBox.shrink();
    }
    return ContentEntrance(child: page);
  }

  /// tv: TV 构建的 rail 目标（上游 app.dart :1711-1832
  /// `_buildRailDestination` 的 lite 值域版）。
  ///
  /// TvMainShell 第二层 tab 项只消费 icon/selectedIcon（label 直接取
  /// visibleTabs[i].label，见 tv_shell.dart `_buildTabItem`）；图标映射取
  /// 上游同 id 档位（discover=explore / library=library_music / favorites=
  /// favorite / fm=radio / search=search / recognition=mic_none /
  /// audiobook=auto_stories / settings=settings），'recent' 为 lite 独有
  /// id（上游无），取 history 档；其余防御性映射落上游 default 圆点档。
  NavigationRailDestination _buildTvRailDestination(TabItem tab) {
    final label = Text(tab.label);
    switch (tab.id) {
      case 'discover':
        return NavigationRailDestination(
          icon: const Icon(Icons.explore_outlined),
          selectedIcon: const Icon(Icons.explore),
          label: label,
        );
      case 'library':
        return NavigationRailDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music),
          label: label,
        );
      case 'favorites':
        return NavigationRailDestination(
          icon: const Icon(Icons.favorite_outline),
          selectedIcon: const Icon(Icons.favorite),
          label: label,
        );
      case 'fm':
        return NavigationRailDestination(
          icon: const Icon(Icons.radio_outlined),
          selectedIcon: const Icon(Icons.radio),
          label: label,
        );
      case 'search':
        return NavigationRailDestination(
          icon: const Icon(Icons.search_outlined),
          selectedIcon: const Icon(Icons.search),
          label: label,
        );
      case 'recognition':
        return NavigationRailDestination(
          icon: const Icon(Icons.mic_none_outlined),
          selectedIcon: const Icon(Icons.mic),
          label: label,
        );
      case 'audiobook':
        return NavigationRailDestination(
          icon: const Icon(Icons.auto_stories_outlined),
          selectedIcon: const Icon(Icons.auto_stories),
          label: label,
        );
      case 'settings':
        return NavigationRailDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: label,
        );
      case 'recent':
        // lite 独有 tab id（上游无此档），取「最近播放」语义图标。
        return NavigationRailDestination(
          icon: const Icon(Icons.history_outlined),
          selectedIcon: const Icon(Icons.history),
          label: label,
        );
      default:
        return NavigationRailDestination(
          icon: const Icon(Icons.circle_outlined),
          selectedIcon: const Icon(Icons.circle),
          label: label,
        );
    }
  }
}
