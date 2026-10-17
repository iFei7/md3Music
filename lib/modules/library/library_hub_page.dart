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
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/m3e_pull_to_refresh_fixed.dart';
import '../../widgets/m3e_sort_sheet.dart';
import '../../widgets/smart_artwork_image.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../../widgets/common/sonify_segmented_control.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import '../artist/artist_detail_page.dart';
import '../playlist/playlist_page.dart';
import '../search/search_page.dart';
import '../user/favorites_page.dart';
import '../user/play_history_page.dart';
import 'albums_page.dart' show AlbumSongsPage;
import 'artists_page.dart' show ArtistSongsPage;
import 'library_page.dart' show LibraryPage, showLibraryScanMenu;

/// 音乐库一级页（设计方案 P0 全部 + P1 质感项）。
///
/// 页面定位：资产聚合中枢——本地扫描资产（曲目/专辑/歌手）与云端收藏
/// 资产（歌单/专辑/歌手）同屏呈现，对标 Apple Music「资料库」：
/// - 骨架：[SonifyTitleScaffold] 固定悬浮大标题「音乐库」+ 顶栏 actions
///   （扫描钮承载原 FAB 职责 / 歌曲段排序钮）+ 搜索胶囊（跳全局搜索页，
///   与首页同语义）；
/// - 分段：[SonifySegmentedControl] 4 段（最近添加｜专辑｜歌手｜歌曲），
///   固定于内容上方（与 SonifyTitleScaffold 结构兼容的吸顶等价实现：
///   分段控件不随内容滚动，内容在 PageView 内各自滚动、各自记忆位置）；
/// - 内容：PageView 四段联动，切段 [HapticFeedback.selectionClick]。
///
/// 与现有子页面的归并关系见设计方案 §1.3：云端歌单/专辑/歌手数据与
/// [FavoritesPage] 同源（[FavoriteListsCache] 缓存链路），「显示全部」
/// 仍跳 FavoritesPage 预选对应 tab；本地收藏/文件夹入口行跳
/// [LibraryPage]（initialTab 契约不变，独立路由复用）。
class LibraryHubPage extends StatefulWidget {
  const LibraryHubPage({super.key});

  @override
  State<LibraryHubPage> createState() => _LibraryHubPageState();
}

/// 分段文案（顺序即布局顺序）。
const List<String> kHubSegments = ['最近添加', '专辑', '歌手', '歌曲'];

/// 音乐库页面局部尺寸规格（设计方案 §2.4 参数表，页面内唯一来源）。
abstract final class _HubDimens {
  /// 歌单/专辑轨道封面边长。
  static const double railCover = 120;

  /// 歌手轨道头像边长（正圆）。
  static const double railAvatar = 96;

  /// 最近播放/歌曲列表行高。
  static const double rowHeight = 56;

  /// 列表行封面边长。
  static const double rowCover = 44;

  /// 入口行高度。
  static const double entryRowHeight = 44;

  /// 随机播放胶囊高度。
  static const double randomPillHeight = 36;
}

/// 「歌曲」段排序项（顶栏排序钮选项，设计方案 §4.4）。
enum HubSongSort { title, artist, dateAdded, playCount }

class _LibraryHubPageState extends State<LibraryHubPage> {
  final PageController _pageController = PageController();
  int _segmentIndex = 0;

  // 云端收藏资产（FavoritesPage 同源缓存链路，§5.1）
  List<KugouPlaylistBrief> _playlists = [];
  List<KugouPlaylistBrief> _cloudAlbums = [];
  List<Map<String, dynamic>> _cloudArtists = [];

  // 最近播放（Top 10 数据源 + 歌曲段「播放次数」排序）
  List<Song> _history = [];
  Map<String, int> _playCounts = {};

  // 歌曲段排序偏好（SettingsRepository 新 key，分段上下文持久化）
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
      // 云端分区直读 FavoriteListsCache，最近播放直读 HistoryRepository；
      // 实时网络同步仍由收藏页承载。
      _loadCloudData();
      _loadHistory();
      _loadSortPrefs();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadCloudData() async {
    final playlists = await FavoriteListsCache.readPlaylists();
    final albums = await FavoriteListsCache.readAlbums();
    final artists = await FavoriteListsCache.readArtists();
    if (!mounted) return;
    setState(() {
      _playlists = playlists;
      _cloudAlbums = albums;
      _cloudArtists = artists;
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

  /// 下拉刷新（§4.1 上下文刷新）：本地段 loadSavedSongs + 云端缓存链路
  /// + 最近播放重读。
  Future<void> _refresh() async {
    await context.read<LibraryProvider>().loadSavedSongs();
    await _loadCloudData();
    await _loadHistory();
  }

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
      // 扫描钮承载原 FAB 职责（§2.2）：扫描中转圈禁用防重复触发；
      // 排序钮仅歌曲段显示（最近添加固定时间线，专辑/歌手暂无独立排序）。
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
        if (_segmentIndex == 3)
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
              _buildSearchCapsule(context),
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
                    _buildRecentSegment(context, library),
                    _buildAlbumsSegment(context, library),
                    _buildArtistsSegment(context, library),
                    _buildSongsSegment(context, library),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==================== A. 搜索胶囊 ====================

  /// 玻璃胶囊搜索入口（§2.2）：点击跳全局搜索页（与首页同语义，
  /// 同 discover_page 的 MaterialPageRoute push）。
  Widget _buildSearchCapsule(BuildContext context) {
    final sonify = SonifyColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SonifySpacing.titleMargin,
        vertical: AppSpacing.xs,
      ),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SearchPage()),
          );
        },
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: LiquidGlassSurface(
          shape: GlassShape.pill,
          child: SizedBox(
            height: _HubDimens.entryRowHeight,
            child: Row(
              children: [
                const Gap(AppSpacing.md),
                Icon(Icons.search, size: 20, color: sonify.textSecondary),
                const Gap(AppSpacing.sm),
                Text(
                  '搜索音乐库',
                  style: SonifyTextStyles.body.copyWith(
                    color: sonify.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==================== C1. 最近添加 ====================

  Widget _buildRecentSegment(BuildContext context, LibraryProvider library) {
    final hasAnyContent =
        library.hasMusic ||
        _playlists.isNotEmpty ||
        _cloudAlbums.isNotEmpty ||
        _cloudArtists.isNotEmpty ||
        _history.isNotEmpty;

    if (!hasAnyContent) {
      return library.isScanning
          ? const _ScanningState()
          : const _EmptyLibraryState();
    }

    // 「最近添加的专辑」= 本地专辑（扫描序倒序 ≈ 添加时间序）+ 云端收藏专辑
    final recentLocalAlbums = library.albums.reversed.take(12).toList();
    final localArtists = library.artists;

    return M3EPullToRefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const PageStorageKey('hub_recent'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          if (_playlists.isNotEmpty)
            _Section(
              title: '歌单',
              onShowAll: () => _push(context, const FavoritesPage(initialTab: 0)),
              child: _PlaylistRail(playlists: _playlists),
            ),
          if (recentLocalAlbums.isNotEmpty || _cloudAlbums.isNotEmpty)
            _Section(
              title: '最近添加的专辑',
              child: _AlbumRail(
                localAlbums: recentLocalAlbums,
                cloudAlbums: _cloudAlbums.take(12).toList(),
              ),
            ),
          if (localArtists.isNotEmpty || _cloudArtists.isNotEmpty)
            _Section(
              title: '歌手',
              onShowAll: () => _push(context, const FavoritesPage(initialTab: 3)),
              child: _ArtistRail(
                localArtists: localArtists.take(12).toList(),
                cloudArtists: _cloudArtists.take(12).toList(),
              ),
            ),
          if (_history.isNotEmpty)
            _Section(
              title: '最近播放',
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

  // ==================== C2. 专辑 ====================

  Widget _buildAlbumsSegment(BuildContext context, LibraryProvider library) {
    final localAlbums = library.albums;
    if (localAlbums.isEmpty && _cloudAlbums.isEmpty) {
      return const _SegmentEmptyState(text: '暂无专辑');
    }

    return CustomScrollView(
      key: const PageStorageKey('hub_albums'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (localAlbums.isNotEmpty) ...[
          const SliverToBoxAdapter(child: _SectionHeaderRow(title: '本地的专辑')),
          _SliverCoverGrid(
            key: const PageStorageKey('hub_albums_local'),
            itemCount: localAlbums.length,
            itemBuilder: (context, index) {
              final album = localAlbums[index];
              return _LocalAlbumTile(album: album);
            },
          ),
        ],
        if (_cloudAlbums.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _SectionHeaderRow(
              title: '来自云音乐',
              trailing: '显示全部',
              onTrailingTap: () =>
                  _push(context, const FavoritesPage(initialTab: 2)),
            ),
          ),
          _SliverCoverGrid(
            key: const PageStorageKey('hub_albums_cloud'),
            itemCount: _cloudAlbums.length,
            itemBuilder: (context, index) =>
                _CloudAlbumTile(album: _cloudAlbums[index]),
          ),
        ],
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );
  }

  // ==================== C3. 歌手 ====================

  Widget _buildArtistsSegment(BuildContext context, LibraryProvider library) {
    final localArtists = library.artists;
    if (localArtists.isEmpty && _cloudArtists.isEmpty) {
      return const _SegmentEmptyState(text: '暂无歌手');
    }

    return CustomScrollView(
      key: const PageStorageKey('hub_artists'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (localArtists.isNotEmpty) ...[
          const SliverToBoxAdapter(child: _SectionHeaderRow(title: '本地的歌手')),
          _SliverCoverGrid(
            key: const PageStorageKey('hub_artists_local'),
            itemCount: localArtists.length,
            itemBuilder: (context, index) =>
                _LocalArtistTile(artist: localArtists[index]),
          ),
        ],
        if (_cloudArtists.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _SectionHeaderRow(
              title: '来自云音乐',
              trailing: '显示全部',
              onTrailingTap: () =>
                  _push(context, const FavoritesPage(initialTab: 3)),
            ),
          ),
          _SliverCoverGrid(
            key: const PageStorageKey('hub_artists_cloud'),
            itemCount: _cloudArtists.length,
            itemBuilder: (context, index) =>
                _CloudArtistTile(artist: _cloudArtists[index]),
          ),
        ],
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );
  }

  // ==================== C4. 歌曲 ====================

  Widget _buildSongsSegment(BuildContext context, LibraryProvider library) {
    if (library.isScanning && !library.hasMusic) {
      return const _ScanningState();
    }
    if (!library.hasMusic) {
      return const _EmptyLibraryState();
    }

    final songs = _sortedSongs(library.songs);

    return Column(
      children: [
        // 入口行（§2.4）：本地收藏 / 文件夹，squircle 卡底 surfaceContainerHigh α0.6
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
                onTap: () => _push(context, const LibraryPage(initialTab: 4)),
              ),
              const Gap(AppSpacing.xs),
              _EntryRow(
                key: const ValueKey('hub-entry-folders'),
                icon: Icons.folder_outlined,
                iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
                label: '文件夹',
                detail: '${library.scanFolders.length} 个目录',
                onTap: () => _push(context, const LibraryPage(initialTab: 3)),
              ),
            ],
          ),
        ),
        const Gap(AppSpacing.sm),
        // 随机播放胶囊（§2.4）：stadium，primaryContainer
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SonifySpacing.titleMargin,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: _RandomPlayPill(songs: songs),
          ),
        ),
        const Gap(AppSpacing.sm),
        Expanded(
          child: M3EPullToRefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              key: const PageStorageKey('hub_songs'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: songs.length,
              itemBuilder: (context, index) {
                return _SongRow(
                  song: songs[index],
                  onTap: () {
                    context.read<PlayerProvider>().playPlaylist(songs, index);
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 歌曲段排序（顶栏排序钮语义，§4.4）。
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

/// 分区（C1 纵向列表用）：分区标题 + 可选「显示全部」+ 内容。
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

/// C2/C3 分区标题行（由 SliverToBoxAdapter 直接承载）。
class _SectionHeaderRow extends StatelessWidget {
  const _SectionHeaderRow({
    required this.title,
    this.trailing,
    this.onTrailingTap,
  });

  final String title;
  final String? trailing;
  final VoidCallback? onTrailingTap;

  @override
  Widget build(BuildContext context) {
    final sonify = SonifyColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.gridEdge,
        AppSpacing.xl,
        SonifySpacing.gridEdge,
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
          if (trailing != null && onTrailingTap != null)
            InkWell(
              onTap: onTrailingTap,
              borderRadius: BorderRadius.circular(AppRadius.xs),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                child: Text(
                  trailing ?? '',
                  style: SonifyTextStyles.listItem.copyWith(
                    color: sonify.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// C2/C3 封面网格 sliver：按 150dp 最小封面自适应列数（coverRailMin），
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

/// 网络封面（云端歌单/专辑/歌手，缓存链路同 FavoritesPage）。
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

// ==================== C1 轨道与列表 ====================

/// 歌单横滑轨道（FavoritesPage 同源数据）。
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

/// 最近添加专辑横滑轨道：本地（扫描序倒序）+ 云端收藏。
class _AlbumRail extends StatelessWidget {
  const _AlbumRail({required this.localAlbums, required this.cloudAlbums});

  final List<Album> localAlbums;
  final List<KugouPlaylistBrief> cloudAlbums;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
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
        itemCount: localAlbums.length + cloudAlbums.length,
        itemBuilder: (context, index) {
          if (index < localAlbums.length) {
            final album = localAlbums[index];
            return _RailCoverItem(
              width: cover,
              artwork: SmartArtworkImage(
                artworkUri: album.artworkUri,
                size: cover,
                borderRadius: AppRadius.sm,
              ),
              title: album.name,
              subtitle: album.artist,
              onTap: () {
                AdaptiveNav.openDetail(
                  context,
                  (_) => AlbumSongsPage(
                    album: album,
                    songs: library.getSongsInAlbum(album.name),
                  ),
                );
              },
            );
          }
          final cloud = cloudAlbums[index - localAlbums.length];
          return _RailCoverItem(
            width: cover,
            artwork: _NetworkCover(url: cloud.coverUrl, placeholderIcon: Icons.album),
            title: cloud.name,
            subtitle: '${cloud.songCount} 首',
            onTap: () {
              AdaptiveNav.openDetail(
                context,
                (_) => PlaylistPage(
                  playlist: cloud.toPlaylist(),
                  isInMyFavorites: true,
                  isAlbum: true,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 歌手头像横滑轨道：本地（正圆 96）+ 云端关注歌手。
class _ArtistRail extends StatelessWidget {
  const _ArtistRail({required this.localArtists, required this.cloudArtists});

  final List<Artist> localArtists;
  final List<Map<String, dynamic>> cloudArtists;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    const avatar = _HubDimens.railAvatar;
    return SizedBox(
      height: avatar + AppSpacing.xs + 22,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          SonifySpacing.titleMargin,
          0,
          AppSpacing.sm,
          0,
        ),
        itemCount: localArtists.length + cloudArtists.length,
        itemBuilder: (context, index) {
          if (index < localArtists.length) {
            final artist = localArtists[index];
            return _RailCoverItem(
              width: avatar,
              artwork: ClipOval(
                child: SmartArtworkImage(
                  artworkUri: artist.artworkUri,
                  size: avatar,
                ),
              ),
              title: artist.name,
              onTap: () {
                AdaptiveNav.openDetail(
                  context,
                  (_) => ArtistSongsPage(
                    artist: artist,
                    songs: library.getSongsByArtist(artist.name),
                  ),
                );
              },
            );
          }
          final cloud = cloudArtists[index - localArtists.length];
          final name =
              (cloud['nickname'] ?? cloud['user_name'] ?? cloud['name'] ?? '')
                  .toString();
          final avatarUrl = _fixImageUrl(
            (cloud['pic'] ??
                    cloud['user_pic'] ??
                    cloud['user_img'] ??
                    cloud['avatar'])
                ?.toString(),
          );
          final id =
              cloud['singerid']?.toString() ??
              cloud['userid']?.toString() ??
              cloud['id']?.toString() ??
              '';
          return _RailCoverItem(
            width: avatar,
            artwork: ClipOval(
              child: _NetworkCover(url: avatarUrl, placeholderIcon: Icons.person),
            ),
            title: name,
            onTap: () {
              AdaptiveNav.openDetail(
                context,
                (_) => ArtistDetailPage(
                  artistId: id,
                  artistName: name,
                  avatarUrl: avatarUrl,
                  initialIsFollowed: true,
                ),
              );
            },
          );
        },
      ),
    );
  }

  String? _fixImageUrl(String? url) {
    if (url == null) return null;
    return url.startsWith('http://')
        ? url.replaceFirst('http://', 'https://')
        : url;
  }
}

/// 轨道通用封面项：封面 + 名称（+ 次级行）。
class _RailCoverItem extends StatelessWidget {
  const _RailCoverItem({
    required this.width,
    required this.artwork,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final double width;
  final Widget artwork;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: width, height: width, child: artwork),
            const Gap(AppSpacing.xs),
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
                  color: SonifyColors.of(context).textSecondary,
                ),
              ),
          ],
        ),
      ),
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

// ==================== C2/C3 网格瓦片 ====================

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

class _CloudAlbumTile extends StatelessWidget {
  const _CloudAlbumTile({required this.album});

  final KugouPlaylistBrief album;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        AdaptiveNav.openDetail(
          context,
          (_) => PlaylistPage(
            playlist: album.toPlaylist(),
            isInMyFavorites: true,
            isAlbum: true,
          ),
        );
      },
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: _NetworkCover(url: album.coverUrl, placeholderIcon: Icons.album),
            ),
          ),
          const Gap(AppSpacing.xs),
          _TileText(title: album.name, subtitle: '${album.songCount} 首'),
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

class _CloudArtistTile extends StatelessWidget {
  const _CloudArtistTile({required this.artist});

  final Map<String, dynamic> artist;

  @override
  Widget build(BuildContext context) {
    final name =
        (artist['nickname'] ?? artist['user_name'] ?? artist['name'] ?? '')
            .toString();
    final avatarUrl = _fixImageUrl(
      (artist['pic'] ?? artist['user_pic'] ?? artist['user_img'] ?? artist['avatar'])
          ?.toString(),
    );
    final id =
        artist['singerid']?.toString() ??
        artist['userid']?.toString() ??
        artist['id']?.toString() ??
        '';
    return InkWell(
      onTap: () {
        AdaptiveNav.openDetail(
          context,
          (_) => ArtistDetailPage(
            artistId: id,
            artistName: name,
            avatarUrl: avatarUrl,
            initialIsFollowed: true,
          ),
        );
      },
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipOval(
              child: _NetworkCover(url: avatarUrl, placeholderIcon: Icons.person),
            ),
          ),
          const Gap(AppSpacing.xs),
          _TileText(title: name),
        ],
      ),
    );
  }

  String? _fixImageUrl(String? url) {
    if (url == null) return null;
    return url.startsWith('http://')
        ? url.replaceFirst('http://', 'https://')
        : url;
  }
}

// ==================== C4 入口行 / 胶囊 / 歌曲行 ====================

/// C4 入口行（§2.4）：44dp、squircle 卡底 surfaceContainerHigh α0.6。
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
