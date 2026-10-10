import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/library_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../player/full_player_route.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'folders_page.dart';
import 'songs_page.dart';

/// 本地音乐页（独立路由形态）。
///
/// 页面内容已抽为可嵌入的 [LibraryMusicPanel]（去 Scaffold），收藏页
/// 「本地」tab 直接嵌入同一面板；本页仅保留路由壳（AppBar + FAB）。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          '本地音乐',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      body: const LibraryMusicPanel(),
      floatingActionButton: _buildScanFAB(context),
    );
  }

  Widget _buildScanFAB(BuildContext context) {
    // 替换为 M3E 规范的 FAB：M3EFab 默认中等尺寸的容器 56 / 图标 24 /
    // 圆角 16，配色沿用 primaryContainer + onPrimaryContainer，
    // 与本项目 floatingActionButtonTheme 原有定义一致，故无需显式传色。
    // 本页仅此一个 FAB，M3EFab 不支持 heroTag，不存在 Hero 标签冲突。
    return M3EFab(
      onPressed: () => showLibraryScanMenu(context),
      icon: const Icon(Icons.add),
    );
  }
}

/// 本地音乐可嵌入面板（去 Scaffold 形态）。
///
/// 承载原 LibraryPage 的全部内容：搜索栏 + 分类 TabBar + 内容区
///（曲目/专辑/艺术家/文件夹/收藏）+ 扫描/空态。数据加载与初始化逻辑
///（[LibraryProvider.loadSavedSongs]/[loadScanFolders]）原样保留在面板
/// 内部，独立路由与收藏页嵌入两种形态共用同一份。
class LibraryMusicPanel extends StatefulWidget {
  const LibraryMusicPanel({super.key});

  @override
  State<LibraryMusicPanel> createState() => _LibraryMusicPanelState();
}

class _LibraryMusicPanelState extends State<LibraryMusicPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  late FocusNode _searchFocusNode;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _searchFocusNode = FocusNode();
    // 监听 FullPlayer 展开状态：展开时取消搜索框焦点，防止返回时自动弹输入法
    playerExpansion.addListener(_onPlayerExpansionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 页面加载后立即取消搜索框焦点，防止输入法自动弹出
      _searchFocusNode.unfocus();
      final provider = context.read<LibraryProvider>();
      // 1. 先恢复上次扫描结果（缓存），让用户立即看到歌曲列表
      provider.loadSavedSongs();
      // 2. 加载已配置的扫描目录
      provider.loadScanFolders();
    });
  }

  /// FullPlayer 展开时取消搜索框焦点，避免返回后输入法自动弹出
  void _onPlayerExpansionChanged() {
    if (playerExpansion.value > 0.5) {
      _searchFocusNode.unfocus();
    }
  }

  @override
  void dispose() {
    playerExpansion.removeListener(_onPlayerExpansionChanged);
    _tabController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final libraryProvider = context.watch<LibraryProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasMusic = libraryProvider.hasMusic;
    final isScanning = libraryProvider.isScanning;

    return Column(
      children: [
        if (hasMusic || isScanning) ...[
          // 搜索栏
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onTap: () {
                      // 点击搜索框时请求焦点并弹出键盘
                      _searchFocusNode.requestFocus();
                    },
                    decoration: InputDecoration(
                      hintText: '搜索本地音乐',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 20),
                              onPressed: () {
                                _searchController.clear();
                                libraryProvider.clearSearch();
                              },
                            )
                          : null,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: AppRadius.xlAll,
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHigh,
                    ),
                    onChanged: (value) {
                      libraryProvider.setSearchQuery(value);
                      setState(() {});
                    },
                  ),
                ),
                // 扫描入口：独立路由形态由页面 FAB 承担，嵌入形态（收藏页
                // 「本地」tab 无 Scaffold FAB）由搜索栏尾部按钮承担。
                IconButton(
                  tooltip: '扫描音乐',
                  icon: const Icon(Icons.add),
                  onPressed: () => showLibraryScanMenu(context),
                ),
              ],
            ),
          ),
          // TabBar
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: '曲目'),
              Tab(text: '专辑'),
              Tab(text: '艺术家'),
              Tab(text: '文件夹'),
              Tab(text: '收藏'),
            ],
            // 5 个 Tab 内容较窄，关闭滚动并居中分布到整行，
            // 缩窄每个 Tab 内部 padding 让"收藏"也能完整显示。
            isScrollable: false,
            tabAlignment: TabAlignment.center,
            padding: EdgeInsets.zero,
            labelPadding: const EdgeInsets.symmetric(horizontal: 6),
            labelStyle: textTheme.titleSmall,
            unselectedLabelStyle: textTheme.titleSmall,
            dividerColor: Colors.transparent,
          ),
        ],
        Expanded(
          child: isScanning && !hasMusic
              ? _buildScanningState(colorScheme)
              : !hasMusic
              ? _buildEmptyState(colorScheme)
              : TabBarView(
                  controller: _tabController,
                  children: [
                    SongsPage(songs: libraryProvider.songs),
                    AlbumsPage(albums: libraryProvider.albums),
                    ArtistsPage(artists: libraryProvider.artists),
                    FoldersPage(folders: libraryProvider.folders),
                    const _LocalFavoritesTab(),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildScanningState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const M3ELoadingIndicator(),
          const Gap(AppSpacing.lg),
          Text(
            '正在扫描本地音乐...',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.library_music_outlined,
            size: 64,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const Gap(AppSpacing.lg),
          Text(
            '还没有本地音乐',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const Gap(AppSpacing.sm),
          Text(
            '点击扫描按钮添加本地音乐',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
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

/// 扫描菜单（独立路由 FAB 与嵌入面板的扫描入口共用）。
void showLibraryScanMenu(BuildContext context) {
  final provider = context.read<LibraryProvider>();
  showM3EModalBottomSheet(
    context: context,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                '扫描本地音乐',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('扫描音乐'),
              subtitle: const Text('扫描默认目录和已添加的文件夹'),
              onTap: () {
                Navigator.pop(ctx);
                provider.loadLocalMusic();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('添加扫描文件夹'),
              subtitle: const Text('选择额外的文件夹进行扫描'),
              onTap: () async {
                Navigator.pop(ctx);
                final success = await provider.addScanFolder();
                if (success && context.mounted) {
                  showToast('已添加文件夹，点击扫描音乐', long: true);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: const Text('排除文件夹'),
              subtitle: Text('已排除 ${provider.excludedFolders.length} 个文件夹'),
              onTap: () {
                Navigator.pop(ctx);
                _showExcludedFolderManagement(context);
              },
            ),
            const Gap(AppSpacing.sm),
          ],
        ),
      );
    },
  );
}

void _showExcludedFolderManagement(BuildContext context) {
  final provider = context.read<LibraryProvider>();
  showM3EModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setModalState) {
          final excludedFolders = provider.excludedFolders;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '排除文件夹',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                  const Gap(AppSpacing.xs),
                  Text(
                    '排除的文件夹及其子目录不会被扫描',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Gap(AppSpacing.md),
                  if (excludedFolders.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                      child: Center(child: Text('暂无排除文件夹')),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(ctx).size.height * 0.35,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: excludedFolders.length,
                        itemBuilder: (context, index) {
                          final folder = excludedFolders[index];
                          final name = folder
                              .split('/')
                              .where((p) => p.isNotEmpty)
                              .last;
                          return ListTile(
                            leading: const Icon(Icons.folder_off_outlined),
                            title: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              folder,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () {
                                provider.removeExcludedFolder(folder);
                                setModalState(() {});
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  const Gap(AppSpacing.sm),
                  // 添加排除文件夹按钮
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: () async {
                        final success = await provider.addExcludedFolder();
                        if (success) {
                          setModalState(() {});
                          if (context.mounted) {
                            showToast('已添加排除文件夹，重新扫描后生效', long: true);
                          }
                        }
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('添加排除文件夹'),
                    ),
                  ),
                  const Gap(AppSpacing.sm),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// 本地音乐收藏 tab：从 `LocalFavoritesProvider` 读取 id 集合，再从
/// `LibraryProvider.allSongs` 中按 id 匹配出完整 Song，传入 `SongsPage`
/// 复用其随机播放 / 排序 / 定位当前播放等交互。
class _LocalFavoritesTab extends StatelessWidget {
  const _LocalFavoritesTab();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final localFavorites = context.watch<LocalFavoritesProvider>();
    final favoriteIds = localFavorites.favoriteIds;

    // 收藏的歌曲列表：未过滤的本地歌曲 × 收藏 id 集合
    final allFavorites = library.allSongs
        .where((s) => favoriteIds.contains(s.id))
        .toList();

    // 跟随 LibraryProvider 搜索框过滤
    final query = library.searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? allFavorites
        : allFavorites
              .where(
                (s) =>
                    s.title.toLowerCase().contains(query) ||
                    s.artist.toLowerCase().contains(query) ||
                    s.album.toLowerCase().contains(query),
              )
              .toList();

    if (allFavorites.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.favorite_border,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const Gap(AppSpacing.lg),
            Text(
              '还没有本地收藏',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Gap(AppSpacing.sm),
            Text(
              '在曲目列表中点击心形图标即可收藏',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的收藏',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return SongsPage(songs: filtered);
  }
}
