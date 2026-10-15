import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/library_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../player/full_player_route.dart';
import '../user/favorites_page.dart';
import '../user/play_history_page.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'folders_page.dart';
import 'scan_status_page.dart';
import 'songs_page.dart';

/// 本地音乐页（独立路由形态）。
///
/// 页面内容已抽为可嵌入的 [LibraryMusicPanel]（去 Scaffold），收藏页
/// 「本地」tab 直接嵌入同一面板；本页仅保留路由壳（AppBar + FAB）。
///
/// v6（音乐库 9 项子页面全量化）：壳内新增 [_LibraryHubEntries] 入口区，
/// 补齐设计稿中跨云/本地的导航项（我的收藏/歌单/专辑/歌手/最近播放/
/// 扫描状态）；曲目/专辑/艺术家/文件夹/收藏五类本地内容仍由面板承载。
class LibraryPage extends StatefulWidget {
  /// 初始选中的面板 tab（0=曲目 1=专辑 2=艺术家 3=文件夹 4=收藏）。
  /// 供「文件夹」「本地收藏」等可选 Tab 复用本页时预选对应分类，
  /// 避免造重复页（复用既有面板，仅预选 tab）。
  final int initialTab;

  const LibraryPage({super.key, this.initialTab = 0});

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
      body: Column(
        children: [
          const _LibraryHubEntries(),
          Expanded(child: LibraryMusicPanel(initialTab: widget.initialTab)),
        ],
      ),
      floatingActionButton: _buildScanFAB(context),
    );
  }

  Widget _buildScanFAB(BuildContext context) {
    // 扫描进行中：FAB 显示转圈并禁用，防止重复触发扫描。
    // 不弹任何模态遮罩，用户仍可自由切换页面（扫描在后台 Isolate 执行）。
    if (context.watch<LibraryProvider>().isScanning) {
      return FloatingActionButton(
        onPressed: null,
        child: const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
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

/// 音乐库入口区：设计稿 9 项子页面中跨云/本地的导航项。
///
/// 面板已承载 曲目/专辑/艺术家/文件夹/收藏 五类本地内容（覆盖设计稿的
/// 本地音乐/文件夹/本地收藏及本地专辑/歌手），本区补齐其余入口：
/// 我的收藏/歌单/专辑/歌手（云，落「我的收藏」对应 tab）、最近播放
/// （播放历史页）、扫描状态（本地扫描状态页）。
///
/// 仅渲染于独立路由壳（[LibraryPage]）；收藏页「本地」tab 嵌入的面板
/// 形态不显示本区（避免与宿主收藏页入口重复）。
class _LibraryHubEntries extends StatelessWidget {
  const _LibraryHubEntries();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 与搜索栏/ TabBar 容器同规格：squircle 9dp 卡底材质
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
          shape: SmoothRectangleBorder(
            borderRadius: BorderRadius.circular(SonifyRadius.card),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Column(
            children: [
              Row(
                children: [
                  _buildCell(
                    context,
                    icon: Icons.favorite,
                    label: '我的收藏',
                    page: const FavoritesPage(),
                  ),
                  _buildCell(
                    context,
                    icon: Icons.queue_music,
                    label: '歌单',
                    page: const FavoritesPage(initialTab: 0),
                  ),
                  _buildCell(
                    context,
                    icon: Icons.album,
                    label: '专辑',
                    page: const FavoritesPage(initialTab: 2),
                  ),
                ],
              ),
              Row(
                children: [
                  _buildCell(
                    context,
                    icon: Icons.person,
                    label: '歌手',
                    page: const FavoritesPage(initialTab: 3),
                  ),
                  _buildCell(
                    context,
                    icon: Icons.history,
                    label: '最近播放',
                    page: const PlayHistoryPage(),
                  ),
                  _buildCell(
                    context,
                    icon: Icons.radar,
                    label: '扫描状态',
                    page: const ScanStatusPage(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCell(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Widget page,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(SonifyRadius.card),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => page),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: colorScheme.primary),
              const Gap(AppSpacing.xs),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
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
  /// 初始选中的分类 tab（0=曲目 1=专辑 2=艺术家 3=文件夹 4=收藏）。
  /// 独立路由形态由 [LibraryPage.initialTab] 传入（如「文件夹」可选 Tab
  /// 预选 3）；嵌入收藏页「本地」tab 时用默认 0。
  final int initialTab;

  const LibraryMusicPanel({super.key, this.initialTab = 0});

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
    _tabController = TabController(
      length: 5,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 4),
    );
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
    final sonify = SonifyColors.of(context);
    final hasMusic = libraryProvider.hasMusic;
    final isScanning = libraryProvider.isScanning;

    return Column(
      children: [
        if (hasMusic || isScanning) ...[
          // 搜索栏：squircle 9dp 卡底材质（方案 §4.2「tab 容器 squircle 9dp 卡底色」
          // 的同类规格，搜索条与 sonify 搜索框材质对齐）
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      shape: SmoothRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(SonifyRadius.card),
                      ),
                    ),
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
                        border: InputBorder.none,
                      ),
                      onChanged: (value) {
                        libraryProvider.setSearchQuery(value);
                        setState(() {});
                      },
                    ),
                  ),
                ),
                // 扫描入口：独立路由形态由页面 FAB 承担，嵌入形态（收藏页
                // 「本地」tab 无 Scaffold FAB）由搜索栏尾部按钮承担。
                // 扫描中禁用并显示转圈，防止重复触发扫描。
                IconButton(
                  tooltip: '扫描音乐',
                  icon: isScanning
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                  onPressed: isScanning
                      ? null
                      : () => showLibraryScanMenu(context),
                ),
              ],
            ),
          ),
          // TabBar：squircle 9dp 分段容器（方案 §4.3「tab 行：squircle 9dp
          // 容器内 5 tab，选中 tab 卡片式反白」），文字层级对齐 sonify。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
                shape: SmoothRectangleBorder(
                  borderRadius: BorderRadius.circular(SonifyRadius.card),
                ),
              ),
              child: TabBar(
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
                labelStyle: SonifyTextStyles.body.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                unselectedLabelStyle: SonifyTextStyles.body.copyWith(
                  color: sonify.textSecondary,
                ),
                dividerColor: Colors.transparent,
              ),
            ),
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
                    const LocalFavoritesPanel(),
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
  // 防重入：扫描进行中不弹菜单（入口按钮已禁用，此处兜底）
  if (provider.isScanning) {
    showToast('正在扫描中，请稍候');
    return;
  }
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
///
/// v6（音乐库 9 项子页面全量化）：由私有 tab 组件抽取为公共面板，
/// 面板「收藏」tab 与「本地收藏」可选 Tab（LibraryPage initialTab=4）
/// 复用同一份实现，不造重复页。
class LocalFavoritesPanel extends StatelessWidget {
  const LocalFavoritesPanel({super.key});

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
