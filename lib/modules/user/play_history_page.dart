import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../data/models/song.dart';
import '../../data/repositories/history_repository.dart';
import '../../providers/player_provider.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import '../../widgets/song_list_item.dart';

class PlayHistoryPage extends StatefulWidget {
  /// 可选扩展：对显示列表应用变换（默认关闭，由私有构建注入，用于筛选等）。
  /// [pageKey] 为页面标识（'history'），供私有状态按页隔离。
  static List<Song> Function(String pageKey, List<Song> songs)? songFilterHook;
  /// 可选扩展：筛选状态变更的监听信号（默认关闭，由私有构建注入，
  /// 用于筛选按钮切换后触发本页重建）。
  static Listenable? songFilterListenable;
  /// 可选扩展：顶栏额外操作按钮（默认关闭，由私有构建注入）。
  static List<Widget> Function(BuildContext context)? extraAppBarActionsBuilder;

  const PlayHistoryPage({super.key});

  @override
  State<PlayHistoryPage> createState() => _PlayHistoryPageState();
}

class _PlayHistoryPageState extends State<PlayHistoryPage> {
  List<Song> _songs = [];
  bool _isLoading = true;

  /// 多选编辑模式（与播放列表页/歌单页同一套心智模型）：
  /// 进入后顶栏变为「✕ / 已选 N 首 / 全选 / 删除」，歌曲项显示圆形复选框。
  bool _editMode = false;
  final Set<String> _selectedIds = {};

  List<Song> get _displaySongs {
    final filter = PlayHistoryPage.songFilterHook;
    if (filter == null) return _songs;
    return filter('history', _songs);
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final history = await HistoryRepository().getHistory();
    if (!mounted) return;
    setState(() {
      _songs = history;
      _isLoading = false;
    });
  }

  void _enterEditMode([String? songId]) {
    setState(() {
      _editMode = true;
      if (songId != null) _selectedIds.add(songId);
    });
  }

  void _exitEditMode() {
    setState(() {
      _editMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String songId) {
    setState(() {
      if (!_selectedIds.remove(songId)) _selectedIds.add(songId);
    });
  }

  void _toggleSelectAll(List<Song> songs) {
    setState(() {
      if (_selectedIds.length == songs.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(songs.map((s) => s.id));
      }
    });
  }

  Future<void> _confirmDeleteSelected() async {
    final count = _selectedIds.length;
    if (count == 0) return;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除歌曲'),
        content: Text('确定从播放历史中删除选中的 $count 首歌曲吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await HistoryRepository().removeIds(Set.of(_selectedIds));
      if (mounted) _exitEditMode();
      await _loadHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 可选扩展：筛选/变换状态变更时重建本页（默认监听空信号，无额外开销）
    return ListenableBuilder(
      listenable: PlayHistoryPage.songFilterListenable ??
          const AlwaysStoppedAnimation<Object?>(null),
      builder: (context, _) {
        // 在 builder 内计算：筛选状态变化时重新过滤（build 外计算会被闭包捕获旧值）
        final displaySongs = _displaySongs;
        final allSelected =
            displaySongs.isNotEmpty &&
            _selectedIds.length == displaySongs.length;
        // 多选编辑态保留多选顶栏（✕ / 已选 N 首 / 全选 / 删除，与播放列表页、
        // 歌单页同一套心智模型）：返回/退出/全选/删除都需要常驻可见，而
        // SonifyTitleScaffold 的 actions 槽滚动后才浮现，不满足该需求。
        if (_editMode) {
          return Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitEditMode,
              ),
              title: Text('已选 ${_selectedIds.length} 首'),
              actions: [
                TextButton(
                  onPressed: displaySongs.isEmpty
                      ? null
                      : () => _toggleSelectAll(displaySongs),
                  child: Text(allSelected ? '取消全选' : '全选'),
                ),
                TextButton(
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : _confirmDeleteSelected,
                  child: Text(
                    '删除',
                    style: TextStyle(
                      color: _selectedIds.isEmpty
                          ? Theme.of(context).disabledColor
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
            body: _buildSongList(displaySongs),
          );
        }
        // 正常态与主页头部统一：SonifyTitleScaffold 固定悬浮大标题（批次 9）。
        // 注入的额外操作钮（默认无）放 actions 槽（滚动后随栏体浮现）。
        return SonifyTitleScaffold(
          title: '播放历史',
          actions: PlayHistoryPage.extraAppBarActionsBuilder?.call(context),
          itemCount: 1,
          itemBuilder: (context, index) => _buildContent(displaySongs),
        );
      },
    );
  }

  /// 业务区（单 item 固定高度）：加载/空态居中，列表态为「统计头 + 歌曲列表」。
  ///
  /// 固定高度 = 视口 − 状态栏 − 标题区（8dp 顶距 + 36dp 标题行高 + 8dp 底距，
  /// 与 [SonifyTitleScaffold] 占位 item 同口径）；歌曲列表保留 ListView.builder
  /// 惰性构建（长历史不整页急建）。
  Widget _buildContent(List<Song> displaySongs) {
    final media = MediaQuery.of(context);
    final height = media.size.height -
        media.padding.top -
        52 -
        media.viewInsets.bottom;
    Widget child;
    if (_isLoading) {
      child = const Center(child: M3ELoadingIndicator());
    } else if (_songs.isEmpty) {
      child = _buildEmpty();
    } else {
      child = Column(
        children: [
          _buildHeader(displaySongs),
          Expanded(child: _buildSongList(displaySongs)),
        ],
      );
    }
    return SizedBox(height: height, child: child);
  }

  /// 歌曲列表（编辑态顶栏 body 与正常态列表区共用）。
  Widget _buildSongList(List<Song> displaySongs) {
    return ListView.builder(
      itemCount: displaySongs.length,
      itemBuilder: (context, index) {
        final song = displaySongs[index];
        return SongListItem(
          song: song,
          isSelectMode: _editMode,
          isSelected: _selectedIds.contains(song.id),
          onSelectToggle: () => _toggleSelect(song.id),
          onLongPress: _editMode
              ? null
              : () => _enterEditMode(song.id),
          onTap: () {
            context.read<PlayerProvider>().playOnlinePlaylist(
              displaySongs,
              index,
            );
          },
        );
      },
    );
  }

  Widget _buildEmpty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history,
            size: 64,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '暂无播放历史',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(List<Song> displaySongs) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '共 ${displaySongs.length} 首',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          if (displaySongs.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                context.read<PlayerProvider>().playOnlinePlaylist(
                  displaySongs,
                  0,
                );
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
          // 批量删除入口（原顶栏编辑钮移到统计头行，保持常驻可达）：
          // 进入多选编辑模式（保留「全选→删除」即清空全部）
          if (_songs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '批量删除',
              onPressed: () => _enterEditMode(),
            ),
        ],
      ),
    );
  }
}
