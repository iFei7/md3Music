import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../modules/login/login_page.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/tab_config_provider.dart';
import '../../tv/design/tv_design.dart';
import '../../widgets/common/glass_circle_button.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../build_flags.dart';
import '../remote/tv_player_bar_focus_bridge.dart';
import '../remote/tv_top_chrome_scope.dart';
import '../utils/app_haptics.dart';
import 'tv_nav_focus_bridge.dart';

/// tv: TV 主壳层顶栏（批次44）——移植上游（origin/rust-local-force）
/// 「顶栏双层 chrome + 真实 tab 内容」结构，废弃批次43 的左侧玻璃 Rail
/// （TvMainShell/TvMainShellHost，真机不可用）。
///
/// ## 结构（需求：tab 换到顶栏，上游双层形态 + lite 玻璃语言）
///
/// 1. **第一层**：账号头像胶囊（左，KugouProvider 登录态）/ 迷你播放条
///    [TvMiniBar]（中，弹性宽）/ 搜索按钮（右）。整层 [DpadRegion]：
///    左右在三者间移动（stop），下键经 [TvNavFocusBridge] 落第二层当前 tab。
/// 2. **第二层**：横向 tab 栏（[TabConfigProvider.visibleTabs] + 设置固定
///    追加）。聚焦即选中（参照上游 TvTabBarItem 语义：焦点切换即选中，
///    无需 OK）；下键进内容区第一可聚焦点，上键经
///    [TvPlayerBarFocusBridge] 回迷你条。
///
/// 整条 chrome 以 [LiquidGlassSurface] 承载（手机端半透明模糊玻璃语言，
/// blur σ 经 [tvBlurSigma] 钳制），两层高度经 [TvLayoutScale] 按 1920 设计
/// 宽换算（第一层 64 / 第二层 56 设计px）。
///
/// ## 焦点链路
///
/// - 第一层下边缘 → 第二层当前 tab（[TvNavFocusBridge.focusNavItem]）；
/// - 第二层上边缘 → 第一层迷你条（[TvPlayerBarFocusBridge.focusMiniPlayer]，
///   连发上键从内容区一路推到顶栏时焦点最终落迷你条，上游同款语义）；
/// - 第二层下边缘 → 内容区第一可聚焦点（上游「内容区焦点校正」简化版：
///   lite 无 ResponsiveShell 的 per-tab Navigator scope，顶栏与真实 tab 页
///   同处路由根 FocusScope，直接在 scope 内找首个非 chrome 焦点候选）；
/// - 内容区上边缘 → 第二层当前 tab（[TvContentFocusRegion] 桥接）。
class TvTopChrome extends StatefulWidget {
  const TvTopChrome({
    super.key,
    required this.visibleTabs,
    required this.selectedIndex,
    required this.onTabSelected,
  });

  /// 来自 `TabConfigProvider.visibleTabs` 的可见 tab 列表（不含设置——
  /// 设置由本组件固定追加在第二层末尾，TV 上设置必须可达）。
  final List<TabItem> visibleTabs;

  /// 当前选中索引（[visibleTabs] 内索引；选中固定追加的「设置」时=
  /// [visibleTabs].length）。由宿主（_MainLayout）持有与同步。
  final int selectedIndex;

  /// tab 选中回调（聚焦即选中 / OK 兼容入口共用）。索引含末尾设置槽位，
  /// 由宿主决定「切换 tab」还是「以二级路由打开设置」。
  final ValueChanged<int> onTabSelected;

  @override
  State<TvTopChrome> createState() => _TvTopChromeState();
}

class _TvTopChromeState extends State<TvTopChrome> {
  /// 固定追加的设置项（TV：设置必须从顶栏可达，用户不能隐藏）。
  static const TabItem _settingsTab = TabItem(id: 'settings', label: '设置');

  /// tv: 第二层 tab 项焦点节点池（每项 1 个，随本 State dispose）。
  /// 复用禁忌同上游 tv_shell 的 _tabNodes：每次 build 新建会逐帧泄漏，
  /// 且选中态切换时节点身份变化会丢焦点。
  final Map<int, FocusNode> _tabNodes = <int, FocusNode>{};

  /// 第一层头像胶囊与搜索按钮的焦点节点（迷你条节点由 TvMiniBar 自持并
  /// 登记 [TvPlayerBarFocusBridge]）。
  final FocusNode _accountNode = FocusNode(debugLabel: 'tv/top-account');
  final FocusNode _searchNode = FocusNode(debugLabel: 'tv/top-search');

  /// 首帧 autofocus 一次性门控（只允许第一帧生效，防重挂载抢焦点）。
  bool _autofocusDone = false;

  /// 全部第二层项（可见 tab + 固定追加的设置，设置已可见时不重复追加）。
  List<TabItem> get _tabs => widget.visibleTabs.any((t) => t.id == 'settings')
      ? widget.visibleTabs
      : [...widget.visibleTabs, _settingsTab];

  @override
  void initState() {
    super.initState();
    if (kTvBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _autofocusDone = true;
      });
    }
  }

  @override
  void dispose() {
    for (final FocusNode node in _tabNodes.values) {
      node.dispose();
    }
    _tabNodes.clear();
    _accountNode.dispose();
    _searchNode.dispose();
    super.dispose();
  }

  /// tab id → 顶栏显示名（批次43 口径沿用：搜索/推荐/我的音乐/现场电台，
  /// 其余原名）。
  String _labelFor(TabItem tab) {
    switch (tab.id) {
      case 'search':
        return '搜索';
      case 'discover':
        return '推荐';
      case 'library':
        return '我的音乐';
      case 'fm':
        return '现场电台';
      default:
        return tab.label;
    }
  }

  /// tab id → 顶栏图标（可选开启的非默认 tab 与手机端 NavigationDestination
  /// 映射一致，见 app.dart _buildDestination）。
  IconData _iconFor(TabItem tab) {
    switch (tab.id) {
      case 'search':
        return Icons.search;
      case 'discover':
        return Icons.explore;
      case 'library':
        return Icons.library_music;
      case 'fm':
        return Icons.radio;
      case 'favorites':
      case 'local_favorites':
        return Icons.favorite;
      case 'recognition':
        return Icons.mic;
      case 'audiobook':
        return Icons.auto_stories;
      case 'recent':
        return Icons.history;
      case 'settings':
        return Icons.settings;
      default:
        return Icons.circle_outlined;
    }
  }

  FocusNode _tabNodeFor(int index) {
    return _tabNodes.putIfAbsent(
      index,
      () => FocusNode(debugLabel: 'tv/tab-$index'),
    );
  }

  /// 聚焦即选中：焦点到达第 [index] 项即切换选中（无需 OK）。
  void _select(int index) {
    if (widget.selectedIndex == index) return;
    AppHaptics.tick();
    widget.onTabSelected(index);
  }

  /// 第二层下边缘 → 内容区第一可聚焦点（上游「内容区焦点校正」简化版）。
  ///
  /// lite 的真实 tab 页与顶栏同处路由根 FocusScope（无 per-tab Navigator
  /// scope），故直接在 scope 的 traversalDescendants 里取首个「非顶栏
  /// chrome」候选：跳过导航节点（[TvNavFocusBridge.isNavNode]）、第一层
  /// chrome 子树（[TvTopChromeScope.contains]）与迷你条节点
  /// （[TvPlayerBarFocusBridge.isMiniNode]），并跳过不可聚焦 /
  /// skipTraversal 的节点（DpadRegion 的 marker 节点即被后者排除）。
  void _focusContent() {
    final FocusScopeNode scope = FocusScope.of(context);
    for (final FocusNode node in scope.traversalDescendants) {
      if (!node.canRequestFocus || node.skipTraversal) continue;
      if (TvNavFocusBridge.instance.isNavNode(node)) continue;
      if (TvTopChromeScope.contains(node)) continue;
      if (TvPlayerBarFocusBridge.instance.isMiniNode(node)) continue;
      node.requestFocus();
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 设计稿像素 → 实际布局换算系数（契约见 tv_design.dart）。
    final double scale = TvLayoutScale.of(context);
    // 玻璃底：整条顶栏悬浮于页面上方的玻璃板（推挤式布局的视觉载体——
    // 布局上它占据固定高度把内容往下推，不遮挡；blur σ 经 tvBlurSigma
    // 钳制，fillAlpha 对齐手机端玻璃语言 0.12）。
    return TvLayoutScale(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16 * scale, 12 * scale, 16 * scale, 0),
        child: LiquidGlassSurface(
          shape: GlassShape.roundedRect,
          borderRadius: 20 * scale,
          blurSigma: tvBlurSigma(18),
          fillAlpha: 0.12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTopLayer(context, scale),
              SizedBox(height: 4 * scale),
              _buildTabLayer(context, scale),
            ],
          ),
        ),
      ),
    );
  }

  // ── 第一层：头像 / 迷你条 / 搜索 ──────────────────────────

  Widget _buildTopLayer(BuildContext context, double scale) {
    return TvTopChromeScope(
      child: DpadRegion(
        memoryKey: 'tv/top-layer',
        debugLabel: 'tv-top-layer',
        horizontalEdge: DpadEdgeBehavior.stop,
        verticalEdge: DpadEdgeBehavior.stop,
        onEdge: (direction) {
          // 下边缘 = 第二层 tab 栏（落在当前 tab 上，经节点池桥接——
          // 顶栏与第二层分属两个 DpadRegion，候选收集互不可见）。
          if (direction == TraversalDirection.down) {
            TvNavFocusBridge.instance.focusNavItem(
              widget.selectedIndex.clamp(0, _tabs.length - 1),
            );
          }
          // 上边缘是屏幕顶，无动作。
        },
        child: SizedBox(
          height: 64 * scale,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 24 * scale,
              vertical: 8 * scale,
            ),
            child: Row(
              children: [
                _buildAccountCapsule(context, scale),
                SizedBox(width: 12 * scale),
                Expanded(
                  child: TvMiniBar(
                    key: const ValueKey('tv_mini_bar'),
                    scale: scale,
                  ),
                ),
                SizedBox(width: 12 * scale),
                _buildPlayPauseButton(context, scale),
                SizedBox(width: 12 * scale),
                _buildSearchButton(context, scale),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 头像胶囊：KugouProvider 登录态（头像+昵称），未登录显示登录图标占位。
  /// OK/点击 → 登录页（批次44 占位落点，批次45 用户中心再分叉）。
  Widget _buildAccountCapsule(BuildContext context, double scale) {
    final userInfo = context.watch<KugouProvider>().userInfo;
    final String? nickname = userInfo?.nickname;
    final String? avatarUrl = userInfo?.avatar;
    return DpadFocusable(
      focusNode: _accountNode,
      debugLabel: 'tv/account',
      // 指针点击交给内容自身的占位路径，避免与 OK 双触发。
      tapToSelect: false,
      onSelect: _openAccount,
      child: Container(
        constraints: BoxConstraints(maxWidth: 220 * scale),
        padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 6 * scale),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(24 * scale),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildAvatar(avatarUrl, scale),
            SizedBox(width: 8 * scale),
            Flexible(
              child: Text(
                (nickname == null || nickname.isEmpty) ? '未登录' : nickname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 24 * scale,
                  color: (nickname == null || nickname.isEmpty)
                      ? TvColors.secondary
                      : TvColors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(String? url, double scale) {
    // 半径 14 设计px：胶囊内容高 28+上下 padding 12 = 40 ≤ 第一层内高 48
    // （64 − 上下 8×2），不产生纵向溢出。
    final double radius = 14 * scale;
    if (url == null || url.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.white.withValues(alpha: 0.10),
        child: Icon(
          Icons.person_outline,
          size: 22 * scale,
          color: TvColors.secondary,
        ),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.white.withValues(alpha: 0.10),
      backgroundImage: NetworkImage(url),
    );
  }

  void _openAccount() {
    unawaited(
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      ),
    );
  }

  /// 播放/暂停钮：与迷你条平级的独立焦点项（TV 上最常用动作单独可达，
  /// 迷你条本体 OK = 进播放页）。无歌时点击空操作。
  Widget _buildPlayPauseButton(BuildContext context, double scale) {
    final player = context.watch<PlayerProvider>();
    final bool hasSong = player.currentSong != null;
    final bool playing = player.isPlaying;
    return DpadFocusable(
      key: const ValueKey('tv_mini_bar_play_pause'),
      debugLabel: 'tv/mini-bar-play-pause',
      onSelect: () {
        if (!hasSong) return;
        // ignore: discarded_futures
        playing ? player.pause() : player.resume();
      },
      child: Container(
        width: 44 * scale,
        height: 44 * scale,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12 * scale),
        ),
        child: Icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 28 * scale,
          color: hasSong ? TvColors.white : TvColors.disabled,
        ),
      ),
    );
  }

  /// 搜索钮：玻璃圆钮（GlassCircleButton），OK/点击 → '/search' 路由。
  Widget _buildSearchButton(BuildContext context, double scale) {
    return DpadFocusable(
      focusNode: _searchNode,
      debugLabel: 'tv/search',
      // 指针点击交给 GlassCircleButton 自身的 IconButton，避免与 OK 双触发。
      tapToSelect: false,
      onSelect: _openSearch,
      child: GlassCircleButton(
        icon: Icons.search,
        tooltip: '搜索',
        onPressed: _openSearch,
      ),
    );
  }

  void _openSearch() {
    unawaited(Navigator.of(context, rootNavigator: true).pushNamed('/search'));
  }

  // ── 第二层：横向 tab 栏 ──────────────────────────────────

  Widget _buildTabLayer(BuildContext context, double scale) {
    return DpadRegion(
      memoryKey: 'tv/main-nav',
      debugLabel: 'tv-main-nav',
      horizontalEdge: DpadEdgeBehavior.stop,
      verticalEdge: DpadEdgeBehavior.stop,
      onEdge: (direction) {
        switch (direction) {
          case TraversalDirection.up:
            // 上边缘 = 第一层。短按上键落迷你条；内容区连发上键推上来时
            // 焦点最终停在迷你条（上游 TvPlayerBarFocusBridge 同款语义）。
            TvPlayerBarFocusBridge.instance.focusMiniPlayer();
          case TraversalDirection.down:
            // 下边缘 = 页面内容（需求：从 tab 栏按下方向键进入页面）。
            _focusContent();
          default:
            break;
        }
      },
      child: SizedBox(
        height: 56 * scale,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            horizontal: 16 * scale,
            vertical: 6 * scale,
          ),
          itemCount: _tabs.length,
          itemBuilder: (context, index) =>
              _buildTabItem(context, _tabs[index], index, scale),
        ),
      ),
    );
  }

  Widget _buildTabItem(
    BuildContext context,
    TabItem tab,
    int index,
    double scale,
  ) {
    final bool selected = index == widget.selectedIndex;
    // 焦点节点登记到焦点移交池：内容区上边缘 / 首层下边缘都靠它识别与
    // 落点（TvTopChrome 与内容区分属不同 DpadRegion，必须显式桥接）。
    final FocusNode node = _tabNodeFor(index);
    TvNavFocusBridge.instance.register(index, node);
    return DpadFocusable(
      focusNode: node,
      autofocus: index == widget.selectedIndex && !_autofocusDone,
      debugLabel: 'tv/tab-item-${tab.id}',
      // 聚焦即选中（上游语义）：方向键移入即切换 tab，无需 OK。
      onFocusChange: (focused) {
        if (focused) _select(index);
      },
      // OK 键兼容入口（读屏/指针设备）：再次确认当前 tab。
      onSelect: () {
        if (!selected) _select(index);
      },
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 4 * scale),
        padding: EdgeInsets.symmetric(horizontal: 16 * scale),
        decoration: BoxDecoration(
          // 获焦（=选中）玻璃底块：半透明白块叠在顶栏玻璃板上（无实色底）。
          color: selected
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12 * scale),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 左侧品牌色指示条：4×32 设计px，120ms 淡入（上游动效参数）。
            AnimatedOpacity(
              opacity: selected ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Container(
                width: 4 * scale,
                height: 32 * scale,
                margin: EdgeInsets.only(right: 12 * scale),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(2 * scale),
                ),
              ),
            ),
            Icon(
              _iconFor(tab),
              size: 26 * scale,
              color: selected ? TvColors.white : TvColors.secondary,
            ),
            // tab 名称与图标同行，仅当前 tab 显示（上游口径）。
            if (selected) ...[
              SizedBox(width: 10 * scale),
              Text(
                _labelFor(tab),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 26 * scale,
                  fontWeight: FontWeight.w600,
                  color: TvColors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// tv: 顶栏迷你播放条（批次44 自建简化版，替代上游 1185 行的 MiniPlayer）。
///
/// 布局：封面缩略 + 歌名/歌手（弹性宽）+ 底部细进度线；**本体可聚焦**
/// （FocusNode 登记 [TvPlayerBarFocusBridge]，OK/点击 → '/player' 播放页，
/// TV 播放页路由已接 TvFullPlayer）。播放/暂停为第一层平级独立焦点项
/// （[TvTopChrome._buildPlayPauseButton]），走 [PlayerProvider]。
///
/// 高频进度经 [PlayerProvider.positionNotifier]（ValueListenable，~200ms
/// 采样不触发 Provider 全量通知），歌名/播放态走 context.watch 低频重建。
class TvMiniBar extends StatefulWidget {
  const TvMiniBar({super.key, required this.scale});

  /// TvLayoutScale 换算系数（由 [TvTopChrome] 传入，避免再建作用域）。
  final double scale;

  @override
  State<TvMiniBar> createState() => _TvMiniBarState();
}

class _TvMiniBarState extends State<TvMiniBar> {
  /// 迷你条本体焦点节点（登记到焦点移交桥，见类注释）。
  final FocusNode _barNode = FocusNode(debugLabel: 'tv/mini-bar');

  @override
  void initState() {
    super.initState();
    TvPlayerBarFocusBridge.instance.register(_barNode);
  }

  @override
  void dispose() {
    TvPlayerBarFocusBridge.instance.unregister(_barNode);
    _barNode.dispose();
    super.dispose();
  }

  void _openPlayer() {
    unawaited(Navigator.of(context, rootNavigator: true).pushNamed('/player'));
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    final double s = widget.scale;

    return DpadFocusable(
      focusNode: _barNode,
      // 注意：DpadFocusable 会用本 debugLabel 覆写 focusNode.debugLabel
      // （dpad focusable.dart:279），节点与组件共用同一标识。
      debugLabel: 'tv/mini-bar',
      onSelect: _openPlayer,
      child: Container(
        height: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 14 * s),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12 * s),
        ),
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  _buildCover(song?.artworkUri, s),
                  SizedBox(width: 10 * s),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song?.title ?? '未在播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            // height 1.05 固定行高：两行文字合计
                            // 21+16.8+2 ≈ 40 ≤ 可用高（48−进度线 7）。
                            fontSize: 20 * s,
                            height: 1.05,
                            color: song == null
                                ? TvColors.secondary
                                : TvColors.white,
                          ),
                        ),
                        if (song != null) ...[
                          SizedBox(height: 2 * s),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16 * s,
                              height: 1.05,
                              color: TvColors.secondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 细进度线（track → 白，随 positionNotifier 高频推进）。
            SizedBox(height: 4 * s),
            ValueListenableBuilder<Duration>(
              valueListenable: player.positionNotifier,
              builder: (context, position, _) {
                final Duration? total = player.duration ?? song?.duration;
                final double fraction =
                    (total == null || total <= Duration.zero)
                        ? 0.0
                        : (position.inMilliseconds / total.inMilliseconds)
                            .clamp(0.0, 1.0);
                return ClipRRect(
                  borderRadius: BorderRadius.circular(1.5 * s),
                  child: SizedBox(
                    height: 3 * s,
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 3 * s,
                      backgroundColor: TvColors.track,
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(TvColors.white),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 封面缩略：有 url 走网络图（加载失败回落占位图标），无 url 画占位。
  Widget _buildCover(String? url, double s) {
    final Widget placeholder = Icon(
      Icons.music_note,
      size: 22 * s,
      color: TvColors.secondary,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8 * s),
      child: SizedBox(
        width: 36 * s,
        height: 36 * s,
        child: ColoredBox(
          color: Colors.white.withValues(alpha: 0.08),
          child: (url == null || url.isEmpty)
              ? Center(child: placeholder)
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Center(child: placeholder),
                ),
        ),
      ),
    );
  }
}

/// tv: TV 内容区焦点作用域（批次44）——包住真实 tab 页宿主
/// （_MainLayout body），承接「内容区上边缘 → 第二层当前 tab」的移交。
///
/// 上边缘 stop + onEdge：焦点走到内容区顶缘时经 [TvNavFocusBridge] 显式
/// 桥接回第二层（顶栏与内容区分属不同 DpadRegion，候选收集互不可见）。
/// 左右边缘保持默认 leave：页面内横向滚动/翻页由页面自身处理。
/// [selectedIndex] 随宿主重建刷新，事件时读到的是当前 tab。
class TvContentFocusRegion extends StatelessWidget {
  const TvContentFocusRegion({
    super.key,
    required this.selectedIndex,
    required this.child,
  });

  /// 当前选中 tab 索引（内容区上边缘的桥接落点）。
  final int selectedIndex;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DpadRegion(
      memoryKey: 'tv_content',
      debugLabel: 'tv-content',
      upEdge: DpadEdgeBehavior.stop,
      onEdge: (direction) {
        if (direction == TraversalDirection.up) {
          TvNavFocusBridge.instance.focusNavItem(selectedIndex);
        }
      },
      child: child,
    );
  }
}
