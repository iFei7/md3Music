import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart' hide M3EPullToRefreshIndicator;
import 'package:provider/provider.dart';

import '../../core/layout/adaptive_navigator.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../data/models/album.dart';
import '../../data/models/artist.dart';
import '../../data/models/song.dart';
import '../../data/repositories/favorite_lists_cache.dart';
import '../../data/repositories/history_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/library_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/m3e_pull_to_refresh_fixed.dart';
import '../../widgets/m3e_sort_sheet.dart';
import '../../widgets/smart_artwork_image.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../../widgets/common/sonify_segmented_control.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import '../playlist/playlist_page.dart';
import '../search/search_page.dart';
import '../user/favorites_page.dart';
import '../user/play_history_page.dart';
import '../user/purchased_page.dart';
import 'albums_page.dart' show AlbumSongsPage;
import 'artists_page.dart' show ArtistSongsPage;
import 'hub_cloud_panel.dart';
import 'library_page.dart' show LibraryPage, showLibraryScanMenu;

/// 音乐库一级页（IA 改版：收藏 / 本地 / 已购 / 云盘 四段）。
///
/// 页面定位：资产聚合中枢，按「资产归属」重新分段（对标 Apple Music
/// 「资料库」+ 云端内容）：
/// - 骨架：[SonifyTitleScaffold] 固定悬浮大标题「音乐库」+ 顶栏 actions
///   （扫描钮承载原 FAB 职责 / 本地段排序钮 / 搜索玻璃圆钮——形态与首页
///   顶栏搜索钮一致，点击跳全局搜索页）；
/// - 分段：[SonifySegmentedControl] 4 段（收藏｜本地｜已购｜云盘），
///   固定于内容上方（吸顶等价实现：分段控件不随内容滚动，内容在 PageView
///   内各自滚动、各自记忆位置），切段 [HapticFeedback.selectionClick]；
/// - 收藏段（默认）：「我的歌单」（创建）+「收藏的歌单」（收藏他人）
///   +「最近播放」Top 10；歌单创建/收藏区分与 [FavoritesPage] 同款规则
///   （listCreateUserid 比对当前用户，兜底 type/source/名称启发式）；
/// - 本地段：批次 11 本地资产浏览收编——本地收藏/文件夹入口行、随机播放
///   胶囊、本地专辑/歌手网格、歌曲列表（排序钮持久化）；
/// - 已购段：内嵌 [PurchasedPanel]（单曲/专辑双 tab 二次切换，未登录
///   引导登录）；
/// - 云盘段：内嵌 [CloudHubPanel]（精简列表 + 查看全部跳 CloudMusicPage，
///   未登录引导登录）。
class LibraryHubPage extends StatefulWidget {
  const LibraryHubPage({super.key});

  @override
  State<LibraryHubPage> createState() => _LibraryHubPageState();
}

/// 分段文案（顺序即布局顺序）。
const List<String> kHubSegments = ['收藏', '本地', '已购', '云盘'];

/// 音乐库页面局部尺寸规格（页面内唯一来源）。
abstract final class _HubDimens {
  /// 歌单轨道封面边长。
  static const double railCover = 120;

  /// 最近播放列表行高。
  static const double rowHeight = 56;

  /// 列表行封面边长。
  static const double rowCover = 44;

  /// 入口行高度。
  static const double entryRowHeight = 44;

  /// 随机播放胶囊高度。
  static const double randomPillHeight = 36;

  /// 顶栏玻璃圆钮边长（与首页顶栏搜索钮同规格，discover_page 42dp）。
  static const double barButton = 42;

  /// 顶栏玻璃圆钮图标边长（同首页 20dp）。
  static const double barButtonIcon = 20;
}

/// 「歌曲」排序项（本地段顶栏排序钮选项，§4.4）。
enum HubSongSort { title, artist, dateAdded, playCount }

class _LibraryHubPageState extends State<LibraryHubPage> {
  final PageController _pageController = PageController();
  int _segmentIndex = 0;

  // 云端歌单（FavoritesPage 同源缓存链路；区分「创建 vs 收藏」见
  // _isCreatedPlaylist。云端收藏专辑/歌手不进 IA（归属收藏语义，由
  // FavoritesPage 承载）。
  List<KugouPlaylistBrief> _playlists = [];

  // 最近播放（收藏段 Top 10 数据源 + 本地段「播放次数」排序）
  List<Song> _history = [];
  Map<String, int> _playCounts = {};

  // 歌曲排序偏好（SettingsRepository，分段上下文持久化）
  final SettingsRepository _settings = SettingsRepository();
  HubSongSort _sortBy = HubSongSort.title;
  bool _sortDescending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<LibraryProvider>();
      // 本地段初始化（与 LibraryMusicPanel 同口径）：先恢复缓存歌曲
      // 再加载扫描目录，不自动触发扫描。
      provider.loadSavedSongs();
      provider.loadScanFolders();
      // 歌单分区直读 FavoriteListsCache，最近播放直读 HistoryRepository；
      // 实时网络同步仍由收藏页承载。
      _loadPlaylists();
      _loadHistory();
      _loadSortPrefs();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists() async {
    final playlists = await FavoriteListsCache.readPlaylists();
    if (!mounted) return;
    setState(() => _playlists = playlists);
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

  Future<void> _loadSortPrefs() async {
    final sortIndex = await _settings.getHubSongSort();
    final descending = await _settings.getHubSongSortDescending();
    if (!mounted) return;
    setState(() {
      _sortBy = HubSongSort.values.firstWhere(
        (e) => e.index == sortIndex,
        orElse: () => HubSongSort.title,
      );
      _sortDescending = descending;
    });
  }

  Future<void> _saveSortPrefs() async {
    await _settings.setHubSongSort(_sortBy.index);
    await _settings.setHubSongSortDescending(_sortDescending);
  }

  /// 下拉刷新：本地段 loadSavedSongs + 歌单缓存链路 + 最近播放重读。
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

  List<KugouPlaylistBrief> get _createdPlaylists =>
      _playlists.where(_isCreatedPlaylist).toList();

  List<KugouPlaylistBrief> get _collectedPlaylists =>
      _playlists.where((p) => !_isCreatedPlaylist(p)).toList();

  // ==================== 交互 ====================

  void _onSegmentChanged(int index) {
    setState(() => _segmentIndex = index);
    _pageController.animateToPage(
      index,
      duration: SonifyMotion.glassAlpha,
      curve: Curves.easeOut,
    );
  }

  void _onPageChanged(int index) {
    HapticFeedback.selectionClick();
    setState(() => _segmentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    context.watch<LocalFavoritesProvider>();
    return SonifyTitleScaffold(
      title: '音乐库',
      itemCount: 1,
      // 顶栏 actions：扫描钮（原 FAB 职责，扫描中转圈禁用防重复触发）+
      // 排序钮（仅本地段显示，歌曲列表排序）+ 搜索玻璃圆钮（与首页顶栏
      // 同形态）。
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
        if (_segmentIndex == 1)
          M3ESortButton<HubSongSort>(
            tooltip: '排序',
            icon: _sortDescending
                ? Icons.arrow_downward_rounded
                : Icons.arrow_upward_rounded,
            current: _sortBy,
            options: const [
              (value: HubSongSort.title, label: '按标题'),
              (value: HubSongSort.artist, label: '按歌手'),
              (value: HubSongSort.dateAdded, label: '按添加时间'),
              (value: HubSongSort.playCount, label: '按播放次数'),
            ],
            onPicked: (value, repeated) {
              setState(() {
                if (repeated) {
                  _sortDescending = !_sortDescending;
                } else {
                  _sortBy = value;
                  _sortDescending = false;
                }
              });
              _saveSortPrefs();
            },
          ),
        _buildSearchButton(context),
      ],
      itemBuilder: (context, index) {
        final media = MediaQuery.of(context);
        // 固定高度 = 视口 − 状态栏 − 标题区（8+36+8，与占位 item 同口径，
        // 同 LibraryPage/FavoritesPage 的单 item 固定高度模式）
        final height = media.size.height - media.padding.top - 52;
        return SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SonifySpacing.titleMargin,
                ),
                child: SonifySegmentedControl(
                  segments: kHubSegments,
                  selectedIndex: _segmentIndex,
                  onChanged: _onSegmentChanged,
                ),
              ),
              const Gap(AppSpacing.sm),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: _onPageChanged,
                  children: [
                    _buildFavoritesSegment(context),
                    _buildLocalSegment(context, library),
                    const PurchasedPanel(),
                    const CloudHubPanel(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 顶栏玻璃圆钮（与 discover_page 顶栏搜索钮同形态：42dp 圆形液态玻璃 +
  /// 20dp 图标），点击跳全局搜索页。
  Widget _buildSearchButton(BuildContext context) {
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

  // ==================== A. 收藏段 ====================

  Widget _buildFavoritesSegment(BuildContext context) {
    final created = _createdPlaylists;
    final collected = _collectedPlaylists;
    final hasAnyContent =
        created.isNotEmpty || collected.isNotEmpty || _history.isNotEmpty;
    if (!hasAnyContent) {
      return const _SegmentEmptyState(text: '暂无收藏内容');
    }

    return M3EPullToRefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const PageStorageKey('hub_favorites'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          if (created.isNotEmpty)
            _Section(
              title: '我的歌单',
              onShowAll: () => _push(context, const FavoritesPage(initialTab: 0)),
              child: _PlaylistRail(playlists: created),
            ),
          if (collected.isNotEmpty)
            _Section(
              title: '收藏的歌单',
              onShowAll: () => _push(context, const FavoritesPage(initialTab: 0)),
              child: _PlaylistRail(playlists: collected),
            ),
          if (_history.isNotEmpty)
            _Section(
              title: '最近',
              onShowAll: () => _push(context, const PlayHistoryPage()),
              child: _RecentPlayList(
                songs: _history.take(10).toList(),
                playCounts: _playCounts,
              ),
            ),
        ],
      ),
    );
  }

  // ==================== B. 本地段 ====================

  Widget _buildLocalSegment(BuildContext context, LibraryProvider library) {
    if (library.isScanning && !library.hasMusic) {
      return const _ScanningState();
    }
    if (!library.hasMusic) {
      return const _EmptyLibraryState();
    }

    final songs = _sortedSongs(library.songs);
    final albums = library.albums;
    final artists = library.artists;

    return M3EPullToRefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        key: const PageStorageKey('hub_local'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // 入口行（本地收藏 / 文件夹）+ 随机播放胶囊
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SonifySpacing.titleMargin,
                  ),
                  child: Column(
                    children: [
                      _EntryRow(
                        key: const ValueKey('hub-entry-local-favorites'),
                        icon: Icons.favorite,
                        iconColor: Theme.of(context).colorScheme.primary,
                        label: '本地收藏',
                        detail:
                            '${context.watch<LocalFavoritesProvider>().favoriteIds.length} 首',
                        onTap: () =>
                            _push(context, const LibraryPage(initialTab: 4)),
                      ),
                      const Gap(AppSpacing.xs),
                      _EntryRow(
                        key: const ValueKey('hub-entry-folders'),
                        icon: Icons.folder_outlined,
                        iconColor:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                        label: '文件夹',
                        detail: '${library.scanFolders.length} 个目录',
                        onTap: () =>
                            _push(context, const LibraryPage(initialTab: 3)),
                      ),
                    ],
                  ),
                ),
                const Gap(AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SonifySpacing.titleMargin,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _RandomPlayPill(songs: songs),
                  ),
                ),
              ],
            ),
          ),
          // 本地专辑网格
          if (albums.isNotEmpty) ...[
            const SliverToBoxAdapter(child: _SectionHeaderRow(title: '专辑')),
            _SliverCoverGrid(
              key: const PageStorageKey('hub_local_albums'),
              itemCount: albums.length,
              itemBuilder: (context, index) =>
                  _LocalAlbumTile(album: albums[index]),
            ),
          ],
          // 本地歌手网格
          if (artists.isNotEmpty) ...[
            const SliverToBoxAdapter(child: _SectionHeaderRow(title: '歌手')),
            _SliverCoverGrid(
              key: const PageStorageKey('hub_local_artists'),
              itemCount: artists.length,
              itemBuilder: (context, index) =>
                  _LocalArtistTile(artist: artists[index]),
            ),
          ],
          // 歌曲列表（顶栏排序钮作用于本列表）
          const SliverToBoxAdapter(child: _SectionHeaderRow(title: '歌曲')),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  return _SongRow(
                    song: songs[index],
                    onTap: () {
                      context
                          .read<PlayerProvider>()
                          .playPlaylist(songs, index);
                    },
                  );
                },
                childCount: songs.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 歌曲排序（顶栏排序钮语义，§4.4）。
  /// 添加时间：原列表顺序视为添加顺序（与 SongsPage 同口径）。
  List<Song> _sortedSongs(List<Song> songs) {
    final list = List<Song>.from(songs);
    int compare(int result) => _sortDescending ? -result : result;
    switch (_sortBy) {
      case HubSongSort.title:
        list.sort((a, b) => compare(a.title.compareTo(b.title)));
      case HubSongSort.artist:
        list.sort((a, b) => compare(a.artist.compareTo(b.artist)));
      case HubSongSort.dateAdded:
        if (_sortDescending) return list.reversed.toList();
      case HubSongSort.playCount:
        list.sort((a, b) =>
            compare((_playCounts[a.id] ?? 0).compareTo(_playCounts[b.id] ?? 0)));
    }
    return list;
  }

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }
}

// ==================== 通用子组件 ====================

/// 分区（收藏段纵向列表用）：分区标题 + 可选「显示全部」+ 内容。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.onShowAll,
  });

  final String title;
  final Widget child;
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final sonify = SonifyColors.of(context);
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
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: SonifyTextStyles.sectionTitle.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              if (onShowAll != null)
                InkWell(
                  onTap: onShowAll,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                    child: Text(
                      '显示全部',
                      style: SonifyTextStyles.listItem.copyWith(
                        color: sonify.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // 横滑轨道首尾出血：左缘 20dp、右缘 8dp 预览（§2.4）
        child,
      ],
    );
  }
}

/// 本地段分区标题行（由 SliverToBoxAdapter 直接承载）。
class _SectionHeaderRow extends StatelessWidget {
  const _SectionHeaderRow({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.gridEdge,
        AppSpacing.xl,
        SonifySpacing.gridEdge,
        AppSpacing.md,
      ),
      child: Text(
        title,
        style: SonifyTextStyles.sectionTitle.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

/// 封面网格 sliver：按 150dp 最小封面自适应列数（coverRailMin），
/// 列距 gridH 15 / 行距 gridV 20 / 边缘 gridEdge 18（§2.4）。
class _SliverCoverGrid extends StatelessWidget {
  const _SliverCoverGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final usable = constraints.crossAxisExtent - SonifySpacing.gridEdge * 2;
        final columns =
            (usable / SonifySpacing.coverRailMin).floor().clamp(2, 6);
        return SliverPadding(
          padding: const EdgeInsets.symmetric(
            horizontal: SonifySpacing.gridEdge,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: SonifySpacing.gridH,
              mainAxisSpacing: SonifySpacing.gridV,
              childAspectRatio: 0.72,
            ),
            delegate: SliverChildBuilderDelegate(
              itemBuilder,
              childCount: itemCount,
            ),
          ),
        );
      },
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

// ==================== 收藏段轨道与列表 ====================

/// 歌单横滑轨道（FavoritesPage 同源数据；创建/收藏两个分区共用）。
class _PlaylistRail extends StatelessWidget {
  const _PlaylistRail({required this.playlists});

  final List<KugouPlaylistBrief> playlists;

  @override
  Widget build(BuildContext context) {
    const cover = _HubDimens.railCover;
    return SizedBox(
      height: cover + AppSpacing.xs + 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          SonifySpacing.titleMargin,
          0,
          AppSpacing.sm,
          0,
        ),
        itemCount: playlists.length,
        itemBuilder: (context, index) {
          final playlist = playlists[index];
          return SizedBox(
            width: cover,
            child: InkWell(
              onTap: () {
                AdaptiveNav.openDetail(
                  context,
                  (_) => PlaylistPage(
                    playlist: playlist.toPlaylist(),
                    isInMyFavorites: true,
                  ),
                );
              },
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: SizedBox(
                      width: cover,
                      height: cover,
                      child: _NetworkCover(
                        url: playlist.coverUrl,
                        placeholderIcon: Icons.queue_music,
                      ),
                    ),
                  ),
                  const Gap(AppSpacing.xs),
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SonifyTextStyles.listItem.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    '${playlist.songCount} 首',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SonifyTextStyles.listItem.copyWith(
                      color: SonifyColors.of(context).textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
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

/// 最近播放 Top 10 列表（行高 56dp：封面 44×44 圆角 8 + 标题/副行）。
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

// ==================== 本地段网格瓦片 ====================

class _LocalAlbumTile extends StatelessWidget {
  const _LocalAlbumTile({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    return InkWell(
      onTap: () {
        AdaptiveNav.openDetail(
          context,
          (_) => AlbumSongsPage(
            album: album,
            songs: library.getSongsInAlbum(album.name),
          ),
        );
      },
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // LayoutBuilder 取实宽：SmartArtworkImage 的 size 参数必须是有限值
          //（占位/加载图标按 size*0.4 缩放，传 double.infinity 会让 Icon
          // fontSize 无穷大，text_scaler 断言崩溃）。
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SmartArtworkImage(
                artworkUri: album.artworkUri,
                size: constraints.maxWidth,
                borderRadius: AppRadius.sm,
              ),
            ),
          ),
          const Gap(AppSpacing.xs),
          _TileText(title: album.name, subtitle: album.artist),
        ],
      ),
    );
  }
}

class _LocalArtistTile extends StatelessWidget {
  const _LocalArtistTile({required this.artist});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    return InkWell(
      onTap: () {
        AdaptiveNav.openDetail(
          context,
          (_) => ArtistSongsPage(
            artist: artist,
            songs: library.getSongsByArtist(artist.name),
          ),
        );
      },
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => ClipOval(
                child: SmartArtworkImage(
                  artworkUri: artist.artworkUri,
                  size: constraints.maxWidth,
                ),
              ),
            ),
          ),
          const Gap(AppSpacing.xs),
          _TileText(
            title: artist.name,
            subtitle: '${artist.albumCount} 张专辑',
          ),
        ],
      ),
    );
  }
}

// ==================== 本地段入口行 / 胶囊 / 歌曲行 ====================

/// 入口行（§2.4）：44dp、squircle 卡底 surfaceContainerHigh α0.6。
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    return SizedBox(
      height: _HubDimens.entryRowHeight,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
          shape: SmoothRectangleBorder(
            borderRadius: BorderRadius.circular(SonifyRadius.card),
          ),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: SmoothRectangleBorder(
            borderRadius: BorderRadius.circular(SonifyRadius.card),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const Gap(AppSpacing.md),
                Text(
                  label,
                  style: SonifyTextStyles.cardTitle.copyWith(
                    color: cs.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  detail,
                  style: SonifyTextStyles.listItem.copyWith(
                    color: sonify.textSecondary,
                  ),
                ),
                const Gap(AppSpacing.xs),
                Icon(Icons.chevron_right, size: 18, color: sonify.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 随机播放胶囊（§2.4）：stadium 36dp，primaryContainer 底。
class _RandomPlayPill extends StatelessWidget {
  const _RandomPlayPill({required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: _HubDimens.randomPillHeight,
      child: Material(
        color: cs.primaryContainer,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (songs.isEmpty) return;
            final shuffled = List<Song>.from(songs)..shuffle();
            context.read<PlayerProvider>().playPlaylist(shuffled, 0);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shuffle,
                    size: 16, color: cs.onPrimaryContainer),
                const Gap(AppSpacing.xs),
                Text(
                  '随机播放',
                  style: SonifyTextStyles.listItem.copyWith(
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 歌曲列表行（§2.4）：行高 56dp，封面 44×44 圆角 8。
class _SongRow extends StatelessWidget {
  const _SongRow({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sonify = SonifyColors.of(context);
    return InkWell(
      onTap: onTap,
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
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== 空态 / 扫描态 ====================

/// 扫描态（沿用面板文案，§4.5）。
class _ScanningState extends StatelessWidget {
  const _ScanningState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const M3ELoadingIndicator(),
          const Gap(AppSpacing.lg),
          Text(
            '正在扫描本地音乐...',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 本地无音乐空态（§4.5：主文案 + 副文案 + tonal 扫描钮）。
class _EmptyLibraryState extends StatelessWidget {
  const _EmptyLibraryState();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.library_music_outlined,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const Gap(AppSpacing.lg),
          Text(
            '你的音乐库还是空的',
            style: SonifyTextStyles.cardTitle.copyWith(
              color: SonifyColors.of(context).textSecondary,
            ),
          ),
          const Gap(AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SonifySpacing.titleMargin,
            ),
            child: Text(
              '扫描设备中的音乐，或先去主页听听看',
              textAlign: TextAlign.center,
              style: SonifyTextStyles.listItem.copyWith(
                color: SonifyColors.of(context).textSecondary,
              ),
            ),
          ),
          const Gap(AppSpacing.xl),
          FilledButton.tonal(
            onPressed: () {
              context.read<LibraryProvider>().loadLocalMusic();
            },
            child: const Text('扫描音乐'),
          ),
        ],
      ),
    );
  }
}

/// 分段无数据兜底（分区隐藏后整段为空时）。
class _SegmentEmptyState extends StatelessWidget {
  const _SegmentEmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
