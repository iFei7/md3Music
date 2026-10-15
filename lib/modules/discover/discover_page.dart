import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:m3e_core/m3e_core.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../widgets/common/cover_rail.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/song_list_item.dart';
import 'home_discover_refill.dart';
import '../album/album_detail_page.dart';
import '../personal_fm/personal_fm_page.dart';
import '../playlist/playlist_page.dart';
import '../recognition/song_recognition_page.dart';
import '../search/explore_sections.dart' show PlaylistBrowsePage, NewAlbumBrowsePage, RankDetailPage;
import '../search/search_page.dart';

/// 首页 / Discover（UI 重设计批次 1，方案 §1）。
///
/// 结构（方案 §1.2 线框）：
/// - [SonifyTitleScaffold] 大标题「发现」折叠顶栏（列表首 item，滚动溶解，
///   没入后 18.5sp 小标题浮现，180ms EaseOutCubic 吸附）；
/// - 顶栏右上**固定用户头像**（常驻不折叠，点击进 /user）；
/// - 折叠后头像左侧浮现搜索/识曲两枚玻璃圆钮（点击行为同搜索框）；
/// - 列表：胶囊搜索框（内右侧识曲按钮）→ 快捷入口行（FM/识曲）→ 每日推荐
///   → 编辑精选/主题歌单/热门歌单/新碟上架/排行榜 横滑 Rail（[CoverRail]）
///   → 刷歌推荐 → Dock 避让。
///
/// 既有行为保持：下拉刷新（Md3PullToRefresh）、渐进加载（Selector 分区补出）、
/// 每日推荐/刷歌推荐分区折叠持久化、刷歌补货器（[HomeDiscoverRefill]）。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  static const String _kDiscoverLastDateKey = 'discover_last_date';

  // 每日推荐区块的折叠状态（true=折叠）。SharedPreferences 存"是否折叠"。
  static const String _kCollapsedDaily = 'discover_collapsed_daily';

  // 刷歌推荐区块的折叠状态，键名与每日推荐同一套约定（前缀 + 分区）。
  static const String _kCollapsedHomeDiscover = 'discover_collapsed_home_discover';

  bool _isLoading = true;
  String? _error;

  bool _isDailyExpanded = true;
  bool _isHomeDiscoverExpanded = true;

  /// 横滑 Rail 单侧最大卡片数：上限避免一次构建过多封面卡
  /// （provider 列表可能有一整页 30 条，首屏 10 张足够横滑）。
  static const int _kRailMaxItems = 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initIfNeeded();
      _loadCollapseStates();
      // 横滑分区数据补拉（TTL 内静默跳过，与搜索空白态共享同一份缓存）
      _ensureRailData();
    });
  }

  /// 从 SharedPreferences 恢复每日推荐 section 的折叠状态
  Future<void> _loadCollapseStates() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isDailyExpanded = !(prefs.getBool(_kCollapsedDaily) ?? false);
      _isHomeDiscoverExpanded = !(prefs.getBool(_kCollapsedHomeDiscover) ?? false);
    });
  }

  /// 切换 section 展开/折叠并持久化
  Future<void> _toggleCollapse({
    required String prefKey,
    required bool currentlyExpanded,
    required ValueChanged<bool> apply,
  }) async {
    final next = !currentlyExpanded;
    setState(() => apply(next));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, !next);
  }

  /// 每天只自动加载一次：内存有数据且是同一天则跳过，否则拉取
  Future<void> _initIfNeeded() async {
    if (!mounted) return;
    final kugou = context.read<KugouProvider>();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lastDate = prefs.getString(_kDiscoverLastDateKey);
    final today = _todayString();
    if (kugou.hasLoadedDiscoverData && lastDate == today) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    if (lastDate != null && lastDate != today) {
      // 跨天：重置标志，让 _loadAllData 重新拉
      kugou.resetDiscoverLoadedFlag();
    }

    // 自动重试：首次启动时 Node.js 服务器可能尚未完全就绪
    int retryCount = 0;
    while (retryCount < 3) {
      await _loadAllData();
      if (!mounted) return;

      // 检查是否真的加载到了数据（发现页只剩每日推荐）
      if (kugou.recommendSongs.isNotEmpty) {
        break; // 有数据了，退出重试
      }

      retryCount++;
      if (retryCount < 3 && mounted) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  String _todayString() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// 是否有任一发现分区数据就绪（渐进加载用）：任一就绪即退出整页转圈。
  /// 刷歌推荐（首页 /home/discover）也算一块：它进页面就能拿到首屏 4 首，
  /// 没有它的话只有每日推荐慢半拍时整个刷歌区会先空着。
  bool get _hasAnySectionData {
    final kugou = context.read<KugouProvider>();
    return kugou.recommendSongs.isNotEmpty ||
        kugou.homeDiscoverSongs.isNotEmpty;
  }

  /// 横滑分区数据补拉：编辑精选/主题歌单/热门歌单/排行榜/新碟上架。
  /// 全部命中 provider 5 分钟 TTL 缓存即静默跳过，与搜索空白态
  /// （MusicExploreSections）共享同一份 [KugouProvider] 数据。
  void _ensureRailData({bool forceRefresh = false}) {
    final kugou = context.read<KugouProvider>();
    unawaited(kugou.getIpHome(forceRefresh: forceRefresh));
    unawaited(kugou.getThemePlaylist(forceRefresh: forceRefresh));
    unawaited(kugou.getPlaylist(forceRefresh: forceRefresh));
    unawaited(kugou.getRankList(forceRefresh: forceRefresh));
    unawaited(kugou.getTopAlbum(forceRefresh: forceRefresh));
  }

  Future<void> _loadAllData() async {
    if (!mounted) return; // 页面已销毁则放弃，避免访问 context 触发 null check 崩溃
    final kugou = context.read<KugouProvider>();
    final hasExistingData = kugou.hasLoadedDiscoverData;
    // 已有数据时直接展示，后台静默刷新
    if (!hasExistingData) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    // 下拉刷新触发全部分区重拉（横滑分区走 provider TTL，forceRefresh 时绕过）
    _ensureRailData(forceRefresh: hasExistingData);
    try {
      // 渐进加载：请求并行发起，每个分区完成后立即刷新一次。
      final reqs = <Future<void>>[
        kugou.getRecommendDaily(forceRefresh: hasExistingData),
        // 刷歌推荐下拉只 forceRefresh、**不重置游标**：forceRefresh 在
        // getHomeDiscover 里的含义仅仅是绕过 5 分钟 TTL，游标（已消费条数）和
        // seen（已消费 hash，持久化在 HomeDiscoverProgressStore）都原样保留。
        // 刷歌的意义就是"每次点开/下拉都是没听过的"，重置游标等于把刚刷过的那
        // 几首原样端回来，用户会反复看见同一批歌，那还不如不放这个入口。
        kugou.getHomeDiscover(forceRefresh: hasExistingData),
      ];
      for (final f in reqs) {
        unawaited(f.then((_) {
          if (mounted) setState(() {});
        }).catchError((Object _) {
          // 单个分区失败不阻塞其它分区；错误由最终判定/分区自身兜底
          if (mounted) setState(() {});
        }));
      }
      await Future.wait(reqs);

      // 只有确实加载到数据时才标记为已加载
      final hasAnyData = kugou.recommendSongs.isNotEmpty;
      if (!mounted) return;
      if (hasAnyData) {
        kugou.markDiscoverLoaded();
        // 任何一次加载成功都把日期标记为今天
        final prefs = await SharedPreferences.getInstance();
        if (!mounted) return;
        await prefs.setString(_kDiscoverLastDateKey, _todayString());
      }
    } catch (e) {
      if (!mounted) return;
      _error = e.toString();
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Md3PullToRefresh(
      onRefresh: _loadAllData,
      // 页面内嵌横向滑 Rail：收窄到「depth-0 + 纵向」通知，防止横滑列表
      // 左缘 overscroll 被误判为下拉刷新（见 [Md3PullToRefresh.notificationPredicate]）。
      notificationPredicate: (n) =>
          n.depth == 0 && n.metrics.axis == Axis.vertical,
      // 渐进加载：任一分区数据就绪即退出整页转圈，先显示已获取的分区；
      // 未就绪分区由各自 Selector 在数据到达时自动补出（空数据返回占位）。
      child: _isLoading && !_hasAnySectionData
          ? Scaffold(body: const Center(child: M3ELoadingIndicator()))
          : _error != null && !_hasAnySectionData
          ? Scaffold(body: _buildError(colorScheme))
          : SonifyTitleScaffold(
              title: '发现',
              // 顶栏右侧固定用户头像（常驻，不随折叠）
              trailing: _buildUserAvatar(),
              // 折叠后在头像左侧浮现搜索/识曲圆钮
              actions: _buildCollapsedBarActions(),
              itemCount: _kSectionCount,
              itemBuilder: _buildListItem,
            ),
    );
  }

  /// 列表 item 布局（方案 §1.2 线框顺序）。
  static const int _kSectionCount = 10;

  Widget _buildListItem(BuildContext context, int index) {
    switch (index) {
      case 0:
        return _buildSearchFieldItem();
      case 1:
        return _buildQuickAccessRow();
      case 2:
        return _buildDailySection();
      case 3:
        return _buildIpHomeSection();
      case 4:
        return _buildThemeSection();
      case 5:
        return _buildPlaylistSection();
      case 6:
        return _buildNewAlbumSection();
      case 7:
        return _buildRankSection();
      case 8:
        return _buildHomeDiscoverSection();
      case 9:
        // Dock 避让：消费注入的底部 padding（手势条 + Dock 高度），
        // 让最后一个分区停在悬浮 Dock 上方、可点击。
        return SizedBox(height: MediaQuery.paddingOf(context).bottom);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildError(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const Gap(AppSpacing.md),
            Text(
              '加载失败',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const Gap(AppSpacing.sm),
            Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const Gap(AppSpacing.lg),
            FilledButton.tonal(
              onPressed: _loadAllData,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SearchPage()),
    );
  }

  /// 识曲入口：[SongRecognitionPage] 为独立路由页（非 tab 项），
  /// 复用快捷入口行的 MaterialPageRoute 跳转方式。
  void _openRecognition() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SongRecognitionPage()),
    );
  }

  /// 胶囊搜索框（列表首 item，随内容自然滚动，不吸顶）：
  /// sonify 玻璃胶囊，左侧搜索图标 + 占位文案，框内右侧识曲按钮。
  /// 整体可点 → 搜索页；识曲按钮单独响应（内层 GestureDetector 在手势
  /// 竞技场中优先胜出）。
  Widget _buildSearchFieldItem() {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin, 4, SonifySpacing.titleMargin, 0,
      ),
      child: GestureDetector(
        onTap: _openSearch,
        behavior: HitTestBehavior.opaque,
        child: LiquidGlassSurface(
          shape: GlassShape.pill,
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                const Gap(AppSpacing.md),
                Icon(Icons.search, size: 20, color: cs.onSurfaceVariant),
                const Gap(AppSpacing.sm),
                Expanded(
                  child: Text(
                    '搜索歌曲、歌手',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SonifyTextStyles.listItem.copyWith(
                      color: sonify.textSecondary,
                    ),
                  ),
                ),
                // 框内右侧：听歌识曲按钮
                GestureDetector(
                  onTap: _openRecognition,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12,
                    ),
                    child: Icon(Icons.mic_none, size: 20, color: cs.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 顶栏固定用户头像（36dp）：常驻不参与折叠，点击进 /user
  /// （未登录时用户中心自身展示登录引导）。
  Widget _buildUserAvatar() {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => Navigator.of(context).pushNamed('/user'),
      behavior: HitTestBehavior.opaque,
      child: Selector<KugouProvider, String?>(
        selector: (_, kugou) => kugou.userInfo?.avatar,
        builder: (context, avatar, _) => CircleAvatar(
          radius: 18,
          backgroundColor: cs.surfaceContainerHighest,
          backgroundImage: (avatar != null && avatar.isNotEmpty)
              ? CachedNetworkImageProvider(avatar)
              : null,
          child: (avatar == null || avatar.isEmpty)
              ? Icon(Icons.person, size: 20, color: cs.onSurfaceVariant)
              : null,
        ),
      ),
    );
  }

  /// 顶栏玻璃圆钮：42dp 圆形液态玻璃（sonify Title.kt:849-873 材质），
  /// 图标 20dp。用于折叠后的顶栏搜索/识曲按钮。
  Widget _buildGlassCircleButton(IconData icon, VoidCallback onTap) {
    return LiquidGlassSurface(
      shape: GlassShape.circle,
      child: SizedBox(
        width: 42,
        height: 42,
        child: IconButton(
          // 顶满玻璃圆钮（默认 48dp 会溢出 42dp 容器）
          constraints: const BoxConstraints.tightFor(width: 42, height: 42),
          padding: EdgeInsets.zero,
          icon: Icon(icon, size: 20),
          onPressed: onTap,
        ),
      ),
    );
  }

  /// 折叠后顶栏动作按钮：头像左侧的搜索圆钮 + 识曲圆钮，
  /// 点击行为与列表搜索框一致。
  List<Widget> _buildCollapsedBarActions() {
    return [
      _buildGlassCircleButton(Icons.search, _openSearch),
      const SizedBox(width: 10),
      _buildGlassCircleButton(Icons.mic_none, _openRecognition),
    ];
  }

  /// 快捷入口行：FM / 识曲，56dp squircle 9dp 卡底色块（方案 §1.3）。
  ///
  /// 线框中的「场景」「榜单」两块未落地：场景点击链路（场景音乐列表页）与
  /// 榜单浏览页在数据侧均未就绪（见批次回报），避免放死入口。
  Widget _buildQuickAccessRow() {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    Widget block(IconData icon, String label, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SmoothClipRRect(
          borderRadius: BorderRadius.circular(SonifyRadius.card),
          child: Container(
            width: 64,
            height: 56,
            color: sonify.surfaceCard,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 24, color: cs.onSurface),
                const Gap(3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: sonify.textSecondary,
                  ),
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin, AppSpacing.sm, SonifySpacing.titleMargin, 0,
      ),
      child: Row(
        children: [
          block(
            Icons.radio,
            '私人 FM',
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PersonalFmPage()),
            ),
          ),
          const Gap(AppSpacing.sm),
          block(
            Icons.mic_none,
            '识曲',
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SongRecognitionPage()),
            ),
          ),
        ],
      ),
    );
  }

  /// 分区标题行：18sp Bold 标题 + 可选「更多」（13sp 次级灰 + 24dp primary
  /// 右箭头，方案 §1.3）。
  Widget _sectionHeader(String title, {VoidCallback? onMore}) {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin, AppSpacing.lg, SonifySpacing.titleMargin, AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: SonifyTextStyles.sectionTitle.copyWith(color: cs.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onMore != null)
            GestureDetector(
              onTap: onMore,
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '更多',
                    style: SonifyTextStyles.listItem.copyWith(
                      color: sonify.textSecondary,
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 24, color: cs.primary),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _railCoverImage(String? url) {
    final cs = Theme.of(context).colorScheme;
    if (url == null || url.isEmpty) {
      return Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      memCacheWidth: 390,
      memCacheHeight: 390,
      fit: BoxFit.cover,
      placeholder: (_, _) => Container(color: cs.surfaceContainerHighest),
      errorWidget: (_, _, _) => Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// 编辑精选：消费 [KugouProvider.ipHomeData]（/top/ip 原始 JSON，无解析模型）。
  ///
  /// 容错解析：尝试 data.list/info 等常见键位提取「名称 + 封面」条目，
  /// 提取不到（结构不符）时分区整体隐藏，不影响其它分区。
  Widget _buildIpHomeSection() {
    return Selector<KugouProvider, Map<String, dynamic>?>(
      selector: (_, kugou) => kugou.ipHomeData,
      builder: (context, data, _) {
        final items = _parseIpHomeItems(data);
        if (items.isEmpty) return const SizedBox.shrink();
        final count = items.length.clamp(0, _kRailMaxItems);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader('编辑精选'),
            CoverRail(
              itemCount: count,
              itemBuilder: (context, i) => CoverRailCard(
                cover: _railCoverImage(items[i].cover),
                title: items[i].name,
                // /ip 详情页尚未建（getIpData 无消费页），暂为展示态
              ),
            ),
          ],
        );
      },
    );
  }

  List<({String name, String? cover})> _parseIpHomeItems(
    Map<String, dynamic>? raw,
  ) {
    if (raw == null) return const [];
    dynamic node = raw['data'] ?? raw;
    List? list;
    if (node is Map) {
      for (final key in const ['list', 'info', 'items', 'blocks', 'data']) {
        final v = node[key];
        if (v is List && v.isNotEmpty) {
          list = v;
          break;
        }
      }
    } else if (node is List) {
      list = node;
    }
    if (list == null) return const [];
    final out = <({String name, String? cover})>[];
    for (final e in list) {
      if (e is! Map) continue;
      final name =
          (e['name'] ?? e['title'] ?? e['ipName'])?.toString() ?? '';
      final cover =
          (e['coverUrl'] ?? e['cover'] ?? e['imgUrl'] ?? e['img'] ??
                  e['screenshot'] ?? e['pic'])
              ?.toString();
      if (name.isEmpty || cover == null || cover.isEmpty) continue;
      out.add((name: name, cover: cover));
    }
    return out;
  }

  /// 主题歌单：横滑 Rail（自搜索空白态探索分区迁回，共享 provider 缓存）。
  /// 主题卡暂无详情页（现状展示态，与 MusicExploreSections 一致）。
  Widget _buildThemeSection() {
    return Selector<KugouProvider, List<KugouThemeInfo>>(
      selector: (_, kugou) => kugou.themePlaylistData,
      builder: (context, themes, _) {
        if (themes.isEmpty) return const SizedBox.shrink();
        final count = themes.length.clamp(0, _kRailMaxItems);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader('主题歌单'),
            CoverRail(
              itemCount: count,
              itemBuilder: (context, i) => CoverRailCard(
                cover: _railCoverImage(themes[i].coverUrl),
                title: themes[i].name,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 热门歌单：横滑 Rail，点击进歌单详情，「更多」进浏览页。
  Widget _buildPlaylistSection() {
    return Selector<KugouProvider, List<KugouPlaylistBrief>>(
      selector: (_, kugou) => kugou.playlistList,
      builder: (context, plist, _) {
        if (plist.isEmpty) return const SizedBox.shrink();
        final count = plist.length.clamp(0, _kRailMaxItems);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(
              '热门歌单',
              onMore: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlaylistBrowsePage()),
              ),
            ),
            CoverRail(
              itemCount: count,
              itemBuilder: (context, i) => CoverRailCard(
                cover: _railCoverImage(plist[i].coverUrl),
                title: plist[i].name,
                subtitle: plist[i].songCount > 0
                    ? '${plist[i].songCount}首'
                    : null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PlaylistPage(playlist: plist[i].toPlaylist()),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 新碟上架：横滑 Rail，点击进专辑详情，「更多」进浏览页。
  Widget _buildNewAlbumSection() {
    return Selector<KugouProvider, List<KugouAlbumBrief>>(
      selector: (_, kugou) => kugou.topAlbums,
      builder: (context, albums, _) {
        if (albums.isEmpty) return const SizedBox.shrink();
        final count = albums.length.clamp(0, _kRailMaxItems);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(
              '新碟上架',
              onMore: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewAlbumBrowsePage()),
              ),
            ),
            CoverRail(
              itemCount: count,
              itemBuilder: (context, i) => CoverRailCard(
                cover: _railCoverImage(albums[i].toAlbum().artworkUri),
                title: albums[i].name,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        AlbumDetailPage(album: albums[i].toAlbum()),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 排行榜：横滑 Rail（提级自搜索空白态网格），点击进榜单歌曲页。
  Widget _buildRankSection() {
    return Selector<KugouProvider, KugouRankList?>(
      selector: (_, kugou) => kugou.rankList,
      builder: (context, rankList, _) {
        final ranks = rankList?.ranks ?? const <KugouRank>[];
        if (ranks.isEmpty) return const SizedBox.shrink();
        final count = ranks.length.clamp(0, _kRailMaxItems);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader('排行榜'),
            CoverRail(
              itemCount: count,
              itemBuilder: (context, i) => CoverRailCard(
                cover: _railCoverImage(ranks[i].toAlbum().artworkUri),
                title: ranks[i].name,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RankDetailPage(
                      rankId: ranks[i].id,
                      rankName: ranks[i].name,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 每日推荐：竖排前四首。
  ///
  /// 复用 [SongListItem]，拿到「正在播」高亮、收藏、更多菜单（含 MV）。
  /// 全部 30 首仍在标题右侧的 `›` 里。折叠状态持久化（既有行为）。
  Widget _buildDailySection() {
    return Selector<KugouProvider, List<KugouSongDetail>>(
      selector: (_, kugou) => kugou.recommendSongs,
      builder: (context, songs, _) {
        if (songs.isEmpty) return const SizedBox.shrink();
        final all = songs.map((e) => e.toSong()).toList();
        final top = all.take(4).toList();
        return _CollapsibleSection(
          title: '每日推荐',
          isExpanded: _isDailyExpanded,
          onToggle: () => _toggleCollapse(
            prefKey: _kCollapsedDaily,
            currentlyExpanded: _isDailyExpanded,
            apply: (v) => _isDailyExpanded = v,
          ),
          trailing: IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const _DailyRecommendDetailPage(),
                ),
              );
            },
            icon: const Icon(Icons.chevron_right),
          ),
          child: Padding(
            // SongListItem 自带 horizontal 10 的内边距，补 6 凑成 16dp 页边距。
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              children: [
                for (var i = 0; i < top.length; i++)
                  SongListItem(
                    song: top[i],
                    showDuration: false,
                    // 每日推荐：右侧仅收藏按钮（见改版计划二）。
                    trailingActions: SongTrailingActions.favoriteOnly,
                    onTap: () => context
                        .read<PlayerProvider>()
                        .playOnlinePlaylist(all, i),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 刷歌推荐：竖排前四首，形态与 [_buildDailySection] 完全一致。
  ///
  /// 刻意复用 [SongListItem]：与每日推荐是同一类内容（"挑几首听"），
  /// 复用顺带拿到「正在播」高亮与收藏按钮。折叠状态持久化（既有行为）。
  Widget _buildHomeDiscoverSection() {
    return Selector<KugouProvider, List<KugouSongDetail>>(
      selector: (_, kugou) => kugou.homeDiscoverSongs,
      builder: (context, details, _) {
        if (details.isEmpty) return const SizedBox.shrink();
        final all = details.map((e) => e.toSong()).toList();
        final top = all.take(4).toList();
        return _CollapsibleSection(
          title: '刷歌推荐',
          isExpanded: _isHomeDiscoverExpanded,
          onToggle: () => _toggleCollapse(
            prefKey: _kCollapsedHomeDiscover,
            currentlyExpanded: _isHomeDiscoverExpanded,
            apply: (v) => _isHomeDiscoverExpanded = v,
          ),
          trailing: IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const _HomeDiscoverDetailPage(),
                ),
              );
            },
            icon: const Icon(Icons.chevron_right),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              children: [
                for (var i = 0; i < top.length; i++)
                  SongListItem(
                    song: top[i],
                    showDuration: false,
                    // 与每日推荐一致：右侧仅收藏按钮，时长对"刷"没有参考价值。
                    trailingActions: SongTrailingActions.favoriteOnly,
                    onTap: () => _play(i),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 点一首歌就起播，并把 [HomeDiscoverRefill] 装上，让这条队列在播完之后还能接着刷。
  ///
  /// 顺序和"必须补一批"都是踩出来的：
  /// 1. **先起播再 arm**。补货器是靠识别"当前播放队列是不是刷歌来的"来决定
  ///    留不留场的，而队列是在 [PlayerProvider.playOnlinePlaylist] 里落地的。
  ///    顺序反了的话 arm 那一刻 currentSong 还是上一首，它会把这当成别人的队列
  ///    直接退场，之后这条队列永远不会被补货。
  /// 2. **必须立刻 append 一批**。PlayerProvider 一次只把当前这一首灌进
  ///    audio_service，队列末尾没有任何预加载；不补的话播到队尾就停，"刷歌"
  ///    退化成"听四首就完事"。
  /// 3. **播放源取 provider 的权威列表快照**（homeDiscoverSongsAsSongs），不在本地
  ///    存副本：副本会和补货器追加进 provider 的新歌脱节，队列里就没有后来的歌。
  Future<void> _play(int index) async {
    final kugou = context.read<KugouProvider>();
    final player = context.read<PlayerProvider>();
    final songs = kugou.homeDiscoverSongsAsSongs;
    if (index < 0 || index >= songs.length) return;
    await player.playOnlinePlaylist(songs, index);
    // 装填补货器：同一条队列已在补货会复用现有实例
    final refill = HomeDiscoverRefill.arm(kugou, player);
    if (refill == null) return;
    // 立即补一批
    await refill.append();
  }
}

class _DailyRecommendDetailPage extends StatefulWidget {
  const _DailyRecommendDetailPage();

  @override
  State<_DailyRecommendDetailPage> createState() =>
      _DailyRecommendDetailPageState();
}

class _DailyRecommendDetailPageState extends State<_DailyRecommendDetailPage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getRecommendDaily();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('每日推荐')),
      body: _isLoading
        ? const Center(child: M3ELoadingIndicator())
        : Selector<KugouProvider, List<KugouSongDetail>>(
            selector: (_, kugou) => kugou.recommendSongs,
            builder: (context, recommendSongs, _) {
              final songs = recommendSongs.map((e) => e.toSong()).toList();
              if (songs.isEmpty) return const Center(child: Text('暂无数据'));
              return Column(
                children: [
                  // 播放全部：把当日的 30 首当一张歌单从头连播。
                  // 形态与专辑/歌单/听书详情页的主行动按钮一致
                  // （FilledButton.icon + play_arrow）。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => context
                            .read<PlayerProvider>()
                            .playOnlinePlaylist(songs, 0),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('播放全部'),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.sm,
                        AppSpacing.lg,
                        AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                      ),
                      itemCount: songs.length,
                      itemBuilder: (context, index) {
                        final song = songs[index];
                        return SongListItem(
                          song: song,
                          // 每日推荐：右侧仅收藏按钮（见改版计划二）。
                          trailingActions: SongTrailingActions.favoriteOnly,
                          onTap: () {
                            context.read<PlayerProvider>().playOnlinePlaylist(
                              songs,
                              index,
                            );
                          },
                          onMoreTap: () {},
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }
}

/// 刷歌推荐详情页：完整的一批 + 上滑增量 + 起播补货。
///
/// 骨架照 [_DailyRecommendDetailPage]（Scaffold + AppBar + 「播放全部」+
/// ListView.builder），差别只有两处：
/// - 列表会随滚动变长：底部哨兵行到距底 200px 就翻一批
///   （[KugouProvider.fetchMoreHomeDiscover]），翻到取不动为止；
/// - 点任意一首都会把 [HomeDiscoverRefill] 装上，播完自动接下一批。
class _HomeDiscoverDetailPage extends StatefulWidget {
  const _HomeDiscoverDetailPage();

  @override
  State<_HomeDiscoverDetailPage> createState() =>
      _HomeDiscoverDetailPageState();
}

class _HomeDiscoverDetailPageState extends State<_HomeDiscoverDetailPage> {
  /// 一批的条数，对齐 [KugouProvider.homeDiscoverBatchSize]。
  /// 传小了的代价是 provider 判定"这一趟没凑够 minCount"就再多试几轮请求，
  /// 白白多发几次网络。
  static const int _pageSize = 30;

  bool _isLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 与 provider 里的 5 分钟 TTL 对齐：冷启动时首页可能刚取过首屏 4 首，
      // 这里不该再要一次。
      await context.read<KugouProvider>().getHomeDiscover();
      if (!mounted) return;
      setState(() => _isLoading = false);
      await _fillUntilScrollable();
    });
  }

  @override
  void dispose() {
    // 先摘监听再 dispose：controller 在 dispose 之后任何一次 scroll 通知都会
    // 反过来摸已销毁的 controller（同类列表页曾漏了这一步）。
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 距底 200px 触发翻页：等真正到底再翻会先看到一屏空白（footer 才刚出现）。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  /// 列表装不满一屏时主动补批，直到它真的能滚。
  ///
  /// 这是"只有 4 首时怎么上拉都没反应"的根因：[_onScroll] 挂在 ScrollController
  /// 上，只有**真的发生滚动**才会回调。首屏只有 4 首（`pagesize` 的文档默认值），
  /// 远矮于一屏，`maxScrollExtent` 为 0 —— 根本滚不动，于是回调不触发，
  /// [_loadMore] 永远不被调用。条件本身（`0 >= 0 - 200`）是成立的，只是没人
  /// 去算它。这也是"播放补货正常、滑动失灵"的原因：补货由
  /// [HomeDiscoverRefill] 监听 PlayerProvider 驱动，与滚动毫无关系。
  ///
  /// 所以不能把"取下一批"只挂在滚动上——首屏那一段没有任何滚动事件可听。
  static const int _maxAutoFillRounds = 4;

  /// 防止 [_loadMoreBatch] 末尾再调本方法时递归：[_fillUntilScrollable] 内部
  /// 会调 [_loadMore]，后者又回调进来，没有这道闸就会变成无限自我调用。
  bool _autoFilling = false;

  Future<void> _fillUntilScrollable() async {
    if (_autoFilling) return;
    _autoFilling = true;
    try {
      for (var round = 0; round < _maxAutoFillRounds; round++) {
        if (!mounted || !_hasMore) return;
        // 等新条目布局完再量，否则量到的还是补货前的 maxScrollExtent。
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        // maxScrollExtent > 0 表示已经能滚了，交给用户上拉即可。
        if (_scrollController.hasClients &&
            _scrollController.position.maxScrollExtent > 0) {
          return;
        }
        await _loadMore();
      }
    } finally {
      _autoFilling = false;
    }
  }

  /// 上拉翻一批。复位放在 finally：翻页失败（网络/上游返回 null）时若不复位，
  /// 指示器会一直转、之后再怎么滚都不会加载，等于把整页的增量永久卡死。
  /// 翻转 [_loadingMore] 必须走 setState：footer 的转圈分支渲染依赖列表重建，
  /// 只改字段不重建的话指示器从出现到消失都不会画出来。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      await _loadMoreBatch();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadMoreBatch() async {
    final kugou = context.read<KugouProvider>();
    final fresh = await kugou.fetchMoreHomeDiscover(minCount: _pageSize);
    if (!mounted) return;
    // 列表本身由 provider 追加（fetchMoreHomeDiscover 内部已经并进
    // homeDiscoverSongs 并 notifyListeners），这里只判"还有没有"。
    setState(() {
      _hasMore = fresh.isNotEmpty;
    });
    // 补完一批后再确认一次能否滚动：大屏/折叠屏展开态下，一屏装得下 30 首，
    // 光靠首屏那次自动补货还是滚不动。
    await _fillUntilScrollable();
  }

  /// 点歌起播 + 装填补货器。
  ///
  /// 三点顺序的原因与 [_DiscoverPageState._play] 完全一致（那是同一套起播逻辑的
  /// 卡片版本，这里只重复结论）：
  /// 1. **先 [PlayerProvider.playOnlinePlaylist] 再 arm**：队列要先落地，补货器才
  ///    认得出这条队列是刷歌来的；反了的话 arm 那一刻 currentSong 还是上一首，会被
  ///    当成「别人的队列」直接退场。
  /// 2. **必须立即 append 一批**：PlayerProvider 一次只把一首歌灌进 audio_service，
  ///    队尾没有预加载；不补就是播到头就停。
  /// 3. **不在本 State 存 List&lt;Song&gt; 副本**：本页展示的是
  ///    [KugouProvider.homeDiscoverSongs]（Selector 监听），补货器往里追加后本页
  ///    会自然变长。存一份副本的话，副本既不会变长，也会和补货器判断队列归属时
  ///    依据的 provider 列表对不上。
  Future<void> _play(int index) async {
    final kugou = context.read<KugouProvider>();
    final player = context.read<PlayerProvider>();
    final songs = kugou.homeDiscoverSongsAsSongs;
    if (index < 0 || index >= songs.length) return;
    await player.playOnlinePlaylist(songs, index);
    // 装填补货器：同一条队列已在补货会复用现有实例
    final refill = HomeDiscoverRefill.arm(kugou, player);
    if (refill == null) return;
    // 立即补一批
    await refill.append();
  }

  /// 列表尾部哨兵行：加载中转圈 / 还有更多时提示上滑 / 取完了说一声。
  /// 三态都留着是因为"还在转"和"到底了"不写清楚的话，用户会以为页面卡住。
  Widget _buildListFooter(BuildContext context) {
    if (_loadingMore) {
      // 与下拉刷新同款：M3EPullToRefreshIndicator 默认用的 M3EContainedLoadingIndicator，
      // 48×48 药丸容器 + shapes 动画，视觉与发现页/刷刷页的下拉刷新一致。
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: M3EContainedLoadingIndicator(
            width: 48,
            height: 48,
          ),
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          _hasMore ? '继续上滑加载更多' : '没有更多了',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('刷歌推荐')),
      body: _isLoading
        ? const Center(child: M3ELoadingIndicator())
        : Selector<KugouProvider, List<KugouSongDetail>>(
            selector: (_, kugou) => kugou.homeDiscoverSongs,
            builder: (context, details, _) {
              final songs = details.map((e) => e.toSong()).toList();
              if (songs.isEmpty) return const Center(child: Text('暂无数据'));
              return Column(
                children: [
                  // 播放全部：与每日推荐详情页同形态（FilledButton.icon +
                  // play_arrow），点它也走 _play(0)，同样会装上补货器。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => _play(0),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('播放全部'),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.sm,
                        AppSpacing.lg,
                        AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                      ),
                      // +1 是底部哨兵行，兼作翻页指示与"没有更多"的落点。
                      itemCount: songs.length + 1,
                      itemBuilder: (context, index) {
                        if (index == songs.length) {
                          return _buildListFooter(context);
                        }
                        return SongListItem(
                          song: songs[index],
                          // 与卡片一致：右侧仅收藏按钮。
                          trailingActions: SongTrailingActions.favoriteOnly,
                          onTap: () => _play(index),
                          onMoreTap: () {},
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }
}

/// 可折叠 section 容器：
/// - 标题行左侧可点击区域（标题 + chevron 图标）触发 onToggle 折叠/展开
/// - 标题行右侧可放额外 widget（如"查看更多"按钮）
/// - 内容用 AnimatedCrossFade 在展示态和零高度态间平滑过渡
class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    required this.isExpanded,
    required this.onToggle,
    required this.child,
    this.trailing,
  });

  final String title;
  final bool isExpanded;
  final VoidCallback onToggle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SonifySpacing.titleMargin,
            AppSpacing.lg,
            SonifySpacing.titleMargin,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onToggle,
                  borderRadius: AppRadius.smAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            // 分区标题 18sp Bold（方案 §0.3 排印 token）
                            style: SonifyTextStyles.sectionTitle.copyWith(
                              color: cs.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Gap(AppSpacing.xs),
                        AnimatedRotation(
                          turns: isExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: isExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          sizeCurve: Curves.easeInOut,
          firstChild: child,
          secondChild: const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
