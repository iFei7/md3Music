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
import '../../widgets/common/glass_circle_button.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'folders_page.dart';
import 'scan_status_page.dart';
import 'songs_page.dart';

/// 本地音乐页（独立路由形态）。
///
/// 页面内容已抽为可嵌入的 [LibraryMusicPanel]（去 Scaffold），收藏页
/// 「本地」tab 直接嵌入同一面板。
///
/// 顶栏右侧（[SonifyTitleScaffold]）两个动作，均**常驻** trailing：
/// - **搜索圆钮**（批次 23 常驻，此前在 actions 槽、随面板内列表滚动
///   浮现）：用户原话「上滑看不到搜索框后顶栏显示圆形搜索按钮」。
///   滚动浮现链（actionsVisible + 面板滚动信号上传）在真机上按钮会
///   跟着内层列表滚动才出现、且外层骨架不滚导致模糊带不同步，改为
///   与扫描钮并列常驻保证入口恒可见；配方用公共组件
///   [GlassCircleButton]（42dp 圆形液态玻璃 + 20dp 图标），与首页/
///   听书/搜索页顶栏圆钮完全同款；
/// - **扫描钮**（常驻）：本页外层骨架是单固定高 item、本身不滚动，
///   actions 的既有「随骨架滚动淡入」条件永不满足（扫描钮放 actions
///   时因此**永不显示**，bug）——故常驻 trailing，点击进扫描状态页
///   （扫描/目录管理能力由该页「扫描选项」承载）。
///
/// 已移除：原「音乐库入口区」快捷宫格（我的收藏/歌单/专辑/歌手/
/// 最近播放/扫描状态，跨云/本地导航项收敛到音乐库 hub 页）与页面级
/// 扫描 FAB、面板尾部扫描钮（三入口收敛为一：顶栏扫描钮 + 面板空态
/// 「扫描音乐」按钮）；[showLibraryScanMenu] 仍保留导出（扫描状态页
/// 「扫描选项」复用）。曲目/专辑/艺术家/文件夹/收藏 5 tab 面板、空态、
/// initialTab 契约均不变。
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
  /// 顶栏常驻搜索钮 / 扫描钮的定位 key（供测试按位点击，不影响样式）。
  static const String _kSearchButtonKey = 'library-local-search';
  static const String _kScanButtonKey = 'library-scan';

  /// 本地音乐搜索框的 FocusNode：顶栏搜索钮点击时聚焦面板内的搜索
  /// TextField。节点由本页创建并持有生命周期，经
  /// [LibraryMusicPanel.searchFocusNode] 传递给面板 attach；面板未渲染
  /// （空库）时节点处于未 attach 状态，此时聚焦改走 SnackBar 提示。
  final FocusNode _localSearchFocusNode = FocusNode();

  @override
  void dispose() {
    _localSearchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 扫描中：扫描钮显示转圈（视觉反馈）；点击仍进扫描状态页查看进度
    // （原 FAB 的禁点语义由状态页内的扫描状态展示承接）。
    final isScanning = context.watch<LibraryProvider>().isScanning;
    // 头部与主页统一：SonifyTitleScaffold 固定悬浮大标题（批次 9）。
    // 面板整体作为单个业务 item 固定在标题下方（固定高 item 模式不变）。
    return Scaffold(
      body: SonifyTitleScaffold(
        title: '本地音乐',
        itemCount: 1,
        // 顶栏右侧：搜索圆钮 + 扫描钮，均常驻 trailing（见类文档：
        // 本页外层骨架不可滚，actions 滚动淡入条件永不满足）。
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 搜索玻璃圆钮（公共组件 GlassCircleButton，42dp 圆 + 20dp
            // 图标，与首页/听书/搜索页顶栏同款）：点击聚焦面板内本地
            // 音乐搜索框。批次 23 起常驻可见（此前随内层列表滚动浮现，
            // 真机上与骨架不滚的顶栏背景脱节、入口不可靠）。
            GlassCircleButton(
              key: const ValueKey(_kSearchButtonKey),
              tooltip: '搜索',
              icon: Icons.search,
              onPressed: _focusLocalSearch,
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey(_kScanButtonKey),
              tooltip: '扫描音乐',
              icon: isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ScanStatusPage()),
                );
              },
            ),
          ],
        ),
        itemBuilder: (context, index) {
          final media = MediaQuery.of(context);
          // 固定高度 = 视口 − 状态栏 − 标题区（8+36+8，与占位 item 同口径）
          final height = media.size.height - media.padding.top - 52;
          return SizedBox(
            height: height,
            child: LibraryMusicPanel(
              initialTab: widget.initialTab,
              // 顶栏搜索钮 ↔ 面板搜索框的 FocusNode 传递链（见
              // [_localSearchFocusNode] 与 [_focusLocalSearch]）。
              searchFocusNode: _localSearchFocusNode,
            ),
          );
        },
      ),
    );
  }

  /// 顶栏搜索钮：聚焦面板内本地音乐搜索框。
  ///
  /// 面板仅在「有本地音乐 / 扫描中」渲染搜索栏（与 [LibraryMusicPanel]
  /// 的 `if (hasMusic || isScanning)` 同口径）；搜索钮本身只在面板内
  /// 列表可滚（已上滑）时浮现，空库态按钮不可见——此处的 SnackBar
  /// 分支是防御性兜底（如库被并发清空），不做静默 no-op。
  void _focusLocalSearch() {
    final provider = context.read<LibraryProvider>();
    if (!provider.hasMusic && !provider.isScanning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有本地音乐，先扫描音乐吧')),
      );
      return;
    }
    _localSearchFocusNode.requestFocus();
  }
}

/// 本地音乐可嵌入面板（去 Scaffold 形态）。
///
/// 承载原 LibraryPage 的全部内容：搜索栏 + 分类 TabBar + 内容区
/// （曲目/专辑/艺术家/文件夹/收藏）+ 空态。数据加载与初始化逻辑
/// （[LibraryProvider.loadSavedSongs]/[loadScanFolders]）原样保留在面板
/// 内部，独立路由与收藏页嵌入两种形态共用同一份。
///
/// 面板原尾部扫描钮已移除（扫描入口收敛为宿主页顶栏扫描钮，见
/// [LibraryPage]）；空态的「扫描音乐」按钮（触发
/// [LibraryProvider.loadLocalMusic]）保留，嵌入收藏页「本地」tab 时可达。
class LibraryMusicPanel extends StatefulWidget {
  /// 初始选中的分类 tab（0=曲目 1=专辑 2=艺术家 3=文件夹 4=收藏）。
  /// 独立路由形态由 [LibraryPage.initialTab] 传入（如「文件夹」可选 Tab
  /// 预选 3）；嵌入收藏页「本地」tab 时用默认 0。
  final int initialTab;

  /// 可选外部 FocusNode：由宿主页（[LibraryPage]）传入并 attach 到面板
  /// 内的搜索 TextField，宿主据此实现「点顶栏搜索钮聚焦面板搜索框」。
  /// 不传时面板自建自持（收藏页「本地」tab 嵌入形态）；外部传入时
  /// 生命周期归宿主，面板不重复 dispose。
  final FocusNode? searchFocusNode;

  const LibraryMusicPanel({
    super.key,
    this.initialTab = 0,
    this.searchFocusNode,
  });

  @override
  State<LibraryMusicPanel> createState() => _LibraryMusicPanelState();
}

class _LibraryMusicPanelState extends State<LibraryMusicPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  late final FocusNode _searchFocusNode;

  /// 外部传入的节点由宿主（[LibraryPage]）负责 dispose，面板不重复销毁。
  late final bool _ownsSearchFocusNode;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 5,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 4),
    );
    _ownsSearchFocusNode = widget.searchFocusNode == null;
    _searchFocusNode = widget.searchFocusNode ?? FocusNode();
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
    if (_ownsSearchFocusNode) _searchFocusNode.dispose();
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
          // 搜索栏：sonify 玻璃胶囊（与首页 _buildSearchFieldItem 同款
          // LiquidGlassSurface + GlassShape.pill，批次 8 补项统一外观形状，
          // 高度对齐首页 44dp 基准）。**交互语义不变**：仍是可输入实时
          // 过滤框（非首页的"点击跳搜索页"入口），只统一外观不改交互。
          // 搜索框的 FocusNode 可为宿主（[LibraryPage] 顶栏搜索钮）传入
          // 的外部节点（[LibraryMusicPanel.searchFocusNode]）。
          // 扫描入口已收敛：独立路由形态走顶栏扫描钮（进扫描状态页），
          // 面板原尾部扫描钮/FAB 移除（避免三入口）；空态「扫描音乐」
          // 按钮保留。
          // 搜索栏（无 Expanded）：原实现与面板尾部扫描钮同处横向 Row，
          // 用 Expanded 分享剩余宽度；扫描钮移除后本项是 Column 直接
          // 子节点——竖向 Column 里的 Expanded 会纵向撑满面板（批次14
          // 曾因此把 44dp 胶囊撑成 242dp），且 Expanded 包在 Padding 内
          // 还会抛 ParentDataWidget 不兼容。正确形态即 Padding 直裹。
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xs,
            ),
            child: LiquidGlassSurface(
              shape: GlassShape.pill,
              child: SizedBox(
                height: 44,
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onTap: () {
                    // 点击搜索框时请求焦点并弹出键盘
                    _searchFocusNode.requestFocus();
                  },
                  // InputDecorator 默认 textAlignVertical 为 top，
                  // 44dp 固定高度下需显式居中（input_decorator.dart:807）
                  textAlignVertical: TextAlignVertical.center,
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
          // 内容区：空库/扫描态居中占位；有音乐走 5 tab 分类。
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
