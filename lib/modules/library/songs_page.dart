import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../widgets/m3e_sort_sheet.dart';
import '../../widgets/song_list_item.dart';
import '../../widgets/common/multi_select_controller.dart';

enum SongSortBy { title, artist, dateAdded }

/// 曲目列表视图形态（方案 §4.1「曲目页加切换钮」）。
enum _SongsViewMode { list, grid }

class SongsPage extends StatefulWidget {
  final List<Song> songs;

  const SongsPage({super.key, required this.songs});

  @override
  State<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends State<SongsPage> {
  /// 排序选择的持久化 key（记忆本地歌曲排序：切页返回后保持上次选择）。
  static const String _kSortByKey = 'local_songs_sort_by';
  static const String _kSortDescKey = 'local_songs_sort_desc';
  /// 视图形态持久化 key（方案 §4.3：对齐 SongSortBy 的 SharedPreferences 模式）。
  static const String _kViewModeKey = 'local_songs_view_mode';

  SongSortBy _sortBy = SongSortBy.title;
  // 排序方向：true=倒序(Z→A)，false=正序(A→Z)
  bool _sortDescending = false;
  _SongsViewMode _viewMode = _SongsViewMode.list;

  // 多选：复用公共 MultiSelectController（方案 §4.1，与歌单/专辑/歌手页一致）。
  // 批量操作收敛为「播放所选」（playPlaylist 既有播放链路零改动）；
  // 加入队列/加入歌单无既有基建，缺省（见批次回报）。
  final MultiSelectController _multiSelect = MultiSelectController();

  final ScrollController _scrollController = ScrollController();
  // 定位目标项的索引与 GlobalKey：滚到位后用 ensureVisible 精确对齐。
  GlobalKey? _targetItemKey;
  int _targetScrollIndex = -1;

  @override
  void initState() {
    super.initState();
    _multiSelect.addListener(_onMultiSelectChanged);
    _loadSortPreference();
    _loadViewMode();
  }

  /// 多选状态翻转 → 页面重建。
  void _onMultiSelectChanged() {
    if (mounted) setState(() {});
  }

  /// 恢复上次的排序选择（读取失败/无记录时保持默认按标题）。
  Future<void> _loadSortPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sortBy = SongSortBy.values.firstWhere(
        (e) => e.name == prefs.getString(_kSortByKey),
        orElse: () => SongSortBy.title,
      );
      _sortDescending = prefs.getBool(_kSortDescKey) ?? false;
    });
  }

  /// 持久化当前排序选择，供下次进入本地音乐页恢复。
  Future<void> _saveSortPreference() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSortByKey, _sortBy.name);
    await prefs.setBool(_kSortDescKey, _sortDescending);
  }

  /// 恢复上次的视图形态（list/grid，读取失败保持列表）。
  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _viewMode = prefs.getString(_kViewModeKey) == 'grid'
          ? _SongsViewMode.grid
          : _SongsViewMode.list;
    });
  }

  Future<void> _toggleViewMode() async {
    setState(() {
      _viewMode = _viewMode == _SongsViewMode.list
          ? _SongsViewMode.grid
          : _SongsViewMode.list;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kViewModeKey, _viewMode.name);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _multiSelect.removeListener(_onMultiSelectChanged);
    _multiSelect.dispose();
    super.dispose();
  }

  void _playAt(List<Song> songs, int index) {
    context.read<PlayerProvider>().playPlaylist(songs, index);
  }

  /// 定位当前播放歌曲并在视口中居中。
  ///
  /// 行高不是常量：SongListItem 的高度取封面（52）与文字列（随 uiScale
  /// 0.5~2.0 变化）中较高者，故不能用固定值换算偏移。这里改为从
  /// ScrollPosition 反推实测行高——本列表所有项等高，此时 Flutter 对
  /// SliverChildBuilderDelegate 的 extent 估算恰好精确——再用 GlobalKey +
  /// ensureVisible 做最终对齐，消除任何残余偏差。
  Future<void> _scrollToCurrentSong(int index) async {
    if (!_scrollController.hasClients) return;

    setState(() {
      // 每次定位新建 GlobalKey，避免旧 key 残留导致重复 GlobalKey 冲突
      _targetItemKey = GlobalKey();
      _targetScrollIndex = index;
    });
    // 等一帧让 GlobalKey 挂到目标项上（目标项已在视口内时可直接命中）
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scrollController.hasClients) return;

    final pos = _scrollController.position;
    final viewport = pos.viewportDimension;
    // 实测行高：内容总高 ÷ 项数（ListView 无 padding，所有项等高）
    final rowHeight = (pos.maxScrollExtent + viewport) / widget.songs.length;
    // 让目标项落在视口正中，而非按屏幕高度取比例
    final target = index * rowHeight - (viewport - rowHeight) / 2;
    await _scrollController.animateTo(
      target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;

    // 滚动后目标项已构建：精确居中
    final targetContext = _targetItemKey?.currentContext;
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    }
  }

  List<Song> get _sortedSongs {
    final songs = List<Song>.from(widget.songs);
    // 统一的方向比较器：升序返回 a 与 b 的差；降序取反即可。
    int compare<T>(T a, T b, int Function(T, T) asc) {
      final result = asc(a, b);
      return _sortDescending ? -result : result;
    }

    switch (_sortBy) {
      case SongSortBy.title:
        songs.sort(
            (a, b) => compare(a.title, b.title, (x, y) => x.compareTo(y)));
        break;
      case SongSortBy.artist:
        songs.sort(
            (a, b) => compare(a.artist, b.artist, (x, y) => x.compareTo(y)));
        break;
      case SongSortBy.dateAdded:
        // 添加时间排序：原列表顺序视为添加顺序，倒序时整体反转
        if (_sortDescending) {
          return songs.reversed.toList();
        }
        break;
    }
    return songs;
  }

  /// 网格列数：150dp 自适应（sonify AdaptiveImageLayout.kt:9 min 尺寸语义）。
  int _gridColumns(double width) => (width / SonifySpacing.coverRailMin)
      .floor()
      .clamp(2, 6);

  void _onItemTap(List<Song> songs, int index) {
    final song = songs[index];
    if (_multiSelect.isSelectMode) {
      _multiSelect.toggle(song.id);
    } else {
      _playAt(songs, index);
    }
  }

  void _onItemLongPress(List<Song> songs, int index) {
    final song = songs[index];
    if (_multiSelect.isSelectMode) return;
    _multiSelect.enterSelectMode(song.id);
  }

  /// 批量播放所选（复用 playPlaylist 既有链路）。
  void _playSelected(List<Song> songs) {
    final selected = songs
        .where((s) => _multiSelect.selectedIds.contains(s.id))
        .toList();
    if (selected.isEmpty) return;
    _multiSelect.exitSelectMode();
    _playAt(selected, 0);
  }

  @override
  Widget build(BuildContext context) {
    final songs = _sortedSongs;
    final player = context.watch<PlayerProvider>();
    final currentId = player.currentSong?.id;
    final currentIndex = (currentId == null || songs.isEmpty)
        ? -1
        : songs.indexWhere((s) => s.id == currentId);
    // hasClients 在首帧 build 时必为 false，不能作为按钮可用性的依据，
    // 否则定位按钮会先显示为禁用；该检查已移入 _scrollToCurrentSong。
    final canLocate = currentIndex >= 0;

    if (songs.isEmpty) {
      return Center(
        child: Text(
          '暂无歌曲',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    final sonify = SonifyColors.of(context);

    return Column(
      children: [
        // 多选模式顶栏：关闭 / 已选 N 首 / 全选 / 播放所选（与歌单页同结构）
        if (_multiSelect.isSelectMode)
          Container(
            color: Theme.of(context).colorScheme.surface,
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _multiSelect.exitSelectMode,
                  tooltip: '退出选择',
                ),
                Expanded(
                  child: Text(
                    '已选 ${_multiSelect.selectedIds.length} 首',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _multiSelect.selectedIds.length == songs.length &&
                            songs.isNotEmpty
                        ? Icons.deselect
                        : Icons.select_all,
                  ),
                  onPressed: () =>
                      _multiSelect.toggleSelectAll(songs.map((s) => s.id)),
                  tooltip: _multiSelect.selectedIds.length == songs.length &&
                          songs.isNotEmpty
                      ? '取消全选'
                      : '全选',
                ),
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: _multiSelect.selectedIds.isNotEmpty
                      ? () => _playSelected(songs)
                      : null,
                  tooltip: '播放所选',
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                '${songs.length} 首歌曲',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: sonify.textSecondary,
                    ),
              ),
              const Spacer(),
              // 视图切换钮（方案 §4.3：grid↔list 图标切换，状态持久化）
              if (!_multiSelect.isSelectMode)
                IconButton(
                  icon: Icon(
                    _viewMode == _SongsViewMode.list
                        ? Icons.grid_view_outlined
                        : Icons.view_list_outlined,
                  ),
                  tooltip: _viewMode == _SongsViewMode.list
                      ? '切换为网格视图'
                      : '切换为列表视图',
                  onPressed: _toggleViewMode,
                ),
              IconButton(
                icon: const Icon(Icons.shuffle),
                tooltip: '随机播放',
                onPressed: () {
                  if (songs.isNotEmpty) {
                    final shuffled = List<Song>.from(songs)..shuffle();
                    context.read<PlayerProvider>().playPlaylist(shuffled, 0);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.my_location),
                tooltip: '定位当前播放',
                onPressed: canLocate && !_multiSelect.isSelectMode
                    ? () => _scrollToCurrentSong(currentIndex)
                    : null,
              ),
              M3ESortButton<SongSortBy>(
                tooltip: '排序',
                // 排序按钮上根据当前方向显示箭头标识
                icon: _sortDescending
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded,
                current: _sortBy,
                options: const [
                  (value: SongSortBy.title, label: '按标题'),
                  (value: SongSortBy.artist, label: '按歌手'),
                  (value: SongSortBy.dateAdded, label: '按添加时间'),
                ],
                onPicked: (value, repeated) {
                  setState(() {
                    if (repeated) {
                      // 再次点当前项 → 切换升/降序
                      _sortDescending = !_sortDescending;
                    } else {
                      // 切到新的排序项 → 重置为正序
                      _sortBy = value;
                      _sortDescending = false;
                    }
                  });
                  // 记忆排序选择：切到其它页面再回来仍保持本次选择
                  _saveSortPreference();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _viewMode == _SongsViewMode.list
              ? ListView.builder(
                  controller: _scrollController,
                  // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度）
                  padding: EdgeInsets.only(
                      bottom: MediaQuery.paddingOf(context).bottom),
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    return SongListItem(
                      // 定位目标项挂 GlobalKey，供 ensureVisible 精确对齐
                      key: index == _targetScrollIndex ? _targetItemKey : null,
                      song: song,
                      isSelectMode: _multiSelect.isSelectMode,
                      isSelected: _multiSelect.isSelected(song.id),
                      onLongPress: () => _onItemLongPress(songs, index),
                      onTap: () => _onItemTap(songs, index),
                    );
                  },
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = _gridColumns(constraints.maxWidth);
                    return GridView.builder(
                      controller: _scrollController,
                      // 网格边缘 18dp、列距 15dp（Title.kt:419-420, 416-417）
                      padding: const EdgeInsets.fromLTRB(
                          SonifySpacing.gridEdge, 0, SonifySpacing.gridEdge, 0),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: SonifySpacing.gridH,
                        mainAxisSpacing: SonifySpacing.gridV,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: songs.length,
                      itemBuilder: (context, index) {
                        final song = songs[index];
                        return _SongGridCard(
                          song: song,
                          isSelectMode: _multiSelect.isSelectMode,
                          isSelected: _multiSelect.isSelected(song.id),
                          onTap: () => _onItemTap(songs, index),
                          onLongPress: () => _onItemLongPress(songs, index),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 曲目网格卡（方案 §4.1/§5.3 规格）：封面 squircle 10dp +
/// 标题 13sp + 歌手 13sp 次级灰；多选模式下展示勾选态。
class _SongGridCard extends StatelessWidget {
  const _SongGridCard({
    required this.song,
    required this.isSelectMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
  });

  final Song song;
  final bool isSelectMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SmoothClipRRect(
              borderRadius: BorderRadius.circular(SonifyRadius.cover),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  song.artworkUri != null && song.artworkUri!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: song.artworkUri!,
                          memCacheWidth: 300,
                          memCacheHeight: 300,
                          fit: BoxFit.cover,
                          placeholder: (_, _) => Container(
                            color: cs.surfaceContainerHighest,
                            child: Icon(Icons.music_note,
                                color: cs.onSurfaceVariant),
                          ),
                          errorWidget: (_, _, _) => Container(
                            color: cs.surfaceContainerHighest,
                            child: Icon(Icons.music_note,
                                color: cs.onSurfaceVariant),
                          ),
                        )
                      : Container(
                          color: cs.surfaceContainerHighest,
                          child:
                              Icon(Icons.music_note, color: cs.onSurfaceVariant),
                        ),
                  if (isSelectMode)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected
                              ? cs.primary
                              : Colors.black.withValues(alpha: 0.35),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.8),
                            width: 1.5,
                          ),
                        ),
                        child: isSelected
                            ? Icon(Icons.check,
                                size: 16, color: cs.onPrimary)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SonifyTextStyles.listItem.copyWith(color: cs.onSurface),
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
    );
  }
}
