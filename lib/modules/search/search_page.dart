import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:m3e_core/m3e_core.dart';

import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../providers/kugou_provider.dart';
import '../../core/layout/adaptive_content_grid.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../core/widgets/app_background.dart';
import '../../providers/theme_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/cloud_song_mapper.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/pinchable_grid_view.dart';
import '../../widgets/song_list_item.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import '../../widgets/common/user_avatar_button.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../playlist/playlist_page.dart';
import '../recognition/song_recognition_page.dart';
import 'explore_sections.dart';

class SearchPage extends StatefulWidget {
  /// 打开时预填并立即执行的查询（桌面顶部工具栏搜索框提交时传入，见计划 4.3）。
  final String? initialQuery;

  const SearchPage({super.key, this.initialQuery});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();

  /// 搜索框聚焦态跟踪（sonify 规格：聚焦时 1.5dp primary 描边）。
  final FocusNode _searchFocusNode = FocusNode();

  /// 顶部外层滚动控制器（挂 [NestedScrollView.controller]）：坍缩交互
  /// 的唯一滚动信号源——outer offset 越过 [_kCollapseThreshold] 即搜索
  /// 胶囊完全收起，顶栏头像左侧浮出搜索图标。
  final ScrollController _outerController = ScrollController();

  /// 坍缩态通知器：true = 胶囊已收起（顶栏搜索图标在场）。
  /// 用 ValueNotifier + ValueListenableBuilder 局部重建 actions 单个
  /// 图标的显隐，不走整页 setState（避免波及 TabBarView / 结果列表）。
  final ValueNotifier<bool> _collapsed = ValueNotifier<bool>(false);

  /// 顶栏渐变模糊带可见性（批次 20）：outer offset > 0 即浮现、回顶
  /// 消失——与 SonifyTitleScaffold / SonifyTitleOverlay 的栏背景同拍，
  /// 四页模糊行为完全一致。
  final ValueNotifier<bool> _showBarBackground = ValueNotifier<bool>(false);

  /// 回顶动画展开同拍补一次焦点请求（见 [_onCollapsedSearchTap]）。
  bool _focusOnExpand = false;

  /// 坍缩阈值：header 展开高 104 = 标题区 52 + 胶囊行 52（批次 20 起
  /// 标题/头像移到 overlay，AppBar 只留胶囊行）；outer offset ≥ 52 即
  /// 胶囊行被滚完（刻度 = expandedHeight − toolbarHeight = 104 − 52）。
  static const double _kCollapseThreshold = 52;

  late TabController _tabController;
  List<String> _searchHistory = [];
  String _query = '';
  bool _hasSearched = false;
  String _currentSearchType = 'song';

  // 云盘搜索 tab 的本地状态
  // 云盘不走通用 /search 接口，进入云盘 tab 时按需懒加载一次用户云盘歌单，
  // 之后用 [_query] 在内存中过滤。生命周期跟随 SearchPage。
  List<Song> _cloudSongs = [];
  bool _cloudLoaded = false;
  bool _cloudLoading = false;
  String? _cloudError;

  static const _historyKey = 'search_history';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _tabController.addListener(_onTabChanged);
    _searchFocusNode.addListener(_onFocusChanged);
    _outerController.addListener(_onOuterScroll);
    _loadSearchHistory();
    // 恢复「热门搜索」（UI 重设计批次 1，方案 §2.1）：接口 /search/hot 一直在
    // （KugouApiClient.getHotSearch → KugouProvider.getHotSearch，结果缓存于
    // hotSearchKeywords），此前只是 UI 被移除。仅在缓存为空时拉一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final kugou = context.read<KugouProvider>();
      if (kugou.hotSearchKeywords.isEmpty) {
        kugou.getHotSearch();
      }
    });
    // 桌面工具栏搜索框提交：预填查询并在首帧后立即执行搜索。
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _searchController.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _performSearch(q);
      });
    }
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  /// 外层滚动 → 坍缩态 + 栏背景：等值比较防抖（避免同一阈值上反复赋值
  /// 触发 ValueListenableBuilder 无意义重建）。
  void _onOuterScroll() {
    if (!_outerController.hasClients) return;
    final offset = _outerController.offset;
    // 栏背景与 SonifyTitleScaffold 同拍：任何滚动即浮现，回顶消失
    if (_showBarBackground.value != (offset > 0)) {
      _showBarBackground.value = offset > 0;
    }
    final collapsed = offset >= _kCollapseThreshold;
    if (_collapsed.value != collapsed) {
      _collapsed.value = collapsed;
      // 展开同拍补一次焦点请求：坍缩期 TextField 不在树，
      // tap 当帧的 postFrame 请求会落空。postFrame 保证请求落在
      // 本帧 build（胶囊已重建）之后。
      if (!collapsed && _focusOnExpand) {
        _focusOnExpand = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocusNode.requestFocus();
        });
      }
    }
  }

  /// 坍缩态顶栏搜索图标：回顶展开搜索胶囊（动画结束后视觉上胶囊
  /// 完整复位），下一帧给输入框取焦点。
  void _onCollapsedSearchTap() {
    _focusOnExpand = true;
    _outerController.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _searchFocusNode.removeListener(_onFocusChanged);
    _searchFocusNode.dispose();
    _searchController.dispose();
    _outerController.removeListener(_onOuterScroll);
    _outerController.dispose();
    _collapsed.dispose();
    _showBarBackground.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final types = ['song', 'album', 'artist', 'special', 'cloud', 'lyric'];
    final newType = types[_tabController.index];
    if (newType != _currentSearchType && _query.isNotEmpty) {
      _currentSearchType = newType;
      if (newType == 'cloud') {
        // 云盘是本地过滤：未加载过就触发懒加载，加载完成后由 _query 在内存过滤
        if (!_cloudLoaded && !_cloudLoading) {
          _loadCloudSongsForSearch();
        }
        return;
      }
      final kugouProvider = context.read<KugouProvider>();
      if (kugouProvider.hasSearchResultForType(_query, newType)) {
        kugouProvider.restoreSearchResultFromCache(_query, newType);
      } else {
        _performSearchByType(_query, newType);
      }
    }
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _searchHistory = prefs.getStringList(_historyKey) ?? [];
    });
  }

  Future<void> _saveSearchHistory(String query) async {
    final prefs = await SharedPreferences.getInstance();
    _searchHistory = [
      query,
      ..._searchHistory.where((h) => h != query),
    ].take(10).toList();
    await prefs.setStringList(_historyKey, _searchHistory);
    setState(() {});
  }

  Future<void> _clearSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    setState(() {
      _searchHistory = [];
    });
  }

  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _query = query.trim();
      _hasSearched = true;
      _currentSearchType = 'song';
    });
    _tabController.animateTo(0);
    _saveSearchHistory(_query);

    final kugouProvider = context.read<KugouProvider>();
    await kugouProvider.search(_query, type: 'song');
  }

  Future<void> _performSearchByType(String query, String type) async {
    if (query.trim().isEmpty) return;
    final kugouProvider = context.read<KugouProvider>();
    await kugouProvider.search(query, type: type);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final themeProvider = context.watch<ThemeProvider>();
    final useBackgroundImage = themeProvider.useBackgroundImage;
    // 预计算背景图 provider（与 SliverAppBar flexibleSpace 用同一 cacheWidth →
    // ImageCache 同 key 共享解码），作为参数传入 _TabBarDelegate，
    // 避免在 SliverPersistentHeaderDelegate.build 内 watch ThemeProvider
    // 污染 NestedScrollView 的 sliver 链（导致 TabBarView 结果区被异常重建/覆盖）。
    ImageProvider? tabBarBackgroundImage;
    if (useBackgroundImage) {
      final size = MediaQuery.sizeOf(context);
      final cacheWidth = (size.width * MediaQuery.devicePixelRatioOf(context))
          .round()
          .clamp(540, 1440);
      tabBarBackgroundImage = backgroundImageProvider(
        themeProvider,
        cacheWidth: cacheWidth,
      );
    }

    // 键盘 inset 单一来源（真机 bug 修复）：
    // - Tab 模式（Dock 导航宿主）：本页嵌在 ResponsiveScaffold 的 Scaffold body
    //   内，宿主 Scaffold 已消费一次 viewInsets（resize 缩小 body）；本页
    //   Scaffold 若再 resize 会二次 inset，键盘上方多出一段空隙。祖先已存在
    //   Scaffold 时关闭本页 resize，inset 由宿主单一消费。
    // - 独立路由模式（发现页搜索框 push）：本页是栈顶唯一 Scaffold，必须保持
    //   resize 让键盘正常抬升内容。
    final bool hostedInDockScaffold = Scaffold.maybeOf(context) != null;
    return Scaffold(
      resizeToAvoidBottomInset: !hostedInDockScaffold,
      // 批次 20 UI 统一：滚动区（NestedScrollView，含胶囊行 header 与
      // TabBarView 结果区）+ 共享顶栏 overlay 叠在页面级 Stack 中——
      // overlay 与 discover / library hub / fm 三页同组件
      // （SonifyTitleOverlay），标题/头像几何与模糊带构造级一致。
      body: Stack(
        children: [
          NestedScrollView(
            controller: _outerController,
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverAppBar(
                  floating: true,
                  pinned: true,
                  // 批次 20：页面标题「搜索」/ 右上角用户头像 / 坍缩搜索
                  // 图标全部移到共享顶栏 overlay（SonifyTitleOverlay，见
                  // 本 Stack 第二项）——与其余三个 tab 页同组件，几何与
                  // 模糊完全一致。本 AppBar 只承载搜索胶囊行：展开区 =
                  // 标题区 52（与大标题带对齐：状态栏 + 8 + 36 + 8）+
                  // 胶囊行 52；坍缩阈值 _kCollapseThreshold=52 即胶囊行
                  // 被滚完（刻度 = expandedHeight − toolbarHeight）。
                  // expandedHeight 不含状态栏（maxExtent = 状态栏 + 104）。
                  automaticallyImplyLeading: false,
                  toolbarHeight: 52,
                  expandedHeight: 52 + 52,
                  // 批次 21：顶栏背景**恒透明**——顶栏的「玻璃」由共享
                  // overlay 的模糊带承担（与 discover/library/fm 三页同
                  // 组件同参数）。AppBar 自身若画不透明 surface，滚动后
                  // 模糊带只会模糊到这一层纯色，真机表现为「搜索页没有
                  // 模糊」，与三页不一致；恒透明后内容从带下滚过，模糊
                  // 带模糊的才是真实内容（壁纸场景由下方 flexibleSpace
                  // 的壁纸层铺底，无壁纸场景由页面主体背景兜底）。
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
              flexibleSpace: Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.hardEdge,
                children: [
                  // 壁纸层（原 flexibleSpace 子树整体迁入 Stack 底层）：
                  // 铺满整个 header（含工具栏区），与页面主体共用同一背景图
                  // 解码结果（同 cacheWidth → ImageCache 同 key）
                  if (useBackgroundImage)
                    ClipRect(
                      child: Builder(builder: (context) {
                        // 与页面主体共用同一背景图解码结果（同 cacheWidth →
                        // ImageCache 同 key），避免各自解码
                        final size = MediaQuery.sizeOf(context);
                        final cacheWidth = (size.width *
                                    MediaQuery.devicePixelRatioOf(context))
                                .round()
                                .clamp(540, 1440);
                        final tp = context.watch<ThemeProvider>();
                        // 顶栏区域用全屏尺寸 + 全屏 cover 渲染背景图，再
                        // topCenter 裁剪显示顶部：缩放比例与主体背景完全一致，
                        // 否则窄区域内单独 cover 会放大错位
                        return OverflowBox(
                          alignment: Alignment.topCenter,
                          minWidth: size.width,
                          maxWidth: size.width,
                          minHeight: size.height,
                          maxHeight: size.height,
                          child: SizedBox(
                            width: size.width,
                            height: size.height,
                            // 与 AppBackground 同层结构：surface 打底 +
                            // 模糊（backgroundBlur）+ 透明度（backgroundOpacity），
                            // 顶栏背景跟随主体模糊/透明度改动
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surface,
                                ),
                                Opacity(
                                  opacity: tp.backgroundOpacity,
                                  child: ImageFiltered(
                                    imageFilter: ui.ImageFilter.blur(
                                      sigmaX: tp.backgroundBlur,
                                      sigmaY: tp.backgroundBlur,
                                    ),
                                    child: Image(
                                      image: backgroundImageProvider(
                                        tp,
                                        cacheWidth: cacheWidth,
                                      ),
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ),
                  // 搜索胶囊行（批次 9 玻璃胶囊从 title 槽迁至展开区）：
                  // 贴 header 底部 = 标题区（状态栏 + 8 + 36 + 8）正下方；
                  // 坍缩态（outer offset ≥ 52，胶囊行已滚完）整行退场，
                  // 其后仅剩 overlay 的标题 + 头像 + 头像左侧的搜索图标。
                  // 水平位置由 _buildSearchField 内部 padding
                  // （SonifySpacing.cardMargin 16.5dp）承担；不遮挡下方
                  // TabBar（不同 sliver，无叠区）。
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _collapsed,
                      builder: (context, collapsed, _) {
                        // 坍缩即退场：否则收缩后的 flexibleSpace 仍会把
                        // 胶囊带到 pinned 带内（壁纸透明顶栏下与 overlay
                        // 带内的标题/头像视觉重叠）。局部重建，不波及 body。
                        if (collapsed) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SizedBox(
                            height: 44,
                            child: _buildSearchField(colorScheme),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              surfaceTintColor: Colors.transparent,
            ),
                if (_hasSearched)
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _TabBarDelegate(
                      tabBar: TabBar(
                        controller: _tabController,
                        // sonify 规格（方案 §2.3）：文字 14sp Medium，
                        // 选中 primary / 未选次级灰，指标条 3dp 圆头。
                        labelColor: colorScheme.primary,
                        unselectedLabelColor: SonifyColors.of(context).textSecondary,
                        labelStyle: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        unselectedLabelStyle: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        indicatorSize: TabBarIndicatorSize.label,
                        indicator: UnderlineTabIndicator(
                          borderSide: BorderSide(
                            width: 3,
                            color: colorScheme.primary,
                          ),
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                        tabs: const [
                          Tab(text: '歌曲'),
                          Tab(text: '专辑'),
                          Tab(text: '歌手'),
                          Tab(text: '歌单'),
                          Tab(text: '云盘'),
                          Tab(text: '歌词'),
                        ],
                      ),
                      useBackgroundImage: useBackgroundImage,
                      backgroundOpacity: themeProvider.backgroundOpacity,
                      backgroundBlur: themeProvider.backgroundBlur,
                      backgroundImage: tabBarBackgroundImage,
                    ),
                  ),
              ];
            },
            body: _hasSearched
                ? _buildSearchResults()
                : _searchController.text.trim().isNotEmpty
                ? _buildSuggestions()
                : _buildEmptyState(),
          ),
          // 共享顶栏 overlay（批次 20，SonifyTitleOverlay）：
          // - 大标题「搜索」固定悬浮：SonifyTextStyles.largeTitle
          //   （20sp w800、行高 36）、位置 = 状态栏 + 8dp、左 20dp
          //   （SonifySpacing.titleMargin），滚动中不位移不折叠；
          // - 右上角常驻用户头像 UserAvatarButton（36dp）：右 20dp、
          //   竖向居中于栏体，不随滚动淡入；
          // - 渐变模糊带：单片 BackdropFilter（sigma
          //   kSonifyBarBlurSigma）+ tint 兄弟层（状态栏锚定渐变），
          //   _showBarBackground 驱动 120ms 淡入/回顶消失；
          // - actions 坍缩搜索图标：胶囊滚完（_collapsed，阈值 52）后
          //   在头像左侧浮出，点击 animateTo(0) + 聚焦（批次 19 交互
          //   不变）；与头像间距 SizedBox(width: 8) 由 _TopBar 承担。
          Positioned.fill(
            child: SonifyTitleOverlay(
              title: '搜索',
              showBarBackground: _showBarBackground,
              statusBarHeight: MediaQuery.of(context).padding.top,
              trailing: const UserAvatarButton(),
              actions: [
                ValueListenableBuilder<bool>(
                  valueListenable: _collapsed,
                  builder: (context, collapsed, _) {
                    if (!collapsed) return const SizedBox.shrink();
                    return IconButton(
                      key: const ValueKey('search-collapsed-icon'),
                      tooltip: '搜索',
                      icon: const Icon(Icons.search),
                      onPressed: _onCollapsedSearchTap,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索框（批次 9 真机反馈：与主页/音乐库统一玻璃胶囊）：
  /// - LiquidGlassSurface + GlassShape.pill、高 44dp（对齐首页
  ///   _buildSearchFieldItem 与 library_page 批次 8 基准），水平边距
  ///   16.5dp 由 flexibleSpace 展开区布局承担（批次 18 从 SliverAppBar
  ///   title 槽迁入，收起态随展开区收缩裁掉）；
  /// - 聚焦时 1.5dp primary 描边：StadiumBorder foregroundDecoration
  ///   外覆玻璃面（等价原 ShapeDecoration.side 写法）；
  /// - 左放大镜 20dp、右识曲钮 20dp（命中区 28dp）+ 有文字时清空钮
  ///   28dp 命中区（视觉 18dp 图标）；TextField 由 Expanded 包住，
  ///   不被右侧固定宽图标挤占（**与主页搜索框一致**，识曲钮单独响应，
  ///   内层 GestureDetector 在手势竞技场中优先胜出）。
  /// 行为不变：textInputAction=search、onSubmitted 搜索、onChanged 实时联想。
  Widget _buildSearchField(ColorScheme colorScheme) {
    final sonify = SonifyColors.of(context);
    final hasText = _searchController.text.isNotEmpty;
    final isFocused = _searchFocusNode.hasFocus;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SonifySpacing.cardMargin),
      child: Container(
        foregroundDecoration: ShapeDecoration(
          shape: StadiumBorder(
            side: isFocused
                ? BorderSide(color: colorScheme.primary, width: 1.5)
                : BorderSide.none,
          ),
        ),
        child: LiquidGlassSurface(
          shape: GlassShape.pill,
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(Icons.search, size: 20, color: sonify.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    style: SonifyTextStyles.body.copyWith(
                      color: colorScheme.onSurface,
                    ),
                    decoration: InputDecoration(
                      hintText: '搜索歌曲、歌手、专辑',
                      hintStyle: SonifyTextStyles.body.copyWith(
                        color: sonify.textSecondary,
                      ),
                      border: InputBorder.none,
                      isCollapsed: true,
                    ),
                    // InputDecorator 默认 textAlignVertical 为 top，固定
                    // 44dp 高度下需显式居中（批次 8 library_page 教训）
                    textAlignVertical: TextAlignVertical.center,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _performSearch,
                    onChanged: (value) {
                      setState(() {});
                      if (value.trim().isNotEmpty) {
                        context.read<KugouProvider>().getSearchSuggest(
                          value.trim(),
                        );
                      }
                    },
                  ),
                ),
                // 听歌识曲钮（与首页 _buildSearchFieldItem 一致）：内层
                // GestureDetector 单独响应，不与整体胶囊的点击冲突
                // （搜索页胶囊无整体 onTap，识曲钮是当前唯一识曲入口）。
                GestureDetector(
                  onTap: _openRecognition,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12,
                    ),
                    child: Icon(
                      Icons.mic_none,
                      size: 20,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                if (hasText)
                  IconButton(
                    // 28dp 命中区（视觉 18dp 图标），顶满 44dp 行高便于点按
                    constraints: const BoxConstraints.tightFor(width: 36, height: 44),
                    padding: const EdgeInsets.only(right: 6),
                    icon: Icon(
                      Icons.clear,
                      size: 18,
                      color: sonify.textSecondary,
                    ),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _query = '';
                        _hasSearched = false;
                      });
                    },
                  ),
                if (!hasText) const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 识曲入口：[SongRecognitionPage] 为独立路由页（非 tab 项），
  /// 与首页搜索框识曲钮同款 MaterialPageRoute 跳转方式。
  void _openRecognition() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SongRecognitionPage()),
    );
  }

  Widget _buildEmptyState() {
    // 未输入关键词：搜索历史 + 热门搜索（批次 1 恢复）+ 音乐探索
    // （从发现页迁移的内容模块，与首页共享 Rail 数据缓存）。
    return ListView(
      // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度）
      padding: EdgeInsets.only(
        bottom: AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        if (_searchHistory.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('搜索历史', style: _kGroupHeaderStyle(context)),
                TextButton(
                  onPressed: _clearSearchHistory,
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _searchHistory.map((history) {
                return _SearchKeywordChip(
                  label: history,
                  onTap: () {
                    _searchController.text = history;
                    _performSearch(history);
                  },
                );
              }).toList(),
            ),
          ),
        ],
        // 搜索历史与下方「热门搜索」之间加大间距，形成明显分段。
        if (_searchHistory.isNotEmpty) const Gap(AppSpacing.lg),
        // 热门搜索（恢复）：/search/hot Chip 流置于历史下方；
        // 前 3 名加 11sp 次级灰序号角标（方案 §2.3）。
        Selector<KugouProvider, List<String>>(
          selector: (_, kugou) => kugou.hotSearchKeywords,
          builder: (context, hotKeywords, _) {
            if (hotKeywords.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
                  child: Text('热门搜索', style: _kGroupHeaderStyle(context)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < hotKeywords.length; i++)
                        _SearchKeywordChip(
                          label: hotKeywords[i],
                          rank: i < 3 ? i + 1 : null,
                          onTap: () {
                            _searchController.text = hotKeywords[i];
                            _performSearch(hotKeywords[i]);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        const Gap(AppSpacing.lg),
        // 音乐探索：主题歌单 / 场景音乐 / 热门歌单 / 排行榜 / 新碟上架，
        // 复用 KugouProvider 已有数据与缓存（内部数据为空时自动补拉）。
        const MusicExploreSections(),
      ],
    );
  }

  Widget _buildSearchResults() {
    return TabBarView(
      controller: _tabController,
      children: [
        _buildSongResults(),
        _buildAlbumResults(),
        _buildArtistResults(),
        _buildPlaylistResults(),
        _buildCloudResults(),
        _buildLyricResults(),
      ],
    );
  }

  Widget _buildSuggestions() {
    final colorScheme = Theme.of(context).colorScheme;
    final kugouProvider = context.watch<KugouProvider>();
    final suggestions = kugouProvider.searchSuggest;

    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListView.builder(
      // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度）
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: suggestions.length,
      itemBuilder: (context, index) {
        final suggestion = suggestions[index];
        return ListTile(
          leading: Icon(
            Icons.search,
            size: 20,
            color: colorScheme.onSurfaceVariant,
          ),
          // 联想 13sp，命中关键词片段用 primary 色高亮（方案 §2.3）
          title: _buildHighlightedSuggestion(
            suggestion,
            _searchController.text,
          ),
          dense: true,
          onTap: () {
            _searchController.text = suggestion;
            FocusManager.instance.primaryFocus?.unfocus();
            _performSearch(suggestion);
          },
        );
      },
    );
  }

  /// 联想条目文本：包含查询词的部分以 primary 色渲染（大小写不敏感）。
  Widget _buildHighlightedSuggestion(String suggestion, String query) {
    final colorScheme = Theme.of(context).colorScheme;
    final q = query.trim();
    final baseStyle = SonifyTextStyles.listItem.copyWith(
      color: colorScheme.onSurface,
    );
    if (q.isEmpty) {
      return Text(
        suggestion,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }
    final lower = suggestion.toLowerCase();
    final lowerQ = q.toLowerCase();
    final hitStyle = baseStyle.copyWith(
      color: colorScheme.primary,
      fontWeight: FontWeight.w500,
    );
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final idx = lower.indexOf(lowerQ, start);
      if (idx < 0) {
        if (start < suggestion.length) {
          spans.add(TextSpan(text: suggestion.substring(start)));
        }
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: suggestion.substring(start, idx)));
      }
      spans.add(TextSpan(
        text: suggestion.substring(idx, idx + q.length),
        style: hitStyle,
      ));
      start = idx + q.length;
    }
    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildSongResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.songs.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.songs.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'song');
      });
    }

    final searchResults = kugouProvider.searchResults;
    List<Song> results = [];

    if (searchResults != null && searchResults.songs.isNotEmpty) {
      results = searchResults.songs.map((e) => e.toSong()).toList();
    }

    if (results.isEmpty) {
      return _buildNoResult();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'song');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度）
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: results.length,
              itemBuilder: (context, index) {
                return SongListItem(
                  song: results[index],
                  showDuration: false,
                  trailingActions: SongTrailingActions.detail,
                  onTap: () {
                    context.read<PlayerProvider>().playOnlinePlaylist(
                      results,
                      index,
                    );
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  /// 歌词搜索结果：按歌词片段搜索到的歌曲列表，每项副标题显示匹配的歌词片段。
  Widget _buildLyricResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.songs.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.songs.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'lyric');
      });
    }

    final results = kugouProvider.searchResults?.songs ?? const <KugouSongDetail>[];

    if (results.isEmpty) {
      return _buildNoResult();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'lyric');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度）
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: results.length,
              itemBuilder: (context, index) {
                final detail = results[index];
                final snippet = detail.lyrics ?? '';
                final song = detail.toSong();
                final cs = Theme.of(context).colorScheme;
                final tt = Theme.of(context).textTheme;
                return SongListItem(
                  song: song,
                  showDuration: false,
                  trailingActions: SongTrailingActions.detail,
                  // 保留命中的歌词片段作为副标题（primary 强调）。
                  subtitleOverride: Text(
                    snippet.isNotEmpty ? snippet : song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelSmall?.copyWith(
                      color: snippet.isNotEmpty
                          ? cs.primary.withValues(alpha: 0.85)
                          : cs.onSurfaceVariant,
                    ),
                  ),
                  onTap: () {
                    final songs = results.map((e) => e.toSong()).toList();
                    context.read<PlayerProvider>().playOnlinePlaylist(
                      songs,
                      index,
                    );
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  void _showAlbumDetail(Album album) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)));
  }

  Widget _buildAlbumResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.albums.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.albums.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'album');
      });
    }

    final searchResults = kugouProvider.searchResults;
    List<Album> results = [];

    if (searchResults != null && searchResults.albums.isNotEmpty) {
      results = searchResults.albums.map((e) => e.toAlbum()).toList();
    }

    if (results.isEmpty) {
      return _buildNoResult();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'album');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            // 用 PinchableGridView 替代固定 2 列的 GridView，
            // Pad 模式下可双指捏合动态调整列数，非 Pad 模式仍固定 2 列
            child: PinchableGridView(
              // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度）
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
              ),
              // 原 childAspectRatio 0.75、spacing 12 保持不变
              childAspectRatio: 0.75,
              spacing: 12,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final album = results[index];
                final cleanName = album.name.replaceAll(RegExp(r'<[^>]*>'), '');
                final cleanArtist = album.artist.replaceAll(
                  RegExp(r'<[^>]*>'),
                  '',
                );
                return _SearchAlbumCard(
                  name: cleanName,
                  artist: cleanArtist,
                  artworkUri: album.artworkUri,
                  icon: Icons.album,
                  onTap: () => _showAlbumDetail(album),
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  Widget _buildArtistResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.artists.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.artists.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'artist');
      });
    }

    final searchResults = kugouProvider.searchResults;
    List<KugouArtistBrief> results = [];

    if (searchResults != null && searchResults.artists.isNotEmpty) {
      results = searchResults.artists;
    }

    if (results.isEmpty) {
      return _buildNoResult();
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'artist');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            // 歌手是卡片类结果：手机竖屏（<600）单列，变宽后铺成多列横向卡片（计划 ⑥）。
            child: AdaptiveContentGrid(
              // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度）
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
              ),
              targetExtent: 380,
              childAspectRatio: 3.5,
              spacing: AppSpacing.sm,
              minColumns: 2,
              maxColumns: 3,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final artist = results[index];
                return ListTile(
                  leading: _ArtistAvatar(
                    artistId: artist.id,
                    avatarUrl: artist.avatarUrl,
                    size: 48,
                  ),
                  title: Text(
                    artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text('歌手'),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ArtistDetailPage(
                          artistId: artist.id,
                          artistName: artist.name,
                          avatarUrl: artist.avatarUrl,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaylistResults() {
    final kugouProvider = context.watch<KugouProvider>();

    if (kugouProvider.isLoading &&
        (kugouProvider.searchResults?.playlists.isEmpty ?? true)) {
      return const Center(child: M3ELoadingIndicator());
    }

    if (kugouProvider.error != null &&
        (kugouProvider.searchResults?.playlists.isEmpty ?? true)) {
      return _buildErrorState(kugouProvider.error!, () {
        kugouProvider.clearError();
        _performSearchByType(_query, 'special');
      });
    }

    final searchResults = kugouProvider.searchResults;
    List<KugouPlaylistBrief> results = [];

    if (searchResults != null && searchResults.playlists.isNotEmpty) {
      results = searchResults.playlists;
    }

    if (results.isEmpty) {
      return _buildNoResult();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          context.read<KugouProvider>().loadMoreSearchResults(type: 'special');
        }
        return false;
      },
      child: Column(
        children: [
          Expanded(
            // 用 PinchableGridView 替代固定 2 列的 GridView，
            // Pad 模式下可双指捏合动态调整列数，非 Pad 模式仍固定 2 列
            child: PinchableGridView(
              // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度）
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
              ),
              // 原 childAspectRatio 0.75、spacing 12 保持不变
              childAspectRatio: 0.75,
              spacing: 12,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final pl = results[index];
                final cleanName = pl.name.replaceAll(RegExp(r'<[^>]*>'), '');
                return _SearchAlbumCard(
                  name: cleanName,
                  artist: pl.songCount > 0 ? '${pl.songCount} 首歌曲' : '',
                  artworkUri: pl.coverUrl,
                  icon: Icons.queue_music,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistPage(playlist: pl.toPlaylist()),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (kugouProvider.isLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: M3ELoadingIndicator(constraints: BoxConstraints.tightFor(width: 24, height: 24)),
            ),
        ],
      ),
    );
  }

  /// 云盘歌曲加载上限，与 [CloudMusicPage] 对齐。
  static const int _maxCloudSongs = 6000;

  /// 加载云盘歌曲列表（仅进入云盘 tab 时按需调用一次）。
  /// 分页拉取最多 [_maxCloudSongs] 首，加载完成后由 [_query] 在 [_filteredCloudSongs] 中过滤。
  Future<void> _loadCloudSongsForSearch() async {
    if (_cloudLoading) return;
    setState(() {
      _cloudLoading = true;
      _cloudError = null;
    });
    try {
      final api = KugouApiClient();
      if (!api.isLoggedIn) {
        setState(() {
          _cloudLoading = false;
          _cloudError = '请先登录';
        });
        return;
      }
      const int pageSize = 100;
      const int maxPages = (_maxCloudSongs + pageSize - 1) ~/ pageSize;
      final songs = <Song>[];
      for (int page = 1; page <= maxPages; page++) {
        final result = await api.getUserCloud(page: page, pagesize: pageSize);
        if (!mounted) return;
        if (result == null) {
          if (page == 1) {
            setState(() {
              _cloudLoading = false;
              _cloudError = '加载失败，请稍后重试';
            });
            return;
          }
          break;
        }
        final data = result['data'];
        List<dynamic>? list;
        if (data is List) {
          list = data;
        } else if (data is Map<String, dynamic>) {
          list = data['info'] as List<dynamic>?;
          list ??= data['list'] as List<dynamic>?;
        }
        if (list == null || list.isEmpty) break;
        for (final e in list) {
          if (e is Map<String, dynamic>) {
            final song = mapCloudApiItemToSong(e);
            if (song.id.isNotEmpty) songs.add(song);
          }
        }
        if (songs.length >= _maxCloudSongs) {
          songs.removeRange(_maxCloudSongs, songs.length);
          break;
        }
        if (list.length < pageSize) break;
      }
      setState(() {
        _cloudSongs = songs;
        _cloudLoaded = true;
        _cloudLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _cloudLoading = false;
          _cloudError = '加载失败：$e';
        });
      }
    }
  }

  /// 根据 [_query] 内存过滤已加载的云盘歌曲（title/artist 子串、不区分大小写）。
  List<Song> get _filteredCloudSongs {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _cloudSongs;
    return _cloudSongs.where((s) {
      return s.title.toLowerCase().contains(q) ||
          s.artist.toLowerCase().contains(q);
    }).toList();
  }

  Widget _buildCloudResults() {
    if (_cloudLoading) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (_cloudError != null) {
      return _buildErrorState(_cloudError!, _loadCloudSongsForSearch);
    }
    if (!_cloudLoaded) {
      // 极端情况：未搜索过就跳到云盘 tab —— 主动触发加载
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_cloudLoaded && !_cloudLoading) {
          _loadCloudSongsForSearch();
        }
      });
      return const Center(child: M3ELoadingIndicator());
    }
    final results = _filteredCloudSongs;
    if (results.isEmpty) {
      return _buildNoResult();
    }
    return ListView.builder(
      // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度）
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        return SongListItem(
          song: results[index],
          onTap: () {
            // 必须用 playCloudPlaylist 走 /user/cloud/url 解析
            context.read<PlayerProvider>().playCloudPlaylist(results, index);
          },
        );
      },
    );
  }

  Widget _buildErrorState(String error, VoidCallback onRetry) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const Gap(AppSpacing.md),
            Text(
              '搜索失败',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const Gap(AppSpacing.sm),
            Text(
              error,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const Gap(AppSpacing.lg),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResult() {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const Gap(AppSpacing.md),
          Text(
            '未找到相关结果',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索结果列表中的歌手头像：搜索接口通常不返回头像 URL，
/// 这里用 getArtistDetail 接口异步补全。
class _ArtistAvatar extends StatefulWidget {
  final String artistId;
  final String? avatarUrl;
  final double size;

  const _ArtistAvatar({required this.artistId, this.avatarUrl, this.size = 48});

  @override
  State<_ArtistAvatar> createState() => _ArtistAvatarState();
}

class _ArtistAvatarState extends State<_ArtistAvatar> {
  String? _resolvedUrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty) {
      // 搜索接口已经带了头像，直接用
      _resolvedUrl = _fixUrl(widget.avatarUrl);
      _loading = false;
    } else {
      _resolveAvatar();
    }
  }

  Future<void> _resolveAvatar() async {
    if (widget.artistId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final detail = await KugouApiClient().getArtistDetail(widget.artistId);
      if (!mounted) return;
      final url = _fixUrl(detail?.avatarUrl);
      setState(() {
        _resolvedUrl = url;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String? _fixUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'https://');
    }
    return url;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = widget.size;

    Widget placeholder() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.person,
        color: colorScheme.onSurfaceVariant,
        size: size * 0.5,
      ),
    );

    if (_loading) {
      return SizedBox(width: size, height: size, child: placeholder());
    }

    final url = _resolvedUrl;
    if (url == null) return placeholder();

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        memCacheWidth: 144,
        memCacheHeight: 144,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => placeholder(),
        errorWidget: (_, _, _) => placeholder(),
      ),
    );
  }
}

/// 搜索历史/热门搜索关键字 chip（sonify 规格，方案 §2.1/§2.3）：
/// squircle 8dp、卡底色、13sp 文字；[rank] 非空时渲染 11sp 次级灰序号角标
/// （热门搜索前 3 名）。
class _SearchKeywordChip extends StatelessWidget {
  final String label;
  final int? rank;
  final VoidCallback onTap;

  const _SearchKeywordChip({
    required this.label,
    required this.onTap,
    this.rank,
  });

  @override
  Widget build(BuildContext context) {
    final sonify = SonifyColors.of(context);
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: ShapeDecoration(
          color: sonify.surfaceCard,
          shape: SmoothRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (rank != null) ...[
              Text(
                '$rank',
                style: TextStyle(fontSize: 11, color: sonify.textSecondary),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: SonifyTextStyles.listItem.copyWith(color: cs.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态分组标题（搜索历史/热门搜索）：13sp（方案 §2.2 布局线框）。
TextStyle _kGroupHeaderStyle(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return SonifyTextStyles.listItem.copyWith(
    color: cs.onSurface,
    fontWeight: FontWeight.w500,
  );
}

class _SearchAlbumCard extends StatelessWidget {
  final String name;
  final String artist;
  final String? artworkUri;
  final IconData icon;
  final VoidCallback? onTap;

  const _SearchAlbumCard({
    required this.name,
    required this.artist,
    this.artworkUri,
    this.icon = Icons.album,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: AppRadius.mdAll,
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: artworkUri != null
                    ? CachedNetworkImage(
                        imageUrl: artworkUri!,
                        memCacheWidth: 540,
                        memCacheHeight: 540,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        placeholder: (_, _) => _buildPlaceholder(colorScheme),
                        errorWidget: (_, _, _) =>
                            _buildPlaceholder(colorScheme),
                      )
                    : _buildPlaceholder(colorScheme),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, AppSpacing.sm, 10, AppSpacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    if (artist.isNotEmpty) ...[
                      const Gap(AppSpacing.xxs),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(icon, size: 40, color: colorScheme.onSurfaceVariant),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  /// 是否启用壁纸背景（与顶部 SliverAppBar 的 flexibleSpace 联动）。
  final bool useBackgroundImage;
  final double backgroundOpacity;
  final double backgroundBlur;
  /// 预计算的背景图 [ImageProvider]（由 SearchPage.build 传入，
  /// 与 SliverAppBar flexibleSpace 共享 ImageCache 同 key 解码结果）。
  /// 不在 delegate.build 内 watch ThemeProvider，避免污染 sliver 链。
  final ImageProvider? backgroundImage;

  _TabBarDelegate({
    required this.tabBar,
    required this.useBackgroundImage,
    required this.backgroundOpacity,
    required this.backgroundBlur,
    required this.backgroundImage,
  });

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return tabBar != oldDelegate.tabBar ||
        useBackgroundImage != oldDelegate.useBackgroundImage ||
        backgroundOpacity != oldDelegate.backgroundOpacity ||
        backgroundBlur != oldDelegate.backgroundBlur ||
        backgroundImage != oldDelegate.backgroundImage;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!useBackgroundImage || backgroundImage == null) {
      return Container(color: colorScheme.surface, child: tabBar);
    }
    // 有壁纸：与顶部 SliverAppBar flexibleSpace 同结构（surface 打底 +
    // 模糊 + 透明度 + 全屏 cover 背景图 topCenter 裁剪），tab 栏与
    // 搜索框背景视觉连续。ClipRect 把 OverflowBox 溢出内容裁到本 sliver
    // 区域，避免盖住下方 TabBarView 结果区。
    final size = MediaQuery.sizeOf(context);
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minWidth: size.width,
              maxWidth: size.width,
              minHeight: size.height,
              maxHeight: size.height,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: colorScheme.surface),
                    Opacity(
                      opacity: backgroundOpacity,
                      child: ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: backgroundBlur,
                          sigmaY: backgroundBlur,
                        ),
                        child: Image(
                          image: backgroundImage!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          tabBar,
        ],
      ),
    );
  }
}
