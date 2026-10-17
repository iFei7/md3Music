import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/layout/adaptive_navigator.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../data/models/song.dart';
import '../../data/repositories/favorite_lists_cache.dart';
import '../../data/repositories/history_repository.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import '../../widgets/m3e_pull_to_refresh_fixed.dart';
import '../../widgets/smart_artwork_image.dart';
import '../playlist/playlist_page.dart';
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
/// - 入口区：2×2 squircle 卡片（收藏 / 本地 / 已购 / 云盘），点击分别
///   压入 [FavoritesPage(initialTab: 0)]（歌单段）/ [LibraryPage]（曲目段）
///   / [PurchasedPage]（单曲+专辑双切换）/ [CloudMusicPage]（完整管理）；
/// - 列表分区：最近播放 Top 10 + 我创建的歌单 + 我收藏的歌单
///   （创建/收藏区分与 [FavoritesPage] 同款规则，见 [_isCreatedPlaylist]）；
/// - 歌单为空时分区显示空态文案即可，登录引导由目标子页自行处理。
class LibraryHubPage extends StatefulWidget {
  const LibraryHubPage({super.key});

  @override
  State<LibraryHubPage> createState() => _LibraryHubPageState();
}

/// 音乐库页面局部尺寸规格（页面内唯一来源）。
abstract final class _HubDimens {
  /// 歌单轨道封面边长。
  static const double railCover = 120;

  /// 最近播放列表行高。
  static const double rowHeight = 56;

  /// 列表行封面边长。
  static const double rowCover = 44;

  /// 入口卡片最小高度（2×2 网格两行等高）。
  static const double entryCardMinHeight = 88;

  /// 入口卡片图标边长。
  static const double entryCardIcon = 22;

  /// 顶栏玻璃圆钮边长（与首页顶栏搜索钮同规格，discover_page 42dp）。
  static const double barButton = 42;

  /// 顶栏玻璃圆钮图标边长（同首页 20dp）。
  static const double barButtonIcon = 20;
}

class _LibraryHubPageState extends State<LibraryHubPage> {
  // 云端歌单（FavoritesPage 同源缓存链路；区分「创建 vs 收藏」见
  // _isCreatedPlaylist。云端收藏专辑/歌手不进 IA（归属收藏语义，由
  // FavoritesPage 承载）。
  List<KugouPlaylistBrief> _playlists = [];

  // 最近播放（Top 10 数据源）
  List<Song> _history = [];
  Map<String, int> _playCounts = {};

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

  /// 下拉刷新：本地歌曲缓存（入口卡计数）+ 歌单缓存链路 + 最近播放重读。
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

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
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
                  onShowAll: () => _push(context, const PlayHistoryPage()),
                  child: _history.isEmpty
                      ? const _SectionEmptyText('暂无播放记录')
                      : _RecentPlayList(
                          songs: _history.take(10).toList(),
                          playCounts: _playCounts,
                        ),
                ),
                _Section(
                  title: '我创建的歌单',
                  child: _buildPlaylistSection(
                    _createdPlaylists,
                    emptyText: '暂无创建的歌单',
                  ),
                ),
                _Section(
                  title: '我收藏的歌单',
                  child: _buildPlaylistSection(
                    _collectedPlaylists,
                    emptyText: '暂无收藏的歌单',
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
                onTap: () =>
                    _push(context, const FavoritesPage(initialTab: 0)),
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

  /// 歌单分区内容：有数据走横滑轨，空数据显示空态文案。
  Widget _buildPlaylistSection(
    List<KugouPlaylistBrief> playlists, {
    required String emptyText,
  }) {
    if (playlists.isEmpty) {
      return _SectionEmptyText(emptyText);
    }
    return _PlaylistRail(playlists: playlists);
  }
}

// ==================== 通用子组件 ====================

/// 分区（纵向列表用）：分区标题 + 可选「显示全部」+ 内容。
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

/// 入口卡片（2×2 网格单格）：squircle 卡底 surfaceContainerHigh α0.6 +
/// primary 图标 + 标题/副标题（配方同 library_page 入口区）。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

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
                ],
              ),
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

// ==================== 歌单轨道与最近播放 ====================

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
