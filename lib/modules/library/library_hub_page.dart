import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
// showM3EModalBottomSheet（隐藏歌单底部弹层）。m3e_core 与本地 fork 的
// M3EPullToRefreshIndicator 同名，按 favorites_page 同款 hide 处理。
import 'package:m3e_core/m3e_core.dart' hide M3EPullToRefreshIndicator;
import 'package:provider/provider.dart';

import '../../core/layout/adaptive_navigator.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../data/repositories/favorite_lists_cache.dart';
import '../../data/repositories/hidden_playlists_cache.dart';
import '../../data/repositories/history_repository.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/common/cover_rail.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import '../../widgets/m3e_pull_to_refresh_fixed.dart';
import '../../widgets/smart_artwork_image.dart';
import '../playlist/playlist_page.dart';
import '../playlist/playlist_songs_loader.dart';
import '../search/search_page.dart';
import '../user/cloud_music_page.dart';
import '../user/favorites_page.dart';
import '../user/play_history_page.dart';
import '../user/purchased_page.dart';
import 'library_page.dart' show LibraryPage, showLibraryScanMenu;

/// 音乐库一级页（IA 改版：资产入口聚合中枢）。
///
/// 页面定位：按「资产归属」组织四大资产入口，完整内容下沉二级子页：
/// - 骨架：[SonifyTitleScaffold] 固定悬浮大标题「音乐库」；右上角
///   **常驻**玻璃搜索圆钮（走 [SonifyTitleScaffold.trailing]，不随滚动
///   淡入淡出——用户要求常驻可见）；扫描钮（原 FAB 职责）走 actions
///   （仅栏体浮现后淡入，扫描中转圈禁用防重复触发）；
/// - 入口区：2×2 squircle 卡片（收藏 / 本地 / 已购 / 云盘）。收藏卡
///   额外带「直接播放」圆钮：不点开卡片即播放「我喜欢」（缓存优先、
///   倒序从最新收藏始，链路同收藏页封面一键播放）；点开卡片则直达
///   [FavoritesPage(initialTab: 0, focusMyFavorite: true)] 自动打开
///   「我喜欢」歌单；
/// - 列表分区：最近播放 Top 3（点标题行看全部播放历史）+ 我创建的歌单
///   + 我收藏的歌单，后两者用主页热门歌单同款 [CoverRail]/
///   [CoverRailCard] 样式（创建/收藏区分规则同 [FavoritesPage]，见
///   [_isCreatedPlaylist]）；
/// - 隐藏歌单：两个歌单调区标题行带「管理」入口，进入多选态后可批量
///   隐藏（本地视图偏好，仓库见 [HiddenPlaylistsCache]），分区下方
///   「已隐藏 N 个歌单」可点开底部弹层逐项恢复；
/// - 歌单为空时分区显示空态文案即可，登录引导由目标子页自行处理。
class LibraryHubPage extends StatefulWidget {
  const LibraryHubPage({super.key});

  @override
  State<LibraryHubPage> createState() => _LibraryHubPageState();
}

/// 音乐库页面局部尺寸规格（页面内唯一来源）。
abstract final class _HubDimens {
  /// 最近播放列表行高。
  static const double rowHeight = 56;

  /// 列表行封面边长。
  static const double rowCover = 44;

  /// 入口卡片最小高度（2×2 网格两行等高）。
  static const double entryCardMinHeight = 88;

  /// 入口卡片图标边长。
  static const double entryCardIcon = 22;

  /// 收藏卡「直接播放」圆钮边长（卡右侧，tonal 圆形底）。
  static const double playButton = 36;

  /// 收藏卡播放钮图标边长。
  static const double playButtonIcon = 20;

  /// 播放中进度环边长（小于钮心，留出描边余量）。
  static const double playButtonSpinner = 18;

  /// 顶栏玻璃圆钮边长（与首页顶栏搜索钮同规格，discover_page 42dp）。
  static const double barButton = 42;

  /// 顶栏玻璃圆钮图标边长（同首页 20dp）。
  static const double barButtonIcon = 20;
}

/// 歌单分区标识（管理态 / 隐藏提示按分区隔离）。
const int _kGroupCreated = 1; // 我创建的歌单
const int _kGroupCollected = 2; // 我收藏的歌单

class _LibraryHubPageState extends State<LibraryHubPage> {
  // 云端歌单（FavoritesPage 同源缓存链路；区分「创建 vs 收藏」见
  // _isCreatedPlaylist。云端收藏专辑/歌手不进 IA（归属收藏语义，由
  // FavoritesPage 承载）。
  List<KugouPlaylistBrief> _playlists = [];

  // 最近播放（Top 3 数据源）
  List<Song> _history = [];
  Map<String, int> _playCounts = {};

  // 已隐藏歌单 key 集合（HiddenPlaylistsCache，与收藏页共用同一仓库）
  Set<String> _hiddenKeys = {};

  // 歌单分区多选管理态：null=非管理；_kGroupCreated / _kGroupCollected
  int? _managingGroup;
  final Set<String> _selectedKeys = {};

  // 「我喜欢」封面一键播放中（防重复点击，局部进度环）
  bool _playingMyFavorite = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 「本地」入口卡副标题计数：先恢复缓存歌曲（与 LibraryMusicPanel
      // 同口径，不自动触发扫描）。
      context.read<LibraryProvider>().loadSavedSongs();
      // 歌单分区直读 FavoriteListsCache，最近播放直读 HistoryRepository；
      // 实时网络同步仍由收藏页承载。
      _loadPlaylists();
      _loadHistory();
    });
  }

  Future<void> _loadPlaylists() async {
    final playlists = await FavoriteListsCache.readPlaylists();
    final hidden = await HiddenPlaylistsCache.readHidden();
    if (!mounted) return;
    setState(() {
      _playlists = playlists;
      _hiddenKeys = hidden;
    });
  }

  Future<void> _loadHistory() async {
    final history = await HistoryRepository().getHistory();
    final counts = await HistoryRepository().getPlayCounts();
    if (!mounted) return;
    setState(() {
      _history = history;
      _playCounts = counts;
    });
  }

  /// 下拉刷新：本地歌曲缓存（入口卡计数）+ 歌单缓存链路 + 隐藏集合 +
  /// 最近播放重读。
  Future<void> _refresh() async {
    await context.read<LibraryProvider>().loadSavedSongs();
    await _loadPlaylists();
    await _loadHistory();
  }

  // ==================== 歌单「创建 vs 收藏」区分 ====================

  /// 与 FavoritesPage._isCreated 同款规则：listCreateUserid 比对当前登录
  /// 用户优先；缺失时按 type/source 与默认收藏名称启发式兜底。
  bool _isCreatedPlaylist(KugouPlaylistBrief p) {
    final uid = KugouApiClient().userid;
    if (uid != null &&
        uid.isNotEmpty &&
        p.listCreateUserid != null &&
        p.listCreateUserid!.isNotEmpty) {
      return p.listCreateUserid == uid;
    }
    if (p.type == 0 && p.source != 2) return true;
    if (p.name == '我喜欢' || p.name == '默认收藏') return true;
    return false;
  }

  bool _isHidden(KugouPlaylistBrief p) =>
      _hiddenKeys.contains(HiddenPlaylistsCache.playlistKey(p));

  List<KugouPlaylistBrief> get _createdPlaylists => _playlists
      .where((p) => _isCreatedPlaylist(p) && !_isHidden(p))
      .toList();

  List<KugouPlaylistBrief> get _collectedPlaylists => _playlists
      .where((p) => !_isCreatedPlaylist(p) && !_isHidden(p))
      .toList();

  /// 某分区下被隐藏的歌单（底部弹层数据源：从全量 _playlists 按 key 过滤）。
  List<KugouPlaylistBrief> _hiddenPlaylistsOf(int group) {
    final hidden = _playlists.where(_isHidden);
    return group == _kGroupCreated
        ? hidden.where(_isCreatedPlaylist).toList()
        : hidden.where((p) => !_isCreatedPlaylist(p)).toList();
  }

  // ==================== 交互 ====================

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  void _openPlaylist(KugouPlaylistBrief playlist) {
    AdaptiveNav.openDetail(
      context,
      (_) => PlaylistPage(
        playlist: playlist.toPlaylist(),
        isInMyFavorites: true,
      ),
    );
  }

  /// 收藏卡「直接播放」钮：不点开卡片即播放「我喜欢」。
  ///
  /// 链路与收藏页封面一键播放同款：缓存优先（PlaylistSongsLoader
  /// .readCached），空则拉网络（.fetch），倒序播放（云端按收藏正序返回，
  /// 反序后从最新收藏始），只等队列构建完成即释放进度环。未登录时
  /// playOnlinePlaylist 会静默走 onLoginRequired，故播放前先拦截提示。
  Future<void> _playMyFavorite() async {
    if (_playingMyFavorite) return; // 防重复点击
    if (!KugouApiClient().isLoggedIn) {
      showToast('请先登录');
      return;
    }
    KugouPlaylistBrief? myFavorite;
    for (final p in _playlists) {
      if (p.name == '我喜欢') {
        myFavorite = p;
        break;
      }
    }
    if (myFavorite == null) {
      showToast('暂无「我喜欢」歌单');
      return;
    }
    setState(() => _playingMyFavorite = true);
    try {
      final p = myFavorite.toPlaylist();
      var songs = await PlaylistSongsLoader.readCached(p, isInMyFavorites: true);
      if (songs.isEmpty) {
        final r = await PlaylistSongsLoader.fetch(context, p);
        songs = r.songs;
      }
      if (!mounted) return;
      if (songs.isEmpty) {
        showToast('歌单加载失败，请检查网络后重试', long: true);
        return;
      }
      // 倒序播放：歌单接口按收藏时间升序返回（最早在前、最新在后），
      // 反转后从最新收藏开始。只等队列构建完成即释放进度环，不等整条
      // URL 解析/播放链（playOnlinePlaylist 内部自带失败链式 next）。
      final ordered = songs.reversed.toList();
      unawaited(context.read<PlayerProvider>().playOnlinePlaylist(ordered, 0));
      showToast('开始播放「我喜欢」');
    } catch (_) {
      if (mounted) showToast('歌单加载失败，请检查网络后重试', long: true);
    } finally {
      if (mounted) setState(() => _playingMyFavorite = false);
    }
  }

  // ==================== 隐藏歌单（管理态） ====================

  void _enterManage(int group) {
    setState(() {
      _managingGroup = group;
      _selectedKeys.clear();
    });
  }

  void _exitManage() {
    setState(() {
      _managingGroup = null;
      _selectedKeys.clear();
    });
  }

  /// 管理态点歌单卡：切换选中（不跳详情）。
  void _toggleSelect(KugouPlaylistBrief playlist) {
    final key = HiddenPlaylistsCache.playlistKey(playlist);
    setState(() {
      if (!_selectedKeys.remove(key)) _selectedKeys.add(key);
    });
  }

  /// 「隐藏所选」：与既有隐藏集合求并集写回仓库，退出管理态。
  Future<void> _hideSelected() async {
    if (_selectedKeys.isEmpty) return;
    final keys = {..._hiddenKeys, ..._selectedKeys};
    await HiddenPlaylistsCache.writeHidden(keys);
    if (!mounted) return;
    setState(() {
      _hiddenKeys = keys;
      _managingGroup = null;
      _selectedKeys.clear();
    });
  }

  /// 底部弹层内「恢复」：切换隐藏状态并刷新页面与弹层。
  Future<void> _restorePlaylist(String key) async {
    await HiddenPlaylistsCache.toggleHidden(key);
    if (!mounted) return;
    final keys = await HiddenPlaylistsCache.readHidden();
    setState(() => _hiddenKeys = keys);
  }

  /// 「已隐藏 N 个歌单」底部弹层：列出该分区被隐藏的歌单，逐项恢复。
  Future<void> _showHiddenSheet(int group) async {
    await showM3EModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final hidden = _hiddenPlaylistsOf(group);
          final cs = Theme.of(context).colorScheme;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      group == _kGroupCreated ? '隐藏的创建歌单' : '隐藏的收藏歌单',
                      style: SonifyTextStyles.sectionTitle.copyWith(
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                ),
                if (hidden.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(
                      '暂无隐藏的歌单',
                      style: SonifyTextStyles.listItem.copyWith(
                        color: SonifyColors.of(context).textSecondary,
                      ),
                    ),
                  ),
                for (final p in hidden)
                  ListTile(
                    leading: ClipRRect(
                      borderRadius: AppRadius.xsAll,
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: _NetworkCover(
                          url: p.coverUrl,
                          placeholderIcon: Icons.queue_music,
                        ),
                      ),
                    ),
                    title: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${p.songCount} 首'),
                    trailing: TextButton(
                      onPressed: () async {
                        await _restorePlaylist(
                          HiddenPlaylistsCache.playlistKey(p),
                        );
                        // 弹层内容随父页面 _hiddenKeys 一起刷新
                        setSheetState(() {});
                      },
                      child: const Text('恢复'),
                    ),
                  ),
                const Gap(AppSpacing.sm),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    return SonifyTitleScaffold(
      title: '音乐库',
      itemCount: 1,
      // 顶栏右侧：搜索玻璃圆钮**常驻**（trailing 不随滚动淡入淡出）；
      // 扫描钮走 actions（栏体浮现后淡入）。
      trailing: _buildSearchButton(),
      actions: [
        IconButton(
          tooltip: '扫描音乐',
          icon: library.isScanning
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          onPressed: library.isScanning
              ? null
              : () => showLibraryScanMenu(context),
        ),
      ],
      itemBuilder: (context, index) {
        final media = MediaQuery.of(context);
        // 固定高度 = 视口 − 状态栏 − 标题区（8+36+8，与占位 item 同口径）
        final height = media.size.height - media.padding.top - 52;
        return SizedBox(
          height: height,
          child: M3EPullToRefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                _buildEntryCards(
                  playlistCount: _playlists.length,
                  songCount: library.songs.length,
                ),
                _Section(
                  title: '最近播放',
                  // 整个标题行可点（「显示全部」退化为视觉文案）
                  onHeaderTap: () => _push(context, const PlayHistoryPage()),
                  onShowAll: () => _push(context, const PlayHistoryPage()),
                  child: _history.isEmpty
                      ? const _SectionEmptyText('暂无播放记录')
                      : _RecentPlayList(
                          // 只显示最近 3 条，全部历史进播放历史页
                          songs: _history.take(3).toList(),
                          playCounts: _playCounts,
                        ),
                ),
                _Section(
                  title: '我创建的歌单',
                  trailing: _buildManageButton(_kGroupCreated),
                  managing: _managingGroup == _kGroupCreated,
                  onManageDone: _exitManage,
                  onManageCancel: _exitManage,
                  onHideSelected: _hideSelected,
                  selectedCount: _selectedKeys.length,
                  child: _buildPlaylistSectionBody(
                    _createdPlaylists,
                    emptyText: '暂无创建的歌单',
                    group: _kGroupCreated,
                  ),
                ),
                _Section(
                  title: '我收藏的歌单',
                  trailing: _buildManageButton(_kGroupCollected),
                  managing: _managingGroup == _kGroupCollected,
                  onManageDone: _exitManage,
                  onManageCancel: _exitManage,
                  onHideSelected: _hideSelected,
                  selectedCount: _selectedKeys.length,
                  child: _buildPlaylistSectionBody(
                    _collectedPlaylists,
                    emptyText: '暂无收藏的歌单',
                    group: _kGroupCollected,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 顶栏玻璃圆钮（与 discover_page 顶栏搜索钮同形态：42dp 圆形液态玻璃 +
  /// 20dp 图标），点击跳全局搜索页。常驻于 trailing。
  Widget _buildSearchButton() {
    return LiquidGlassSurface(
      shape: GlassShape.circle,
      child: SizedBox(
        width: _HubDimens.barButton,
        height: _HubDimens.barButton,
        child: IconButton(
          // 顶满玻璃圆钮（默认 48dp 会溢出 42dp 容器）
          constraints: BoxConstraints.tightFor(
            width: _HubDimens.barButton,
            height: _HubDimens.barButton,
          ),
          padding: EdgeInsets.zero,
          tooltip: '搜索',
          icon: const Icon(Icons.search, size: _HubDimens.barButtonIcon),
          onPressed: () => _push(context, const SearchPage()),
        ),
      ),
    );
  }

  // ==================== 入口卡片区（2×2） ====================

  Widget _buildEntryCards({required int playlistCount, required int songCount}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin,
        AppSpacing.md,
        SonifySpacing.titleMargin,
        0,
      ),
      child: Column(
        children: [
          Row(
            children: [
              _EntryCard(
                key: const ValueKey('hub-entry-favorites'),
                icon: Icons.favorite,
                title: '收藏',
                // 未登录 / 无缓存歌单时不显示副标题
                subtitle: playlistCount > 0 ? '$playlistCount 个歌单' : null,
                // 点开卡片直达「我喜欢」歌单（收藏页歌单 tab 自动打开）
                onTap: () => _push(
                  context,
                  const FavoritesPage(initialTab: 0, focusMyFavorite: true),
                ),
                // 卡右侧播放钮：不点开直接播放「我喜欢」
                onPlay: _playMyFavorite,
                playing: _playingMyFavorite,
              ),
              const Gap(AppSpacing.sm),
              _EntryCard(
                key: const ValueKey('hub-entry-local'),
                icon: Icons.library_music,
                title: '本地',
                // 无本地歌曲时不显示副标题
                subtitle: songCount > 0 ? '$songCount 首歌曲' : null,
                onTap: () => _push(context, const LibraryPage(initialTab: 0)),
              ),
            ],
          ),
          const Gap(AppSpacing.sm),
          Row(
            children: [
              _EntryCard(
                key: const ValueKey('hub-entry-purchased'),
                icon: Icons.shopping_bag_outlined,
                title: '已购',
                onTap: () => _push(context, const PurchasedPage()),
              ),
              const Gap(AppSpacing.sm),
              _EntryCard(
                key: const ValueKey('hub-entry-cloud'),
                icon: Icons.cloud_outlined,
                title: '云盘',
                onTap: () => _push(context, const CloudMusicPage()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== 歌单分区（CoverRail + 隐藏管理） ====================

  /// 歌单分区标题行「管理」入口（小尺寸 IconButton，非管理态时可见）。
  Widget _buildManageButton(int group) {
    return IconButton(
      key: ValueKey('hub-manage-${group == _kGroupCreated ? 'created' : 'collected'}'),
      tooltip: '管理隐藏歌单',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      iconSize: 18,
      icon: const Icon(Icons.more_horiz),
      onPressed: () => _enterManage(group),
    );
  }

  /// 歌单分区内容：有数据走 CoverRail（主页热门歌单同款），空数据显示
  /// 空态文案；有隐藏歌单时下方附「已隐藏 N 个歌单，点击管理」入口。
  Widget _buildPlaylistSectionBody(
    List<KugouPlaylistBrief> playlists, {
    required String emptyText,
    required int group,
  }) {
    final hidden = _hiddenPlaylistsOf(group);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (playlists.isEmpty)
          _SectionEmptyText(emptyText)
        else
          _buildPlaylistRail(playlists, group: group),
        if (hidden.isNotEmpty) _buildHiddenHint(group, hidden.length),
      ],
    );
  }

  /// CoverRail 横滑轨（样式同 discover_page 热门歌单）：150dp 封面 +
  /// squircle 10 + 静态阴影 + 1px 白 α0.10 内描边 + 13sp 标题/副标。
  /// 管理态下点卡切换选中（不跳详情），并叠加选中勾角标。
  Widget _buildPlaylistRail(List<KugouPlaylistBrief> playlists, {required int group}) {
    final managing = _managingGroup == group;
    return CoverRail(
      itemCount: playlists.length,
      itemBuilder: (context, i) {
        final playlist = playlists[i];
        final card = CoverRailCard(
          cover: _NetworkCover(
            url: playlist.coverUrl,
            placeholderIcon: Icons.queue_music,
          ),
          title: playlist.name,
          subtitle: '${playlist.songCount} 首',
          onTap: managing
              ? () => _toggleSelect(playlist)
              : () => _openPlaylist(playlist),
        );
        if (!managing) return card;
        return _SelectableCoverCard(
          selected: _selectedKeys.contains(
            HiddenPlaylistsCache.playlistKey(playlist),
          ),
          child: card,
        );
      },
    );
  }

  /// 「已隐藏 N 个歌单，点击管理」一行：点开底部弹层恢复。
  Widget _buildHiddenHint(int group, int count) {
    final sonify = SonifyColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin,
        AppSpacing.sm,
        SonifySpacing.titleMargin,
        0,
      ),
      child: InkWell(
        key: ValueKey(
          'hub-hidden-hint-${group == _kGroupCreated ? 'created' : 'collected'}',
        ),
        onTap: () => _showHiddenSheet(group),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 14,
                color: sonify.textSecondary,
              ),
              const Gap(AppSpacing.xs),
              Text(
                '已隐藏 $count 个歌单，点击管理',
                style: SonifyTextStyles.listItem.copyWith(
                  color: sonify.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== 通用子组件 ====================

/// 分区（纵向列表用）：分区标题 + 可选「显示全部」/「管理」/ 管理态操作
/// 行 + 内容。[onHeaderTap] 非空时整个标题行可点（最近播放 → 播放历史页，
/// 「显示全部」退化为视觉文案）。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.onShowAll,
    this.onHeaderTap,
    this.trailing,
    this.managing = false,
    this.onManageDone,
    this.onManageCancel,
    this.onHideSelected,
    this.selectedCount = 0,
  });

  final String title;
  final Widget child;

  /// 「显示全部」视觉文案的回调（保留旧视觉；整个标题行的点击优先走
  /// [onHeaderTap]，未提供时回退到本回调）。
  final VoidCallback? onShowAll;

  /// 整个标题行点击（最近播放分区专用）。
  final VoidCallback? onHeaderTap;

  /// 标题行右侧额外入口（歌单分区「管理」钮；管理态下不展示）。
  final Widget? trailing;

  // —— 多选管理态（歌单分区专用）——
  final bool managing;
  final VoidCallback? onManageDone;
  final VoidCallback? onManageCancel;
  final VoidCallback? onHideSelected;
  final int selectedCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SonifySpacing.titleMargin,
            AppSpacing.xl,
            SonifySpacing.titleMargin,
            AppSpacing.md,
          ),
          child: managing ? _buildManagingHeader(context) : _buildNormalHeader(context),
        ),
        // 横滑轨道首尾出血：左缘 18dp、右缘 18dp（CoverRail 网格边距）
        child,
      ],
    );
  }

  Widget _buildNormalHeader(BuildContext context) {
    final sonify = SonifyColors.of(context);
    final row = Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: SonifyTextStyles.sectionTitle.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        if (trailing != null) trailing!,
        if (onShowAll != null)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.xs),
            child: Text(
              '显示全部',
              style: SonifyTextStyles.listItem.copyWith(color: sonify.primary),
            ),
          ),
      ],
    );
    if (onHeaderTap == null && onShowAll == null) return row;
    return InkWell(
      onTap: onHeaderTap ?? onShowAll,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: row,
    );
  }

  /// 管理态标题行：「完成 / 取消 / 隐藏所选(N)」（N=0 时不可点）。
  Widget _buildManagingHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textStyle = SonifyTextStyles.listItem;
    return Row(
      children: [
        TextButton(
          onPressed: onManageDone,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text('完成', style: textStyle.copyWith(color: cs.primary)),
        ),
        const Spacer(),
        TextButton(
          onPressed: onManageCancel,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text('取消', style: textStyle.copyWith(color: cs.onSurfaceVariant)),
        ),
        const Gap(AppSpacing.xs),
        FilledButton.tonal(
          onPressed: selectedCount > 0 ? onHideSelected : null,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text('隐藏所选($selectedCount)', style: textStyle),
        ),
      ],
    );
  }
}

/// 分区空态文案（最近播放 / 歌单分区无数据时）。
class _SectionEmptyText extends StatelessWidget {
  const _SectionEmptyText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin,
        AppSpacing.xs,
        SonifySpacing.titleMargin,
        AppSpacing.sm,
      ),
      child: Text(
        text,
        style: SonifyTextStyles.listItem.copyWith(
          color: SonifyColors.of(context).textSecondary,
        ),
      ),
    );
  }
}

/// 入口卡片（2×2 网格单格）：高对比卡底 surfaceContainerHighest α0.92 +
/// 1px 白 α0.10 内描边 + primary 图标 + 标题/副标题。
///
/// [onPlay] 非空时卡右侧渲染圆形 tonal 播放钮（内层 InkWell 在手势竞技中
/// 胜出，不会误触发卡的 [onTap]）；[playing] 为 true 时钮内显示进度环。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.onPlay,
    this.playing = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// 可选「直接播放」钮（仅收藏卡）：卡右侧，独立 onPressed。
  final VoidCallback? onPlay;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: ConstrainedBox(
        // 两行等高：内容不足 88dp 时兜底撑高（文字缩放安全）
        constraints: const BoxConstraints(
          minHeight: _HubDimens.entryCardMinHeight,
        ),
        child: DecoratedBox(
          // 高对比卡底 + 1px 内描边（亮暗主题均不出戏；图标/文字色不动）
          decoration: ShapeDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.92),
            shape: SmoothRectangleBorder(
              borderRadius: BorderRadius.circular(SonifyRadius.card),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
            ),
          ),
          child: InkWell(
            onTap: onTap,
            customBorder: SmoothRectangleBorder(
              borderRadius: BorderRadius.circular(SonifyRadius.card),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: _HubDimens.entryCardIcon,
                    color: cs.primary,
                  ),
                  const Gap(AppSpacing.md),
                  Expanded(
                    child: _TileText(title: title, subtitle: subtitle),
                  ),
                  if (onPlay != null) ...[
                    const Gap(AppSpacing.sm),
                    _buildPlayButton(cs),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 卡右侧播放钮：36dp 圆形 secondaryContainer tonal 底 + 20dp 图标；
  /// 加载中换 18dp 进度环并禁用点击。
  Widget _buildPlayButton(ColorScheme cs) {
    return SizedBox(
      width: _HubDimens.playButton,
      height: _HubDimens.playButton,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: cs.secondaryContainer,
          shape: const CircleBorder(),
        ),
        child: InkWell(
          key: const ValueKey('hub-play-my-favorite'),
          customBorder: const CircleBorder(),
          onTap: playing ? null : onPlay,
          child: Center(
            child: playing
                ? SizedBox(
                    width: _HubDimens.playButtonSpinner,
                    height: _HubDimens.playButtonSpinner,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.onSecondaryContainer,
                    ),
                  )
                : Icon(
                    Icons.play_arrow_rounded,
                    size: _HubDimens.playButtonIcon,
                    color: cs.onSecondaryContainer,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 网格封面卡文本（主行 13sp / 副行 13sp textSecondary，§2.4）。
class _TileText extends StatelessWidget {
  const _TileText({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final sonify = SonifyColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: SonifyTextStyles.listItem.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        if (subtitle != null)
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SonifyTextStyles.listItem.copyWith(
              color: sonify.textSecondary,
            ),
          ),
      ],
    );
  }
}

/// 管理态封面卡包装：选中时置灰 + 右上角圆形勾角标（角标 IgnorePointer，
/// 点击穿透给 CoverRailCard 的 onTap 切换选中）。
class _SelectableCoverCard extends StatelessWidget {
  const _SelectableCoverCard({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Opacity(opacity: selected ? 0.55 : 1, child: child),
        Positioned(
          top: 6,
          right: 6,
          child: IgnorePointer(
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? cs.primary
                    : cs.surfaceContainerHighest.withValues(alpha: 0.9),
                border: Border.all(
                  color: selected ? cs.primary : cs.outline,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? Icon(Icons.check, size: 14, color: cs.onPrimary)
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// 网络封面（云端歌单，缓存链路同 FavoritesPage）。
class _NetworkCover extends StatelessWidget {
  const _NetworkCover({this.url, required this.placeholderIcon});

  final String? url;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: cs.surfaceContainerHighest,
      child: Icon(placeholderIcon, size: 24, color: cs.onSurfaceVariant),
    );
    if (url == null || url!.isEmpty) return placeholder;
    return CachedNetworkImage(
      // http:// 混合资源按 FavoritesPage 同款规则升级 https
      imageUrl: url!.startsWith('http://')
          ? url!.replaceFirst('http://', 'https://')
          : url!,
      memCacheWidth: 300,
      memCacheHeight: 300,
      fit: BoxFit.cover,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}

/// 最近播放 Top 3 列表（行高 56dp：封面 44×44 圆角 8 + 标题/副行）。
class _RecentPlayList extends StatelessWidget {
  const _RecentPlayList({required this.songs, required this.playCounts});

  final List<Song> songs;
  final Map<String, int> playCounts;

  @override
  Widget build(BuildContext context) {
    final sonify = SonifyColors.of(context);
    return Column(
      children: [
        for (final song in songs)
          InkWell(
            onTap: () {
              context.read<PlayerProvider>().playPlaylist([song], 0);
            },
            child: SizedBox(
              height: _HubDimens.rowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SonifySpacing.titleMargin,
                ),
                child: Row(
                  children: [
                    SmartArtworkImage(
                      artworkUri: song.artworkUri,
                      size: _HubDimens.rowCover,
                      borderRadius: AppRadius.sm,
                    ),
                    const Gap(AppSpacing.md),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SonifyTextStyles.cardTitle.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SonifyTextStyles.listItem.copyWith(
                              color: sonify.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if ((playCounts[song.id] ?? 0) > 0)
                      Text(
                        '${playCounts[song.id]} 次',
                        style: SonifyTextStyles.listItem.copyWith(
                          color: sonify.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
