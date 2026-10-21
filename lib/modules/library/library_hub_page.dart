import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
// showM3EModalBottomSheet（隐藏歌单底部弹层）。m3e_core 与本地 fork 的
// M3EPullToRefreshIndicator 同名，按 favorites_page 同款 hide 处理。
import 'package:m3e_core/m3e_core.dart' hide M3EPullToRefreshIndicator;
import 'package:provider/provider.dart';

import '../../core/layout/adaptive_navigator.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../data/repositories/favorite_lists_cache.dart';
import '../../data/repositories/hidden_playlists_cache.dart';
import '../../data/repositories/history_repository.dart';
import '../../data/repositories/playlist_cover_cache.dart';
import '../../data/repositories/playlist_cover_resolver.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/common/cover_rail.dart';
import '../../widgets/common/content_scroll_signal.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import '../../widgets/common/user_avatar_button.dart';
import '../../widgets/m3e_pull_to_refresh_fixed.dart';
import '../../widgets/smart_artwork_image.dart';
import '../playlist/playlist_page.dart';
import '../playlist/playlist_songs_loader.dart';
import '../user/cloud_music_page.dart';
import '../user/favorites_page.dart';
import '../user/play_history_page.dart';
import '../user/purchased_page.dart';
import 'library_page.dart' show LibraryPage;

/// 音乐库一级页（IA 改版：资产入口聚合中枢）。
///
/// 页面定位：按「资产归属」组织四大资产入口，完整内容下沉二级子页：
/// - 骨架：[SonifyTitleScaffold] 固定悬浮大标题「音乐库」；右上角
///   **常驻**用户头像（走 [SonifyTitleScaffold.trailing]，不随滚动
///   淡入淡出——与首页/FM/搜索三页顶栏完全统一）；扫描钮（原 FAB
///   职责）走 actions（仅栏体浮现后淡入，扫描中转圈禁用防重复触发）。
///   批次 19：移除顶栏常驻搜索圆钮——全局搜索由底部导航常驻搜索
///   tab 承载；
/// - 入口区：2×2 squircle 卡片（收藏 / 本地 / 已购 / 云盘）。收藏卡
///   额外带「直接播放」圆钮：不点开卡片即播放「我喜欢」（缓存优先、
///   倒序从最新收藏始，链路同收藏页封面一键播放）；点开卡片则直达
///   「我喜欢」歌单详情（[PlaylistPage]，isDefaultFavorite，与收藏页
///   点击歌单行同款导航）；未登录先提示登录，找不到「我喜欢」
///   （无缓存 / 被隐藏）时兜底进收藏页歌单 tab；
/// - 列表分区：最近播放 Top 3（点标题行看全部播放历史）+ 我创建的歌单
///   + 我收藏的歌单，后两者用主页热门歌单同款 [CoverRail]/
///   [CoverRailCard] 样式（创建/收藏区分规则同 [FavoritesPage]，见
///   [_isCreatedPlaylist]）；
/// - 隐藏歌单：两个歌单调区标题行带「管理」入口，进入多选态后可批量
///   隐藏（本地视图偏好，仓库见 [HiddenPlaylistsCache]），分区下方
///   「已隐藏 N 个歌单」可点开底部弹层逐项恢复；
/// - 歌单为空时分区显示空态文案即可，登录引导由目标子页自行处理。
class LibraryHubPage extends StatefulWidget {
  const LibraryHubPage({super.key});

  @override
  State<LibraryHubPage> createState() => _LibraryHubPageState();
}

/// 音乐库页面局部尺寸规格（页面内唯一来源）。
abstract final class _HubDimens {
  /// 最近播放列表行高。
  static const double rowHeight = 56;

  /// 列表行封面边长。
  static const double rowCover = 44;

  /// 入口卡片最小高度（2×2 网格两行等高）。
  static const double entryCardMinHeight = 88;

  /// 入口卡片图标边长。
  static const double entryCardIcon = 22;

  /// 收藏卡「直接播放」圆钮边长（卡右侧，tonal 圆形底）。
  static const double playButton = 36;

  /// 收藏卡播放钮图标边长。
  static const double playButtonIcon = 20;

  /// 播放中进度环边长（小于钮心，留出描边余量）。
  static const double playButtonSpinner = 18;
}

/// 歌单分区标识（管理态 / 隐藏提示按分区隔离）。
const int _kGroupCreated = 1; // 我创建的歌单
const int _kGroupCollected = 2; // 我收藏的歌单

class _LibraryHubPageState extends State<LibraryHubPage> {
  // 云端歌单（FavoritesPage 同源缓存链路；区分「创建 vs 收藏」见
  // _isCreatedPlaylist。云端收藏专辑/歌手不进 IA（归属收藏语义，由
  // FavoritesPage 承载）。
  List<KugouPlaylistBrief> _playlists = [];

  // 最近播放（Top 3 数据源）
  List<Song> _history = [];

  // 已隐藏歌单 key 集合（HiddenPlaylistsCache，与收藏页共用同一仓库）
  Set<String> _hiddenKeys = {};

  // 无封面歌单的「首曲封面」解析结果（playlistKey → https url），
  // 与本地持久化缓存（PlaylistCoverCache）合并后的视图。
  Map<String, String> _covers = {};

  // 首曲封面解析中（防重入：重复加载不并发发请求）
  bool _resolvingCovers = false;

  // 本页面生命周期内已尝试解析过的歌单 key：避免每次刷新都对
  // 「解析不到封面」的歌单重复发请求（刷新时保留，不随 _loadPlaylists 清空）
  final Set<String> _coverAttempted = {};

  // 歌单分区多选管理态：null=非管理；_kGroupCreated / _kGroupCollected
  int? _managingGroup;
  final Set<String> _selectedKeys = {};

  // 内层列表滚动信号（true = 已离开顶部）：本页外层骨架是单固定高
  // item、自身不滚动，内层 ListView 的滚动经 [ContentScrollSignal] 上传
  // 到此，注入 SonifyTitleScaffold.barBackgroundVisible 让顶栏渐变
  // 模糊带与首页同拍浮现（批次 24：tab 页顶栏背景一致）。
  final ValueNotifier<bool> _contentScrolled = ValueNotifier<bool>(false);
  // 「我喜欢」封面一键播放中（防重复点击，局部进度环）
  bool _playingMyFavorite = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 首帧提速：三组加载互不依赖，并行发起（各组内部的
      // SharedPreferences 读亦已并行化，见 _loadPlaylists）。
      // 「本地」入口卡副标题计数：先恢复缓存歌曲（与 LibraryMusicPanel
      // 同口径，不自动触发扫描）；歌单分区直读 FavoriteListsCache，
      // 最近播放直读 HistoryRepository；实时网络同步由下拉刷新承载
      // （_syncPlaylistsIfLoggedIn）。
      unawaited(
        Future.wait([
          context.read<LibraryProvider>().loadSavedSongs(),
          _loadPlaylists(),
          _loadHistory(),
        ]),
      );
    });
  }

  Future<void> _loadPlaylists() async {
    // 三块本地读并行（歌单 / 隐藏集合 / 首曲封面缓存），避免串行
    // await 把首帧空态拖长（PlaylistCoverCache 此前单独占一段）。
    final results = await Future.wait([
      FavoriteListsCache.readPlaylists(),
      HiddenPlaylistsCache.readHidden(),
      PlaylistCoverCache.readAll(),
    ]);
    if (!mounted) return;
    final playlists = results[0] as List<KugouPlaylistBrief>;
    final hidden = results[1] as Set<String>;
    final covers = results[2] as Map<String, String>;
    setState(() {
      _playlists = playlists;
      _hiddenKeys = hidden;
      _covers = covers;
    });
    // 批次18：登录后首开若缓存为空（冷启动未同步过歌单），立即拉一次
    // 云端歌单并重读缓存渲染；未登录 / 离线时静默保持缓存态，实时同步
    // 仍由下拉刷新（[_refresh] → _syncPlaylistsIfLoggedIn）承载。
    if (_playlists.isEmpty && KugouApiClient().isLoggedIn) {
      await _syncPlaylistsIfLoggedIn();
      final refreshed = await FavoriteListsCache.readPlaylists();
      if (!mounted) return;
      setState(() => _playlists = refreshed);
    }
    // 无封面歌单旁路解析：不阻塞列表首屏（串行限流见 _resolveMissingCovers）
    unawaited(_resolveMissingCovers());
  }

  /// 为 `coverUrl` 为空的歌单解析末曲封面（缓存 → 本地歌曲 → 末页轻请求）。
  ///
  /// 限流：每轮最多 8 个歌单；串行 for（并发 1）；同一歌单在本页生命周期
  /// 内最多尝试一次（[_coverAttempted]）；整体失败静默，只回退占位图。
  Future<void> _resolveMissingCovers() async {
    if (_resolvingCovers) return;
    _resolvingCovers = true;
    try {
      final pending = _playlists
          .where((p) => (p.coverUrl ?? '').isEmpty)
          .take(8)
          .toList();
      for (final playlist in pending) {
        final key = HiddenPlaylistsCache.playlistKey(playlist);
        if (_covers.containsKey(key)) continue;
        if (!_coverAttempted.add(key)) continue;
        final url = await resolveLastSongCover(playlist, cached: _covers);
        if (!mounted) return;
        if (url != null && url.isNotEmpty) {
          setState(() => _covers[key] = url);
        }
      }
    } catch (_) {
      // 静默：封面解析失败不影响歌单列表
    } finally {
      _resolvingCovers = false;
    }
  }

  Future<void> _loadHistory() async {
    final history = await HistoryRepository().getHistory();
    if (!mounted) return;
    setState(() {
      _history = history;
    });
  }

  /// 下拉刷新：本地歌曲缓存（入口卡计数）+ 云端歌单同步（登录态）+
  /// 歌单缓存链路 + 隐藏集合 + 最近播放重读。
  ///
  /// 「刷新不出来」根因修复：此前只重读本地缓存，数据零变化。现按
  /// 收藏页口径（favorites_page._loadPlaylists forceNoCache）在登录态
  /// 强制拉全量歌单并写缓存，再重读缓存刷新 UI；未登录 / 网络失败时
  /// 静默保持缓存态，转圈不卡死。
  Future<void> _refresh() async {
    await context.read<LibraryProvider>().loadSavedSongs();
    // 先同步再重读：_syncPlaylistsIfLoggedIn 只写仓库，不碰 UI 状态，
    // 不会触发 _loadPlaylists 递归刷新。
    await _syncPlaylistsIfLoggedIn();
    await _loadPlaylists();
    await _loadHistory();
  }

  /// 登录态歌单强制同步：复刻收藏页 _loadPlaylists(forceNoCache: true)
  /// 口径——getUserPlaylist(page:1, pagesize:30, noCache:true) → 过滤
  /// （type==1 && source==2 的收藏专辑/歌手项）→ FavoriteListsCache
  /// .savePlaylists（保留**未过滤 hidden** 的列表，隐藏状态单独持久化
  /// 于 HiddenPlaylistsCache）。
  ///
  /// 失败静默：KugouApiClient._get 网络/服务异常时返回 null（不抛），
  /// 其余异常也吞掉——刷新失败保持本地缓存态即可。
  Future<void> _syncPlaylistsIfLoggedIn() async {
    if (!KugouApiClient().isLoggedIn) return;
    try {
      final result = await KugouApiClient().getUserPlaylist(
        page: 1,
        pagesize: 30,
        noCache: true,
      );
      // null = 离线信号（_get 吞错返回 null），保持缓存态
      if (result == null) return;
      final data = result['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>?;
        list ??= data['list'] as List<dynamic>?;
      }
      if (list == null || list.isEmpty) return;
      final filtered = list
          .where((e) {
            final json = e as Map<String, dynamic>;
            final type = json['type'] as int? ?? 0;
            final source = json['source'] as int? ?? 0;
            if (type == 1 && source == 2) return false;
            return true;
          })
          .map((e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>))
          .toList();
      await FavoriteListsCache.savePlaylists(filtered);
    } catch (_) {
      // 静默：同步失败保持缓存态
    }
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

  bool _isHidden(KugouPlaylistBrief p) =>
      _hiddenKeys.contains(HiddenPlaylistsCache.playlistKey(p));

  List<KugouPlaylistBrief> get _createdPlaylists => _playlists
      .where(
        (p) =>
            _isCreatedPlaylist(p) &&
            // 0 首歌单默认不出现（口径见
            // HiddenPlaylistsCache.isEmptyCreatedPlaylist，对齐 sonify）
            !HiddenPlaylistsCache.isEmptyCreatedPlaylist(p) &&
            !_isHidden(p),
      )
      .toList();

  List<KugouPlaylistBrief> get _collectedPlaylists =>
      _playlists.where((p) => !_isCreatedPlaylist(p) && !_isHidden(p)).toList();

  /// 某分区下被隐藏的歌单（底部弹层数据源：从全量 _playlists 按 key 过滤）。
  List<KugouPlaylistBrief> _hiddenPlaylistsOf(int group) {
    final hidden = _playlists.where(_isHidden);
    return group == _kGroupCreated
        ? hidden.where(_isCreatedPlaylist).toList()
        : hidden.where((p) => !_isCreatedPlaylist(p)).toList();
  }

  // ==================== 交互 ====================

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  /// 打开歌单详情（「我创建的歌单」/「我收藏的歌单」横滑轨卡片点击）。
  ///
  /// 批次 22：补齐与收藏页 [_openMyFavorite]/favorites_page._openPlaylistDetail
  /// 同款的两个语义标记——
  /// - `isUserCreated`：自己创建的歌单（可批量删歌）；
  /// - `isDefaultFavorite`：名字为「我喜欢」的默认收藏歌单。**必须传**：
  ///   [PlaylistPage] 头部封面只在 `isDefaultFavorite` 时套用「最新收藏
  ///   歌曲的专辑封面」动态来源（歌单接口对这种系统歌单不返回封面），
  ///   漏传就会出现「从收藏点开有封面、从我创建的歌单点开无封面」的
  ///   同一歌单两种表现（用户反馈）。
  void _openPlaylist(KugouPlaylistBrief playlist) {
    AdaptiveNav.openDetail(
      context,
      (_) => PlaylistPage(
        playlist: playlist.toPlaylist(),
        isInMyFavorites: true,
        isUserCreated: _isCreatedPlaylist(playlist),
        isDefaultFavorite: playlist.name == '我喜欢',
      ),
    );
  }

  /// 收藏卡「直接播放」钮：不点开卡片即播放「我喜欢」。
  ///
  /// 链路与收藏页封面一键播放同款：缓存优先（PlaylistSongsLoader
  /// .readCached），空则拉网络（.fetch），倒序播放（云端按收藏正序返回，
  /// 反序后从最新收藏始），只等队列构建完成即释放进度环。未登录时
  /// playOnlinePlaylist 会静默走 onLoginRequired，故播放前先拦截提示。
  Future<void> _playMyFavorite() async {
    if (_playingMyFavorite) return; // 防重复点击
    if (!KugouApiClient().isLoggedIn) {
      showToast('请先登录');
      return;
    }
    KugouPlaylistBrief? myFavorite;
    for (final p in _playlists) {
      if (p.name == '我喜欢') {
        myFavorite = p;
        break;
      }
    }
    if (myFavorite == null) {
      showToast('暂无「我喜欢」歌单');
      return;
    }
    setState(() => _playingMyFavorite = true);
    try {
      final p = myFavorite.toPlaylist();
      var songs = await PlaylistSongsLoader.readCached(
        p,
        isInMyFavorites: true,
      );
      if (songs.isEmpty) {
        final r = await PlaylistSongsLoader.fetch(context, p);
        songs = r.songs;
      }
      if (!mounted) return;
      if (songs.isEmpty) {
        showToast('歌单加载失败，请检查网络后重试', long: true);
        return;
      }
      // 倒序播放：歌单接口按收藏时间升序返回（最早在前、最新在后），
      // 反转后从最新收藏开始。只等队列构建完成即释放进度环，不等整条
      // URL 解析/播放链（playOnlinePlaylist 内部自带失败链式 next）。
      final ordered = songs.reversed.toList();
      unawaited(context.read<PlayerProvider>().playOnlinePlaylist(ordered, 0));
      showToast('开始播放「我喜欢」');
    } catch (_) {
      if (mounted) showToast('歌单加载失败，请检查网络后重试', long: true);
    } finally {
      if (mounted) setState(() => _playingMyFavorite = false);
    }
  }

  /// 收藏卡（「我喜欢」）点击：直达「我喜欢」歌单详情，导航口径与
  /// 收藏页点击歌单行完全一致（favorites_page._openPlaylistDetail：
  /// AdaptiveNav.openDetail → PlaylistPage，isDefaultFavorite 按名称
  /// 判定；hub 无访问排序状态，不记录 _recordPlaylistAccess）。
  ///
  /// 未登录先拦截提示（与 [_playMyFavorite] 同款 guard）；找不到
  /// 「我喜欢」（无缓存 / 被隐藏）时兜底进收藏页歌单 tab，由用户
  /// 自行查看，不报错。
  Future<void> _openMyFavorite() async {
    if (!KugouApiClient().isLoggedIn) {
      showToast('请先登录');
      return;
    }
    final fav = _findMyFavorite();
    if (fav == null) {
      _push(context, const FavoritesPage(initialTab: 0));
      return;
    }
    AdaptiveNav.openDetail(
      context,
      (_) => PlaylistPage(
        playlist: fav.toPlaylist(),
        isInMyFavorites: true,
        isUserCreated: _isCreatedPlaylist(fav),
        isDefaultFavorite: true,
      ),
    );
  }

  /// 「我喜欢」定位：与收藏页 _myFavoritePlaylist 同口径（name ==
  /// '我喜欢'），并跳过被用户隐藏的歌单（hub 各分区不展示 hidden，
  /// 命中 hiddenKeys 时对用户等同「不存在」，走兜底更诚实）。
  KugouPlaylistBrief? _findMyFavorite() {
    for (final p in _playlists) {
      if (p.name != '我喜欢') continue;
      if (_isHidden(p)) continue;
      return p;
    }
    return null;
  }

  // ==================== 隐藏歌单（管理态） ====================

  void _enterManage(int group) {
    setState(() {
      _managingGroup = group;
      _selectedKeys.clear();
    });
  }

  void _exitManage() {
    setState(() {
      _managingGroup = null;
      _selectedKeys.clear();
    });
  }

  /// 管理态点歌单卡：切换选中（不跳详情）。
  void _toggleSelect(KugouPlaylistBrief playlist) {
    final key = HiddenPlaylistsCache.playlistKey(playlist);
    setState(() {
      if (!_selectedKeys.remove(key)) _selectedKeys.add(key);
    });
  }

  /// 「隐藏所选」：与既有隐藏集合求并集写回仓库，退出管理态。
  Future<void> _hideSelected() async {
    if (_selectedKeys.isEmpty) return;
    final keys = {..._hiddenKeys, ..._selectedKeys};
    await HiddenPlaylistsCache.writeHidden(keys);
    if (!mounted) return;
    setState(() {
      _hiddenKeys = keys;
      _managingGroup = null;
      _selectedKeys.clear();
    });
  }

  /// 底部弹层内「恢复」：切换隐藏状态并刷新页面与弹层。
  Future<void> _restorePlaylist(String key) async {
    await HiddenPlaylistsCache.toggleHidden(key);
    if (!mounted) return;
    final keys = await HiddenPlaylistsCache.readHidden();
    setState(() => _hiddenKeys = keys);
  }

  /// 「已隐藏 N 个歌单」底部弹层：列出该分区被隐藏的歌单，逐项恢复。
  Future<void> _showHiddenSheet(int group) async {
    await showM3EModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final hidden = _hiddenPlaylistsOf(group);
          final cs = Theme.of(context).colorScheme;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      group == _kGroupCreated ? '隐藏的创建歌单' : '隐藏的收藏歌单',
                      style: SonifyTextStyles.sectionTitle.copyWith(
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                ),
                if (hidden.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(
                      '暂无隐藏的歌单',
                      style: SonifyTextStyles.listItem.copyWith(
                        color: SonifyColors.of(context).textSecondary,
                      ),
                    ),
                  ),
                for (final p in hidden)
                  ListTile(
                    leading: ClipRRect(
                      borderRadius: AppRadius.xsAll,
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: _NetworkCover(
                          // 与横滑轨同口径：解析出的首曲封面优先
                          url:
                              _covers[HiddenPlaylistsCache.playlistKey(p)] ??
                              p.coverUrl,
                          placeholderIcon: Icons.queue_music,
                        ),
                      ),
                    ),
                    title: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${p.songCount} 首'),
                    trailing: TextButton(
                      onPressed: () async {
                        await _restorePlaylist(
                          HiddenPlaylistsCache.playlistKey(p),
                        );
                        // 弹层内容随父页面 _hiddenKeys 一起刷新
                        setSheetState(() {});
                      },
                      child: const Text('恢复'),
                    ),
                  ),
                const Gap(AppSpacing.sm),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _contentScrolled.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    return SonifyTitleScaffold(
      title: '音乐库',
      itemCount: 1,
      // 顶栏右侧：用户头像常驻（trailing 不随滚动淡入淡出，四页统一
      // 形态）。批次 19：移除常驻搜索圆钮，全局搜索由底部导航常驻搜索
      // tab 承载；批次 25：移除 actions 扫描钮（用户：上滑顶栏不需要
      // 扫描按钮）——扫描入口收敛为本地音乐页 trailing 扫描钮 +
      // 扫描状态页。
      trailing: const UserAvatarButton(),
      // 批次 24：内层列表滚动信号驱动栏体渐变带浮现（本页外层骨架
      // 不滚动，offset>0 条件永不满足，与首页不一致）。
      barBackgroundVisible: _contentScrolled,
      itemBuilder: (context, index) {
        final media = MediaQuery.of(context);
        // 固定高度 = 视口 − 状态栏 − 标题区（8+36+8，与占位 item 同口径）
        final height = media.size.height - media.padding.top - 52;
        return ContentScrollSignal(
          signal: _contentScrolled,
          child: SizedBox(
            height: height,
            child: M3EPullToRefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  _buildEntryCards(songCount: library.songs.length),
                  _Section(
                    title: '最近播放',
                    // 整个标题行可点（「显示全部」退化为视觉文案）
                    onHeaderTap: () => _push(context, const PlayHistoryPage()),
                    onShowAll: () => _push(context, const PlayHistoryPage()),
                    child: _history.isEmpty
                        ? const _SectionEmptyText('暂无播放记录')
                        : _RecentPlayList(
                            // 只显示最近 3 条，全部历史进播放历史页
                            songs: _history.take(3).toList(),
                          ),
                  ),
                  _Section(
                    title: '我创建的歌单',
                    trailing: _buildManageButton(_kGroupCreated),
                    managing: _managingGroup == _kGroupCreated,
                    onManageDone: _exitManage,
                    onManageCancel: _exitManage,
                    onHideSelected: _hideSelected,
                    selectedCount: _selectedKeys.length,
                    child: _buildPlaylistSectionBody(
                      _createdPlaylists,
                      emptyText: '暂无创建的歌单',
                      group: _kGroupCreated,
                    ),
                  ),
                  _Section(
                    title: '我收藏的歌单',
                    trailing: _buildManageButton(_kGroupCollected),
                    managing: _managingGroup == _kGroupCollected,
                    onManageDone: _exitManage,
                    onManageCancel: _exitManage,
                    onHideSelected: _hideSelected,
                    selectedCount: _selectedKeys.length,
                    child: _buildPlaylistSectionBody(
                      _collectedPlaylists,
                      emptyText: '暂无收藏的歌单',
                      group: _kGroupCollected,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ==================== 入口卡片区（2×2） ====================

  Widget _buildEntryCards({required int songCount}) {
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
                // 批次18：卡名「我喜欢」→「收藏」（直达「我喜欢」歌单
                // 详情的语义未变，见 _openMyFavorite/_playMyFavorite）。
                title: '收藏',
                // 点开卡片直达「我喜欢」歌单详情（收藏页点击歌单行同款
                // 导航；未登录 / 找不到时分别提示登录 / 兜底收藏页）
                onTap: _openMyFavorite,
                // 卡右侧播放钮：不点开直接播放「我喜欢」
                onPlay: _playMyFavorite,
                playing: _playingMyFavorite,
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

  // ==================== 歌单分区（CoverRail + 隐藏管理） ====================

  /// 歌单分区标题行「管理」入口（小尺寸 IconButton，非管理态时可见）。
  Widget _buildManageButton(int group) {
    return IconButton(
      key: ValueKey(
        'hub-manage-${group == _kGroupCreated ? 'created' : 'collected'}',
      ),
      tooltip: '管理隐藏歌单',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      iconSize: 18,
      icon: const Icon(Icons.more_horiz),
      onPressed: () => _enterManage(group),
    );
  }

  /// 歌单分区内容：有数据走 CoverRail（主页热门歌单同款），空数据显示
  /// 空态文案；有隐藏歌单时下方附「已隐藏 N 个歌单，点击管理」入口。
  Widget _buildPlaylistSectionBody(
    List<KugouPlaylistBrief> playlists, {
    required String emptyText,
    required int group,
  }) {
    final hidden = _hiddenPlaylistsOf(group);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (playlists.isEmpty)
          _SectionEmptyText(emptyText)
        else
          _buildPlaylistRail(playlists, group: group),
        if (hidden.isNotEmpty) _buildHiddenHint(group, hidden.length),
      ],
    );
  }

  /// CoverRail 横滑轨（样式同 discover_page 热门歌单）：150dp 封面 +
  /// squircle 10 + 静态阴影 + 1px 白 α0.10 内描边 + 13sp 标题/副标。
  /// 管理态下点卡切换选中（不跳详情），并叠加选中勾角标。
  Widget _buildPlaylistRail(
    List<KugouPlaylistBrief> playlists, {
    required int group,
  }) {
    final managing = _managingGroup == group;
    return CoverRail(
      itemCount: playlists.length,
      itemBuilder: (context, i) {
        final playlist = playlists[i];
        final card = CoverRailCard(
          cover: _NetworkCover(
            // 无封面歌单：优先用解析出的首曲封面，回退歌单自带封面
            url:
                _covers[HiddenPlaylistsCache.playlistKey(playlist)] ??
                playlist.coverUrl,
            placeholderIcon: Icons.queue_music,
          ),
          title: playlist.name,
          subtitle: '${playlist.songCount} 首',
          onTap: managing
              ? () => _toggleSelect(playlist)
              : () => _openPlaylist(playlist),
        );
        if (!managing) return card;
        return _SelectableCoverCard(
          selected: _selectedKeys.contains(
            HiddenPlaylistsCache.playlistKey(playlist),
          ),
          child: card,
        );
      },
    );
  }

  /// 「已隐藏 N 个歌单，点击管理」一行：点开底部弹层恢复。
  Widget _buildHiddenHint(int group, int count) {
    final sonify = SonifyColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin,
        AppSpacing.sm,
        SonifySpacing.titleMargin,
        0,
      ),
      child: InkWell(
        key: ValueKey(
          'hub-hidden-hint-${group == _kGroupCreated ? 'created' : 'collected'}',
        ),
        onTap: () => _showHiddenSheet(group),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 14,
                color: sonify.textSecondary,
              ),
              const Gap(AppSpacing.xs),
              Text(
                '已隐藏 $count 个歌单，点击管理',
                style: SonifyTextStyles.listItem.copyWith(
                  color: sonify.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== 通用子组件 ====================

/// 分区（纵向列表用）：分区标题 + 可选「显示全部」/「管理」/ 管理态操作
/// 行 + 内容。[onHeaderTap] 非空时整个标题行可点（最近播放 → 播放历史页，
/// 「显示全部」退化为视觉文案）。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.onShowAll,
    this.onHeaderTap,
    this.trailing,
    this.managing = false,
    this.onManageDone,
    this.onManageCancel,
    this.onHideSelected,
    this.selectedCount = 0,
  });

  final String title;
  final Widget child;

  /// 「显示全部」视觉文案的回调（保留旧视觉；整个标题行的点击优先走
  /// [onHeaderTap]，未提供时回退到本回调）。
  final VoidCallback? onShowAll;

  /// 整个标题行点击（最近播放分区专用）。
  final VoidCallback? onHeaderTap;

  /// 标题行右侧额外入口（歌单分区「管理」钮；管理态下不展示）。
  final Widget? trailing;

  // —— 多选管理态（歌单分区专用）——
  final bool managing;
  final VoidCallback? onManageDone;
  final VoidCallback? onManageCancel;
  final VoidCallback? onHideSelected;
  final int selectedCount;

  @override
  Widget build(BuildContext context) {
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
          child: managing
              ? _buildManagingHeader(context)
              : _buildNormalHeader(context),
        ),
        // 横滑轨道首尾出血：左缘 18dp、右缘 18dp（CoverRail 网格边距）
        child,
      ],
    );
  }

  Widget _buildNormalHeader(BuildContext context) {
    final sonify = SonifyColors.of(context);
    final row = Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: SonifyTextStyles.sectionTitle.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        if (trailing != null) trailing!,
        if (onShowAll != null)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.xs),
            child: Text(
              '显示全部',
              style: SonifyTextStyles.listItem.copyWith(color: sonify.primary),
            ),
          ),
      ],
    );
    if (onHeaderTap == null && onShowAll == null) return row;
    return InkWell(
      onTap: onHeaderTap ?? onShowAll,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: row,
    );
  }

  /// 管理态标题行：「完成 / 取消 / 隐藏所选(N)」（N=0 时不可点）。
  Widget _buildManagingHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textStyle = SonifyTextStyles.listItem;
    return Row(
      children: [
        TextButton(
          onPressed: onManageDone,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text('完成', style: textStyle.copyWith(color: cs.primary)),
        ),
        const Spacer(),
        TextButton(
          onPressed: onManageCancel,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            '取消',
            style: textStyle.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        const Gap(AppSpacing.xs),
        FilledButton.tonal(
          onPressed: selectedCount > 0 ? onHideSelected : null,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text('隐藏所选($selectedCount)', style: textStyle),
        ),
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

/// 入口卡片（2×2 网格单格）：高对比卡底 surfaceContainerHighest α0.92 +
/// 1px 白 α0.10 内描边 + primary 图标 + 标题/副标题。
///
/// [onPlay] 非空时卡右侧渲染圆形 tonal 播放钮（内层 InkWell 在手势竞技中
/// 胜出，不会误触发卡的 [onTap]）；[playing] 为 true 时钮内显示进度环。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.onPlay,
    this.playing = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// 可选「直接播放」钮（仅收藏卡）：卡右侧，独立 onPressed。
  final VoidCallback? onPlay;
  final bool playing;

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
          // 高对比卡底 + 1px 内描边（亮暗主题均不出戏；图标/文字色不动）
          decoration: ShapeDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.92),
            shape: SmoothRectangleBorder(
              borderRadius: BorderRadius.circular(SonifyRadius.card),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
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
                  Icon(icon, size: _HubDimens.entryCardIcon, color: cs.primary),
                  const Gap(AppSpacing.md),
                  Expanded(
                    child: _TileText(title: title, subtitle: subtitle),
                  ),
                  if (onPlay != null) ...[
                    const Gap(AppSpacing.sm),
                    _buildPlayButton(cs),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 卡右侧播放钮：36dp 圆形 secondaryContainer tonal 底 + 20dp 图标；
  /// 加载中换 18dp 进度环并禁用点击。
  Widget _buildPlayButton(ColorScheme cs) {
    return SizedBox(
      width: _HubDimens.playButton,
      height: _HubDimens.playButton,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: cs.secondaryContainer,
          shape: const CircleBorder(),
        ),
        child: InkWell(
          key: const ValueKey('hub-play-my-favorite'),
          customBorder: const CircleBorder(),
          onTap: playing ? null : onPlay,
          child: Center(
            child: playing
                ? SizedBox(
                    width: _HubDimens.playButtonSpinner,
                    height: _HubDimens.playButtonSpinner,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.onSecondaryContainer,
                    ),
                  )
                : Icon(
                    Icons.play_arrow_rounded,
                    size: _HubDimens.playButtonIcon,
                    color: cs.onSecondaryContainer,
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

/// 管理态封面卡包装：选中时置灰 + 右上角圆形勾角标（角标 IgnorePointer，
/// 点击穿透给 CoverRailCard 的 onTap 切换选中）。
class _SelectableCoverCard extends StatelessWidget {
  const _SelectableCoverCard({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Opacity(opacity: selected ? 0.55 : 1, child: child),
        Positioned(
          top: 6,
          right: 6,
          child: IgnorePointer(
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? cs.primary
                    : cs.surfaceContainerHighest.withValues(alpha: 0.9),
                border: Border.all(
                  color: selected ? cs.primary : cs.outline,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? Icon(Icons.check, size: 14, color: cs.onPrimary)
                  : null,
            ),
          ),
        ),
      ],
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

/// 最近播放 Top 3 列表（行高 56dp：封面 44×44 圆角 8 + 标题/副行）。
class _RecentPlayList extends StatelessWidget {
  const _RecentPlayList({required this.songs});

  final List<Song> songs;

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
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
