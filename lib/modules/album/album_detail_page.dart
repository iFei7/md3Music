import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/motion_constants.dart';
import '../../core/utils/app_toast.dart';
import '../../core/widgets/app_background.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../data/repositories/collected_playlist_store.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_collection_notifier.dart';
import '../../providers/theme_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/keyboard_expand_sheet.dart';
import '../../widgets/m3e_sort_sheet.dart';
import '../../widgets/playlist_comments_view.dart';
import '../../widgets/song_list_item.dart';

class AlbumDetailPage extends StatefulWidget {
  final Album album;

  const AlbumDetailPage({super.key, required this.album});

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

enum _SortBy { time, title, duration }

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  /// 大封面头图展开高度（批次 3 重构：沉浸式头图 + 滚动折叠）
  static const double _expandedHeight = 440;

  /// 头图内大封面的最大边长
  static const double _maxCoverSize = 250;

  bool _isLoading = true;
  List<Song> _songs = [];
  String? _error;
  KugouAlbumDetail? _albumDetail;

  // 排序
  _SortBy _sortBy = _SortBy.time;
  bool _sortAscending = false;

  // 专辑内搜索
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // 定位正在播放歌曲
  String? _highlightSongId;

  // 专辑介绍展开/折叠
  bool _isDescriptionExpanded = false;

  // 收藏状态
  bool _isCollected = false;
  String? _collectedListId;

  // 滚动监听
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;
  double _lastReportedOffset = 0;

  // 缓存的过滤/排序结果
  List<Song>? _cachedDisplaySongs;
  String? _lastSearchQuery;
  _SortBy? _lastSortBy;
  bool? _lastSortAscending;

  List<Song> get _displaySongs {
    if (_cachedDisplaySongs != null &&
        _lastSearchQuery == _searchQuery &&
        _lastSortBy == _sortBy &&
        _lastSortAscending == _sortAscending) {
      return _cachedDisplaySongs!;
    }
    _rebuildDisplaySongs();
    return _cachedDisplaySongs!;
  }

  void _rebuildDisplaySongs() {
    List<Song> list;
    if (_searchQuery.isEmpty) {
      list = List.of(_songs);
    } else {
      final q = _searchQuery.toLowerCase();
      list = _songs.where((s) {
        return s.title.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q) ||
            (s.album?.toLowerCase().contains(q) ?? false);
      }).toList();
    }
    list.sort((a, b) {
      int cmp;
      switch (_sortBy) {
        case _SortBy.time:
          cmp = _songs.indexOf(a).compareTo(_songs.indexOf(b));
          break;
        case _SortBy.title:
          cmp = a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
          break;
        case _SortBy.duration:
          cmp = a.duration.compareTo(b.duration);
          break;
      }
      return _sortAscending ? cmp : -cmp;
    });
    _cachedDisplaySongs = list;
    _lastSearchQuery = _searchQuery;
    _lastSortBy = _sortBy;
    _lastSortAscending = _sortAscending;
  }

  void _invalidateDisplaySongs() {
    _cachedDisplaySongs = null;
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchAlbum();
      _checkCollected();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted) return;
    final offset = _scrollController.offset;
    if ((offset - _lastReportedOffset).abs() > 1.0) {
      _lastReportedOffset = offset;
      _scrollOffset = offset;
      setState(() {});
    }
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
        _invalidateDisplaySongs();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      }
    });
  }

  void _scrollToPlayingSong() {
    final player = context.read<PlayerProvider>();
    final currentSong = player.currentSong;
    if (currentSong == null) return;

    final displayList = _displaySongs;
    final index = displayList.indexWhere((s) => s.id == currentSong.id);
    if (index == -1) return;

    setState(() => _highlightSongId = currentSong.id);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightSongId = null);
    });

    const itemHeight = 72.0;
    final targetOffset = index * itemHeight;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _fetchAlbum() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final api = KugouApiClient();
      final detailFuture = api.getAlbumDetail(widget.album.id);
      final songsFuture = api.getAlbumSongs(widget.album.id);

      final results = await Future.wait([detailFuture, songsFuture]);

      final detail = results[0] as KugouAlbumDetail?;
      final songsResult = results[1] as KugouAlbumSongs?;

      setState(() {
        _albumDetail = detail;
        _songs = songsResult?.songs.map((e) => e.toSong()).toList() ?? [];
        _invalidateDisplaySongs();
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
    setState(() {
      _isLoading = false;
    });
  }

  // ==================== 收藏 ====================

  Future<void> _checkCollected() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;

    final cached = await CollectedPlaylistStore.getListId(widget.album.id);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _isCollected = true;
          _collectedListId = cached;
        });
      }
      return;
    }

    final listid = await _findCollectedListId(api);
    if (listid != null && mounted) {
      await CollectedPlaylistStore.setListId(widget.album.id, listid);
      setState(() {
        _isCollected = true;
        _collectedListId = listid;
      });
    }
  }

  Future<String?> _findCollectedListId(KugouApiClient api) async {
    try {
      final result = await api.getUserPlaylist(pagesize: 50);
      if (result == null) return null;
      final data = result['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>?;
        list ??= data['list'] as List<dynamic>?;
      }
      if (list == null) return null;
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final gid = item['global_collection_id']?.toString() ?? '';
          final name = item['name']?.toString() ?? '';
          if (gid == widget.album.id || name == widget.album.name) {
            return item['listid']?.toString();
          }
        }
      }
    } catch (e) {
      // 忽略
    }
    return null;
  }

  Future<void> _collectAlbum() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) {
      if (mounted) {
        showToast('请先登录', long: true);
      }
      return;
    }

    // 乐观更新：立即显示已收藏状态
    setState(() {
      _isCollected = true;
    });

    try {
      String artistId = _albumDetail?.artistId ?? '';
      if (artistId.isEmpty && _songs.isNotEmpty) {
        artistId = _songs.first.artistId ?? '';
      }
      final result = await api.collectAlbum(
        widget.album.name,
        artistId: artistId,
        albumId: widget.album.id,
      );
      if (result == null) {
        // 回滚
        if (mounted) {
          setState(() { _isCollected = false; });
          showToast('收藏失败，请重试', long: true);
        }
        return;
      }
      String? newId = await _findCollectedListId(api);
      await CollectedPlaylistStore.setListId(widget.album.id, newId);
      if (mounted) {
        setState(() { _collectedListId = newId; });
        context.read<PlaylistCollectionNotifier>().notifyChanged();
      }
    } catch (e) {
      // 回滚
      if (mounted) {
        setState(() { _isCollected = false; });
        showToast('收藏失败', long: true);
      }
    }
  }

  Future<void> _uncollectAlbum() async {
    final api = KugouApiClient();
    if (!api.isLoggedIn) return;

    // 乐观更新：立即显示未收藏状态
    setState(() {
      _isCollected = false;
    });

    String? listId = await CollectedPlaylistStore.getListId(widget.album.id);
    listId ??= _collectedListId;
    listId ??= await _findCollectedListId(api);
    if (listId == null || listId.isEmpty) {
      if (mounted) {
        setState(() { _isCollected = true; });
        showToast('找不到收藏记录，无法取消', long: true);
      }
      return;
    }

    try {
      final result = await api.deletePlaylist(listId, type: 0);
      if (result != null && mounted) {
        await CollectedPlaylistStore.remove(widget.album.id);
        setState(() { _collectedListId = null; });
        context.read<PlaylistCollectionNotifier>().notifyChanged();
      } else if (mounted) {
        // 回滚
        setState(() { _isCollected = true; });
        showToast('取消收藏失败，请重试', long: true);
      }
    } catch (e) {
      if (mounted) {
        // 回滚
        setState(() { _isCollected = true; });
        showToast('取消收藏失败', long: true);
      }
    }
  }

  // ==================== 评论 ====================

  void _showCommentsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => KeyboardExpandScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        // 键盘弹出时也展开到这个高度，否则打字时列表被托盘比例限制成一条缝
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          final colorScheme = Theme.of(context).colorScheme;
          return Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: AppSpacing.md),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                  child: Row(
                    children: [
                      Icon(Icons.comment_outlined, size: 20, color: colorScheme.onSurfaceVariant),
                      const Gap(AppSpacing.sm),
                      Text(
                        '评论',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
                Expanded(
                  child: PlaylistCommentsView(
                    specialId: widget.album.globalCollectionId ?? widget.album.id,
                    commentType: 'album',
                    scrollController: scrollController,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final useBackgroundImage =
        context.watch<ThemeProvider>().useBackgroundImage;
    // 字段级 fallback：API 返回的 albumDetail 优先，但其 artworkUri 为 null 时
    // 保留传入的 widget.album.artworkUri（即 song.artworkUri），避免丢失初始封面
    final apiAlbum = _albumDetail?.toAlbum();
    final displayAlbum = apiAlbum != null
        ? (apiAlbum.artworkUri == null && widget.album.artworkUri != null
            ? apiAlbum.copyWith(artworkUri: widget.album.artworkUri)
            : apiAlbum)
        : widget.album;
    final description = _albumDetail?.description;

    return Scaffold(
      body: _isLoading
        ? const Center(child: M3ELoadingIndicator())
        : _error != null
            ? _buildError(context, colorScheme)
            : Column(
                children: [
                  Expanded(
                    child: CustomScrollView(
                      controller: _scrollController,
                      slivers: [
                        SliverAppBar(
                          expandedHeight: _expandedHeight,
                          pinned: true,
                          // 背景图模式：顶栏恒透明——flexibleSpace 是普通 Stack
                          // （非 FlexibleSpaceBar，折叠时不产生视差位移，壁纸层顶部
                          // 固定裁剪），任意滚动位置壁纸都与主体背景对齐、不透 UI；
                          // 非背景图：上划渐变到 surface（遮住列表不穿透）
                          backgroundColor: useBackgroundImage
                              ? Colors.transparent
                              : Color.lerp(
                                  Colors.transparent,
                                  colorScheme.surface,
                                  (_scrollOffset -
                                          (_expandedHeight - kToolbarHeight))
                                      .clamp(0.0, 60.0) / 60,
                                )!,
                          surfaceTintColor: Colors.transparent,
                          scrolledUnderElevation: 0,
                          actions: [
                            if (_songs.isNotEmpty)
                              IconButton(
                                icon: Icon(_isSearching ? Icons.close : Icons.search),
                                onPressed: _toggleSearch,
                              ),
                            if (_songs.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.comment_outlined),
                                onPressed: () => _showCommentsSheet(context),
                                tooltip: '评论',
                              ),
                            if (_songs.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.my_location),
                                onPressed: _scrollToPlayingSong,
                                tooltip: '定位正在播放',
                              ),
                            if (_songs.isNotEmpty)
                              M3ESortButton<_SortBy>(
                                tooltip: '排序',
                                current: _sortBy,
                                options: const [
                                  (value: _SortBy.time, label: '添加时间'),
                                  (value: _SortBy.title, label: '歌曲名称'),
                                  (value: _SortBy.duration, label: '时长'),
                                ],
                                onPicked: (value, repeated) {
                                  setState(() {
                                    if (repeated) {
                                      // 再次点当前项 → 翻转升/降序
                                      _sortAscending = !_sortAscending;
                                    } else {
                                      _sortBy = value;
                                      _sortAscending = value == _SortBy.time ? false : true;
                                    }
                                    _invalidateDisplaySongs();
                                  });
                                },
                              ),
                          ],
                          title: Opacity(
                            opacity: ((_scrollOffset -
                                        (_expandedHeight - kToolbarHeight)) /
                                    60.0)
                                .clamp(0.0, 1.0),
                            child: Text(
                              displayAlbum.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          // 大封面头图（批次 3 重构）：封面居中沉浸式展示，
                          // 折叠时随可用高度平滑缩小并淡出。全程 Positioned
                          // 定高、无 Flex 布局，不会触发 RenderFlex overflow；
                          // 标题移至头图下方内容区，折叠后由工具栏标题渐现接棒。
                          // 背景图模式保持壁纸层顶部固定裁剪、与主体背景对齐。
                          flexibleSpace: ClipRect(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final safeTop = MediaQuery.paddingOf(context).top;
                                // 内容区高度：扣除状态栏与工具栏，折叠过程中平滑收缩到 0
                                final availH =
                                    (constraints.maxHeight - kToolbarHeight - safeTop)
                                        .clamp(0.0, constraints.maxHeight);
                                // 大封面：高度充足时保持最大边长，折叠时随可用高度缩小
                                final coverSize = (availH - AppSpacing.xl)
                                    .clamp(0.0, _maxCoverSize)
                                    .clamp(0.0, constraints.maxWidth - 2 * AppSpacing.lg);
                                // 折叠后半段淡出封面，与工具栏标题渐现衔接，减少视觉跳动
                                final coverOpacity = (availH / 140.0).clamp(0.0, 1.0);
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (useBackgroundImage)
                                      const WallpaperHeaderBackground(),
                                    Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            // 开启壁纸时主题色渐变半透明叠加在壁纸上，
                                            // 渐变可见且壁纸透出；未开启时实色渐变
                                            useBackgroundImage
                                                ? colorScheme.primaryContainer
                                                    .withValues(alpha: 0.35)
                                                : colorScheme.primaryContainer,
                                            // 底部渐变到透明：启用全局背景图（页面背景透明）时，
                                            // 若此处仍是实色 surface 会与下方背景图形成接缝穿帮。
                                            colorScheme.surface.withValues(alpha: 0),
                                          ],
                                        ),
                                      ),
                                    ),
                                    // 大封面：工具栏下方居中，随折叠缩小/淡出
                                    Positioned(
                                      top: kToolbarHeight + AppSpacing.sm,
                                      left: 0,
                                      right: 0,
                                      height: coverSize,
                                      child: Center(
                                        child: Opacity(
                                          opacity: coverOpacity,
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              borderRadius: AppRadius.cardAll,
                                              boxShadow: [
                                                BoxShadow(
                                                  color: colorScheme.scrim
                                                      .withValues(alpha: 0.35),
                                                  blurRadius: 24,
                                                  offset: const Offset(0, 8),
                                                ),
                                              ],
                                            ),
                                            child: ClipRRect(
                                              borderRadius: AppRadius.cardAll,
                                              child: SizedBox(
                                                width: coverSize,
                                                height: coverSize,
                                                child: displayAlbum.artworkUri != null
                                                    ? CachedNetworkImage(
                                                        imageUrl: displayAlbum.artworkUri!,
                                                        memCacheWidth: 420,
                                                        memCacheHeight: 420,
                                                        fit: BoxFit.cover,
                                                        placeholder: (_, _) => Container(
                                                          color: colorScheme.surfaceContainerHighest,
                                                          child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant),
                                                        ),
                                                        errorWidget: (_, _, _) => Container(
                                                          color: colorScheme.surfaceContainerHighest,
                                                          child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant),
                                                        ),
                                                      )
                                                    : Container(
                                                        color: colorScheme.surfaceContainerHighest,
                                                        child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant),
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                      ),
                        // 标题区（批次 3：从头图内移到内容区，折叠时由工具栏标题接棒）
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.none),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  displayAlbum.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                if (displayAlbum.artist.isNotEmpty) ...[
                                  const Gap(AppSpacing.xs),
                                  Text(
                                    displayAlbum.artist,
                                    style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                  ),
                                ],
                                const Gap(AppSpacing.xs),
                                Text(
                                  '${_songs.length} 首歌曲',
                                  style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // 专辑介绍
                        if (description != null && description.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.none),
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _isDescriptionExpanded = !_isDescriptionExpanded;
                                  });
                                },
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(AppSpacing.md),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                                    borderRadius: AppRadius.mdAll,
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.info_outline, size: 16, color: colorScheme.onSurfaceVariant),
                                          const SizedBox(width: 6),
                                          Text(
                                            '专辑介绍',
                                            style: textTheme.labelLarge?.copyWith(color: colorScheme.onSurfaceVariant),
                                          ),
                                          const Spacer(),
                                          AnimatedRotation(
                                            turns: _isDescriptionExpanded ? 0.5 : 0,
                                            duration: AppMotion.fast,
                                            child: Icon(Icons.keyboard_arrow_down, size: 20, color: colorScheme.onSurfaceVariant),
                                          ),
                                        ],
                                      ),
                                      const Gap(AppSpacing.sm),
                                      AnimatedSize(
                                        duration: AppMotion.medium,
                                        curve: Curves.easeInOut,
                                        alignment: Alignment.topCenter,
                                        clipBehavior: Clip.hardEdge,
                                        child: Text(
                                          description,
                                          maxLines: _isDescriptionExpanded ? null : 2,
                                          overflow: _isDescriptionExpanded ? null : TextOverflow.ellipsis,
                                          style: textTheme.bodyMedium?.copyWith(
                                            color: colorScheme.onSurfaceVariant,
                                            height: 1.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // 搜索栏
                        if (_isSearching)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.none),
                              child: TextField(
                                controller: _searchController,
                                focusNode: _searchFocusNode,
                                decoration: InputDecoration(
                                  hintText: '搜索专辑内的歌曲...',
                                  prefixIcon: const Icon(Icons.search),
                                  suffixIcon: _searchQuery.isNotEmpty
                                      ? IconButton(
                                          icon: const Icon(Icons.clear),
                                          onPressed: () {
                                            _searchController.clear();
                                            setState(() {
                                              _searchQuery = '';
                                              _invalidateDisplaySongs();
                                            });
                                          },
                                        )
                                      : null,
                                  filled: true,
                                  fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                                  border: OutlineInputBorder(
                                    borderRadius: AppRadius.xlAll,
                                    borderSide: BorderSide.none,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                                ),
                                onChanged: (value) {
                                  setState(() {
                                    _searchQuery = value;
                                    _invalidateDisplaySongs();
                                  });
                                },
                              ),
                            ),
                          ),
                        // 操作条（批次 3）：播放全部 / 随机播放 / 收藏 集中一行，
                        // surfaceContainerHigh 层次底 + 胶囊形，热区 ≥44dp
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHigh
                                    .withValues(alpha: useBackgroundImage ? 0.72 : 1.0),
                                borderRadius: BorderRadius.circular(AppRadius.full),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () {
                                        final songs = _displaySongs;
                                        if (songs.isNotEmpty) {
                                          context.read<PlayerProvider>().playOnlinePlaylist(songs, 0);
                                        }
                                      },
                                      icon: const Icon(Icons.play_arrow),
                                      label: Text(
                                        '播放全部${_isSearching && _searchQuery.isNotEmpty ? ' (${_displaySongs.length})' : ''}',
                                      ),
                                      style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
                                    ),
                                  ),
                                  const Gap(AppSpacing.xs),
                                  IconButton.filledTonal(
                                    onPressed: () {
                                      final songs = _displaySongs;
                                      if (songs.isNotEmpty) {
                                        final shuffled = List<Song>.from(songs)..shuffle();
                                        context.read<PlayerProvider>().playOnlinePlaylist(shuffled, 0);
                                      }
                                    },
                                    icon: const Icon(Icons.shuffle),
                                    tooltip: '随机播放',
                                  ),
                                  IconButton.filledTonal(
                                    onPressed: _isCollected ? _uncollectAlbum : _collectAlbum,
                                    icon: Icon(
                                      _isCollected ? Icons.favorite : Icons.favorite_border,
                                      color: _isCollected ? colorScheme.error : null,
                                    ),
                                    tooltip: _isCollected ? '取消收藏' : '收藏',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // 歌曲列表
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final song = _displaySongs[index];
                              final isHighlighted = _highlightSongId == song.id;
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                color: isHighlighted
                                    ? colorScheme.primaryContainer.withValues(alpha: 0.5)
                                    : Colors.transparent,
                                child: SongListItem(
                                  song: song,
                                  onTap: () {
                                    context.read<PlayerProvider>().playOnlinePlaylist(_displaySongs, index);
                                  },
                                  onMoreTap: () {},
                                ),
                              );
                            },
                            childCount: _displaySongs.length,
                          ),
                        ),
                        // 搜索无结果
                        if (_isSearching && _displaySongs.isEmpty && _songs.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.xxl),
                              child: Column(
                                children: [
                                  Icon(Icons.search_off, size: 48, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                                  const Gap(AppSpacing.sm),
                                  Text(
                                    '没有找到「$_searchQuery」相关的歌曲',
                                    style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
    );
  }

  Widget _buildError(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 48, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const Gap(AppSpacing.md),
            Text(
              '加载失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const Gap(AppSpacing.sm),
            Text(
              _error ?? '未知错误',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const Gap(AppSpacing.lg),
            FilledButton.tonal(onPressed: _fetchAlbum, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
