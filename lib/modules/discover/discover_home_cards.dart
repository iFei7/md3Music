import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../data/models/song.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../login/login_page.dart';
import '../personal_fm/personal_fm_core.dart';
import '../user/play_history_page.dart';

/// 首页卡片区的档位预设（任务口径：红心 / 小众 / 速览）。
///
/// mode/songPoolId 与完整 FM 页的模式语义对齐：
/// 红心 = normal + 口味池(0)；小众 = small + 风格池(1)；速览 = peak + 口味池(0)。
/// 刻意不复用 [kFmStations]（红心/探索/小众）与桌面小部件的档位下标空间：
/// 本卡片的档位持久化用独立键，避免与 FmRefillStore / 小部件同步链路串档。
const List<FmStation> kHomeFmStations = [
  FmStation(
    label: '红心',
    icon: Icons.favorite,
    mode: 'normal',
    songPoolId: 0,
    description: '贴着你标过红心的歌来',
  ),
  FmStation(
    label: '小众',
    icon: Icons.diamond,
    mode: 'small',
    songPoolId: 1,
    description: '冷门但对味的作品',
  ),
  FmStation(
    label: '速览',
    icon: Icons.bolt,
    mode: 'peak',
    songPoolId: 0,
    description: '快节奏速览推荐',
  ),
];

const String _kHomeFmStationPrefKey = 'discover_home_fm_station';

/// 堆叠层数（前卡 + 下方两张）。
const int _kStackDepth = 3;

/// 首页私人 FM 堆叠大卡片（搜索框下方，替代原 FM/识曲快捷行）。
///
/// - 大图封面 + 歌名/歌手，卡片顶部一排档位 chips（红心/小众/速览），
///   点击切换并重拉推荐（getPersonalFm 带 mode/songPoolId，绕过 TTL）；
/// - 前卡横向滑动 dismiss 切下一首：正在播本电台队列时联动
///   [PlayerProvider.next]，否则只前移视觉指针（不抢播放）；
///   下方卡片带缩放/位移过渡前移；
/// - 正在播的卡片（当前 FM 曲目）显示播放/暂停 + 收藏（红心）按钮。
///
/// 播放链路与 PersonalFmSection 同源：起播走
/// moveToFirst + playOnlinePlaylist(personalFmAsSongs)，
/// 无限续播由 [FmRefill] 负责（不挂本组件，切走发现页照样续播）。
class DiscoverFmStackCard extends StatefulWidget {
  const DiscoverFmStackCard({super.key});

  /// 下拉刷新 FM 卡：发现页 [_loadAllData] 末尾调用。实际逻辑挂在
  /// State 上（需要摸当前实例的档位/加载态），此处仅作公开转发；
  /// 无挂载实例时 no-op。
  static Future<void> reloadCurrentStation() =>
      _DiscoverFmStackCardState.reloadCurrentStation();

  @override
  State<DiscoverFmStackCard> createState() => _DiscoverFmStackCardState();
}

class _DiscoverFmStackCardState extends State<DiscoverFmStackCard>
    with TickerProviderStateMixin {
  /// 当前挂载实例（下拉刷新重拉入口用）：堆叠卡在发现页全局唯一，
  /// initState 登记、dispose 摘除；未挂载时 reloadCurrentStation no-op。
  static _DiscoverFmStackCardState? _activeInstance;

  /// 下拉刷新 FM 卡：发现页 _loadAllData 末尾调用。复用当前实例的
  /// 档位参数强制重拉（getPersonalFm forceRefresh，绕过 TTL）；卡片
  /// 加载中跳过（防与用户切档/首刷并发）；未登录时由卡片自身的
  /// getPersonalFm 链静默回落空态。
  static Future<void> reloadCurrentStation() async {
    final instance = _activeInstance;
    if (instance == null) return;
    await instance._reloadStation();
  }

  Future<void> _reloadStation() async {
    if (_isLoading) return; // 防并发：首刷/切档进行中不叠加请求
    await _loadStation(forceRefresh: true);
  }

  bool _isLoading = false;
  int _stationIndex = 0;

  /// 未在播放时的视觉指针（前卡 = 列表第 _stackOffset 首之后的卡）。
  int _stackOffset = 0;

  /// 前卡拖拽位移（跟手）。
  double _dragDx = 0;

  /// 批次32：堆叠区宽度（LayoutBuilder 实测缓存，build 内赋值不触发重建）。
  /// 飞出距离 = 宽度 + [_kFlyOutExtra]——前卡真正滑出分区边界即止，
  /// 替代此前写死的 480px（480 < 常见分区宽时飞不出边界）。
  double _stackWidth = 0;

  /// dismiss 飞出动画：0→1，飞出位移 = [_flyFromDx] → [_flyDx] 连续
  /// 插值（批次33，见 [_flyFromDx]；旧公式 _flyDx×(1−t) 方向反了必闪回）。
  late final AnimationController _flyCtrl;
  double _flyDx = 0;
  bool _flying = false;

  /// 批次33：飞出起点位移（松手瞬间的跟手位移，[_onDragEnd] 放行分支
  /// setState 之前捕获）。飞出位移从它连续插值到 [_flyDx]——t=0 精确
  /// 落在释放位置，与松手前最后一帧跟手连续，杜绝「松手首帧瞬移到界外
  /// 再滑回原位」的闪回（旧公式 raw=0 时 offset=_flyDx 必有此帧）。
  double _flyFromDx = 0;

  /// 批次33：飞出起点的 dismiss 进度（释放瞬间的拖拽进度，
  /// clamp(|_flyFromDx|/_stackWidth)，[_onDragEnd] 捕获）。飞出中下层
  /// 卡前移进度从它 easeOutCubic 收敛到 1，松手边界连续。
  double _flyFromProgress = 0;

  /// 批次32：飞出时长。批次31 的 220ms 缩短到 200ms（用户口径
  /// 「划出去即消失」：飞出段短促）；与回弹 180ms 仍保持档次差。
  static const Duration _kFlyOutDuration = Duration(milliseconds: 200);

  /// 批次32：飞出目标距离余量（容器宽度 + 余量）。余量兜住卡片阴影/
  /// 圆角的视觉溢出，避免「看似出界实际还露一条边」。
  static const double _kFlyOutExtra = 64.0;

  /// 批次32：跟手渐隐透明度下限。拖到一半若全透明，用户看不到自己拖的
  /// 卡；0.35 保留「越拖越透」的感知又不至于消失。
  static const double _kDragOpacityFloor = 0.35;

  /// 批次31：回弹时长。落在 150~200ms 区间取 180ms——与飞出的 200ms
  /// （批次32 [_kFlyOutDuration]）拉开档次（回弹是「轻拨一下」，比全幅
  /// 飞出短一截），easeOutCubic 收尾。
  static const Duration _kSpringBackDuration = Duration(milliseconds: 180);

  /// 批次31：未过阈值松手后的回弹动画（0→1，[_kSpringBackDuration]）。
  ///
  /// 选型：新增独立小控制器，而非复用 _flyCtrl 反向——_flyCtrl 的
  /// 200ms 时长与 easeIn 读时曲线（批次32）都是为「飞出渐隐」定的，
  /// 回弹要的是 150~200ms 且位移从松手值收敛到 0（曲线语义正好反过来）；
  /// 反向复用还会和飞出窗口/[_flying] 标记/whenComplete 时序全搅在
  /// 一起。回弹值在 _buildStackArea 的 AnimatedBuilder 里读出
  /// （Listenable.merge 合并两个控制器逐帧重建），不走每帧 setState。
  late final AnimationController _springBackCtrl;

  /// 回弹起点（松手时的跟手位移）。动画值 = _springFromDx ×
  /// (1 − easeOutCubic(t))，t 走 _springBackCtrl.value（线性）。
  double _springFromDx = 0;

  bool _prefetching = false;

  FmStation get _station => kHomeFmStations[_stationIndex];

  @override
  void initState() {
    super.initState();
    _activeInstance = this;
    _flyCtrl = AnimationController(
      vsync: this,
      duration: _kFlyOutDuration,
    );
    // 批次31：回弹控制器（未过阈值松手时把跟手位移收敛回 0）
    _springBackCtrl = AnimationController(
      vsync: this,
      duration: _kSpringBackDuration,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreStation();
    });
  }

  @override
  void dispose() {
    if (_activeInstance == this) _activeInstance = null;
    _flyCtrl.dispose();
    _springBackCtrl.dispose();
    super.dispose();
  }

  Future<void> _restoreStation() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getInt(_kHomeFmStationPrefKey) ?? 0;
    final valid = saved >= 0 && saved < kHomeFmStations.length;
    final kugou = context.read<KugouProvider>();
    // 列表为空才首刷：正在播/已有列表时不抢数据、不打断播放；
    // 未登录不请求（卡片显示登录引导，无数据可拉）。
    final shouldLoad =
        valid && kugou.isLoggedIn && kugou.personalFmSongs.isEmpty;
    if (valid && saved != _stationIndex) {
      setState(() => _stationIndex = saved);
    }
    if (shouldLoad) {
      await _loadStation();
    }
  }

  /// 切换档位：存偏好 + 重拉推荐（mode/songPoolId 显式传参，服务端按档位
  /// 返回新列表；isInteractive 语义绕过 provider 的 freshness guard）。
  Future<void> _selectStation(int index) async {
    if (index == _stationIndex || index < 0 || index >= kHomeFmStations.length) {
      return;
    }
    setState(() {
      _stationIndex = index;
      _stackOffset = 0;
    });
    await _loadStation();
  }

  Future<void> _loadStation({bool forceRefresh = false}) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await context.read<KugouProvider>().getPersonalFm(
            mode: _station.mode,
            songPoolId: _station.songPoolId,
            forceRefresh: forceRefresh,
          );
    } catch (_) {
      // 失败静默：卡片回落「暂无推荐」占位，下拉刷新/再次点击可重试
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kHomeFmStationPrefKey, _stationIndex);
  }

  /// 列表见底时按当前档位补一批（只进 provider 列表，不动播放队列）。
  ///
  /// 必须先带游标（上一批最后一首）请求，整批重复或返回空时退回不带游标
  /// 再要一次——服务端对同游标可能原样回放已消费的批次，而 getPersonalFm
  /// 从不抛异常（_get 吞错返回 null），靠 catch 兜是死代码。与 FmRefill 的
  /// _append/_fetch 同一条兜底规则；没有这一步，最后一张滑走后堆叠区变
  /// 空白（GestureDetector 随卡片一起消失，再没有滑动/重建能触发补货）。
  Future<void> _prefetchMore() async {
    if (_prefetching) return;
    _prefetching = true;
    try {
      final kugou = context.read<KugouProvider>();
      final songs = kugou.personalFmSongs;
      final known = songs.map((s) => s.hash).toSet();
      final last = songs.isNotEmpty ? songs.last : null;
      var fresh = await kugou.fetchMorePersonalFm(
        mode: _station.mode,
        songPoolId: _station.songPoolId,
        hash: last?.hash,
        songId: last?.songId,
      );
      var usable = _freshOnly(fresh, known);
      if (usable.isEmpty && mounted) {
        final fallback = await kugou.fetchMorePersonalFm(
          mode: _station.mode,
          songPoolId: _station.songPoolId,
        );
        usable = _freshOnly(fallback, known);
      }
      if (usable.isNotEmpty && mounted) {
        kugou.appendFmSongs(usable);
      }
    } catch (_) {
    } finally {
      _prefetching = false;
    }
  }

  /// 去掉列表里已有的歌（appendFmSongs 按 hash 去重，这里先算一遍才能
  /// 判断「带游标那批是否真的有新歌」）。
  List<KugouSongDetail> _freshOnly(
    List<KugouSongDetail>? batch,
    Set<String> known,
  ) {
    if (batch == null) return const [];
    return batch.where((s) => !known.contains(s.hash)).toList();
  }

  // —— 播放控制（与 PersonalFmSection 同语义） ——

  /// 新建续播器占住 onPlaylistEnd。sessionGeneration 不传：本卡片不与
  /// 桌面小部件的持久化档位（kFmStations 下标空间）互通，避免串档。
  FmRefill? _armRefill(KugouProvider kugou, PlayerProvider player,
      {bool adoptQueue = false}) {
    final songs = kugou.personalFmSongs;
    if (songs.isEmpty) return null;
    final refill = FmRefill(
      kugou: kugou,
      player: player,
      mode: _station.mode,
      songPoolId: _station.songPoolId,
      songs: songs,
      adoptQueue: adoptQueue,
    );
    player.onPlaylistEnd = refill.onQueueEnd;
    return refill;
  }

  /// 前卡播放键/点按：播放器在本电台 → 槽位补挂 + 播放/暂停切换；
  /// 不在本电台 → 起播前卡那一首（视觉指针归零）。
  Future<void> _handlePlayPause() async {
    final kugou = context.read<KugouProvider>();
    final player = context.read<PlayerProvider>();
    if (_isLoading) return;
    if (kugou.personalFmSongs.isEmpty) {
      await _loadStation();
      return;
    }
    final playingId = player.currentSong?.id;
    final isOnStation = playingId != null &&
        kugou.personalFmSongs.any((s) => s.hash == playingId);
    if (isOnStation) {
      // 槽位空了先补挂续播器（区块重建/上个续播器退场后 resume 出来的是
      // 一条永不补货的死队列），再切换播放/暂停。
      if (player.onPlaylistEnd == null) {
        _armRefill(kugou, player, adoptQueue: true);
      }
      if (player.isPlaying) {
        await player.pause();
      } else {
        await player.resume();
      }
    } else {
      await _playTop();
    }
  }

  Future<void> _playTop() async {
    final kugou = context.read<KugouProvider>();
    final player = context.read<PlayerProvider>();
    final songs = kugou.personalFmSongs;
    if (songs.isEmpty) return;
    final topIndex =
        (_stackOffset).clamp(0, songs.length - 1);
    setState(() => _stackOffset = 0);
    kugou.moveToFirst(songs[topIndex]);
    final refill = _armRefill(kugou, player);
    await player.playOnlinePlaylist(kugou.personalFmAsSongs, 0);
    unawaited(refill?.append()); // 立即补一批
  }

  /// dismiss 收尾（批次31）：飞出动画播完后的状态切换。
  ///
  /// 重构要点：「同步判定 + 同步状态更新」与「async 播放跟随执行」分离，
  /// 清飞出态（_flying/_flyDx/_dragDx）与视觉指针前移（_stackOffset += 1）
  /// 合并进**同一次 setState**，杜绝中间可见帧——
  /// - 未播放本电台：t=1 帧下层已前移就位（layer1 shrink=0 全尺寸、
  ///   与指针前移后的 layer0 形态逐项吻合），一次 setState 即无缝交接。
  ///   此前分成「setState 清飞出态」→「_onDismissed 里再 setState 前移
  ///   指针」两次，靠 Flutter 帧合并才没露馅；播放路径一 await 就露出
  ///   「划走的卡全不透明停回原位」的闪回帧（真机用户可见）。
  /// - 正在播本电台且播放中：先 await player.next()（播放索引驱动 base
  ///   前移、_stackOffset 不动——契约保持），再清飞出态。等待期间保持
  ///   _flying=true：被划走的卡停在 t=1 的不可见态，下层（下一首）已
  ///   全尺寸就位；next() 成功路径的 notifyListeners 后即 return，与
  ///   本方法的 setState 落在同一微任务排水期内、合并为同一帧，无缝
  ///   交接。next() 失败（拿不到播放链接等）回落到「仅前移视觉指针」，
  ///   不卡死在飞出态（_flying 会屏蔽新手势）。
  Future<void> _finishDismiss() async {
    final kugou = context.read<KugouProvider>();
    final player = context.read<PlayerProvider>();
    final songs = kugou.personalFmSongs;
    final playingId = player.currentSong?.id;
    final playingIndex = playingId == null
        ? -1
        : songs.indexWhere((s) => s.hash == playingId);
    var followed = false;
    if (playingIndex >= 0 && player.isPlaying) {
      try {
        await player.next();
        followed = true;
      } catch (_) {
        // 播放跟随失败：不卡死，回落非播放分支收尾（见 followed=false）
      }
    }
    if (!mounted) return;
    setState(() {
      _flying = false;
      _flyDx = 0;
      _dragDx = 0;
      if (!followed) _stackOffset += 1;
    });
  }

  void _onDragEnd(DragEndDetails details) {
    // 飞出中忽略新手势收尾：200ms 飞出窗口内再次抬手不应触发二次 dismiss
    if (_flying) return;
    final dx = _dragDx;
    const threshold = 90.0;
    final velocity = details.velocity.pixelsPerSecond.dx;
    if (dx.abs() > threshold || velocity.abs() > 700) {
      // 飞出方向沿拖拽方向（速度够时即使位移不足也放行）；
      // 批次32：飞出目标 = 容器宽 + 余量（[_kFlyOutExtra]）——滑出分区
      // 边界即止，不再写死 480px（LayoutBuilder 实测宽度缓存于
      // [_stackWidth]，交互前必已测量）。
      final dir = (dx != 0) ? dx.sign : velocity.sign;
      // 批次33：捕获释放瞬间的跟手位移与 dismiss 进度（setState 之前、
      // 与放行判定同源）——飞出位移/透明度从释放位置连续插值到界外，
      // 下层进度从释放进度连续收敛，松手边界零跳变（真根因：旧飞出
      // 公式起点在界外，松手首帧瞬移+滑回=用户反馈的闪回）。
      _flyFromDx = dx;
      _flyFromProgress = _stackWidth > 0
          ? (dx.abs() / _stackWidth).clamp(0.0, 1.0)
          : 0.0; // 未测量（极端情形）：进度兜 0
      setState(() {
        _flying = true;
        _flyDx = dir * (_stackWidth + _kFlyOutExtra);
        _dragDx = 0;
      });
      _flyCtrl.forward(from: 0).whenComplete(() {
        if (!mounted) return;
        unawaited(_finishDismiss());
      });
    } else {
      // 批次31：未过阈值 → 回弹动画（180ms easeOutCubic 收敛到 0），
      // 替代此前的瞬移 setState(_dragDx = 0)（松手「跳」回原位很跳戏）。
      // 动画值在 _buildStackArea 的 AnimatedBuilder 里读出并施加到前卡
      // 子树，不走每帧 setState；_dragDx 先归零，回弹播完（isAnimating
      // =false）后视图自然落回 0。
      if (_dragDx == 0) return;
      _springFromDx = _dragDx;
      setState(() => _dragDx = 0);
      _springBackCtrl.forward(from: 0);
    }
  }

  // —— 构建 ——

  @override
  Widget build(BuildContext context) {
    return Padding(
      // bottom 给 md：与下方「最近播放」标题行（top=sm + 标题行纵向 xs）
      // 合计 24dp，拉开分区间隔（此前 bottom=0 时视觉上贴死）。
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin, AppSpacing.sm, SonifySpacing.titleMargin,
        AppSpacing.md,
      ),
      child: Selector2<KugouProvider, PlayerProvider,
          (bool, List<KugouSongDetail>, String?, bool)>(
        selector: (_, kugou, player) => (
          kugou.isLoggedIn,
          kugou.personalFmSongs,
          player.currentSong?.id,
          player.isPlaying,
        ),
        builder: (context, record, _) {
          final (isLoggedIn, songs, playingId, isPlaying) = record;
          if (!isLoggedIn) return _buildLoginPrompt(context);
          final playingIndex = playingId == null
              ? -1
              : songs.indexWhere((s) => s.hash == playingId);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeaderRow(context),
              const Gap(AppSpacing.sm),
              _buildStackArea(context, songs, playingIndex, isPlaying),
            ],
          );
        },
      ),
    );
  }

  /// 分区标题 + 档位 chips（红心/小众/速览，点击切换并刷新推荐）。
  Widget _buildHeaderRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          '私人 FM',
          style: SonifyTextStyles.sectionTitle.copyWith(color: cs.onSurface),
        ),
        const Spacer(),
        for (var i = 0; i < kHomeFmStations.length; i++) ...[
          if (i > 0) const Gap(AppSpacing.xs),
          _buildStationChip(context, i),
        ],
      ],
    );
  }

  Widget _buildStationChip(BuildContext context, int index) {
    final cs = Theme.of(context).colorScheme;
    final selected = index == _stationIndex;
    return GestureDetector(
      onTap: _isLoading ? null : () => unawaited(_selectStation(index)),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: SonifyMotion.glassAlpha,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: selected ? cs.primary : cs.surfaceContainerHighest,
        ),
        child: Text(
          kHomeFmStations[index].label,
          style: SonifyTextStyles.listItem.copyWith(
            color: selected ? cs.onPrimary : cs.onSurfaceVariant,
          ),
          maxLines: 1,
        ),
      ),
    );
  }

  Widget _buildStackArea(
    BuildContext context,
    List<KugouSongDetail> songs,
    int playingIndex,
    bool isPlaying,
  ) {
    if (songs.isEmpty) {
      return _buildEmptyCard(context);
    }
    final base = playingIndex >= 0 ? playingIndex : 0;
    // 列表见底时按档位补一批（guard 在 _prefetchMore 内）
    if (base + _stackOffset >= songs.length - 1) {
      unawaited(_prefetchMore());
    }

    // 由后往前叠：下面两张缩小/下沉，前卡置顶可拖拽。
    // 层级构建必须放进 AnimatedBuilder builder：每个动画 tick 都要带
    // 最新飞出进度 t 重算各层形态（前卡滑出渐隐、下层前移）。
    //
    // 批次32：外层 LayoutBuilder 实测堆叠区宽度，缓存到 [_stackWidth]
    // 供 _onDragEnd 计算飞出距离（事件回调里拿不到 constraints）。
    // build 内赋值仅作缓存、不触发重建；AnimatedBuilder 保持常驻。
    return LayoutBuilder(
      builder: (context, constraints) {
        _stackWidth = constraints.maxWidth;
        return AnimatedBuilder(
          // 批次31：飞出与回弹共用这一个 AnimatedBuilder——两个控制器的
          // tick 都触发逐帧重建（回弹期间前卡跟手位移由动画值驱动，不走
          // 每帧 setState）。
          animation: Listenable.merge([_flyCtrl, _springBackCtrl]),
          builder: (context, _) {
            // 批次32：前卡与下层曲线分离——前卡 easeIn（后段加速消失，
            // 视觉=滑出去就没了）；下层 easeOutCubic（前快后慢），前卡
            // 一划走下一张立刻趋向全尺寸上位，不等飞出尾声。
            final raw = _flying ? _flyCtrl.value : 0.0;
            final t = _flying ? Curves.easeIn.transform(raw) : 0.0;
            // 回弹进行中：前卡跟手位移由动画值驱动（与飞出同款读时
            // easeOutCubic）；否则用跟手值 _dragDx。
            final dragDx = _springBackCtrl.isAnimating
                ? _springFromDx *
                    (1 - Curves.easeOutCubic.transform(_springBackCtrl.value))
                : _dragDx;
            // 批次33：统一 dismiss 进度 p——下层卡（下一首）的前移量。
            // 拖拽/回弹中：|视觉dx| / 容器宽（视觉 dx 即上面的 dragDx，
            // 回弹中取回弹动画当前位移），与手指 1:1 耦合——旧实现只在
            // _flying 时推进（layerEase），拖拽中下层完全冻结、松手后才动；
            // 飞出中：从释放进度 _flyFromProgress 起 easeOutCubic 收敛到 1
            // （前快后慢，下一张速位上位），raw=0 时精确等于释放时进度。
            final double dismissProgress;
            if (_flying) {
              dismissProgress = _flyFromProgress +
                  (1 - _flyFromProgress) *
                      Curves.easeOutCubic.transform(raw);
            } else {
              dismissProgress = _stackWidth > 0
                  ? (dragDx.abs() / _stackWidth).clamp(0.0, 1.0)
                  : 0.0; // 未测量（极端情形）：下层不前移
            }
            final children = <Widget>[];
            for (var layer = _kStackDepth - 1; layer >= 0; layer--) {
              final idx = base + _stackOffset + layer;
              if (idx >= songs.length) continue;
              children.add(_buildLayeredCard(
                context,
                songs[idx],
                layer: layer,
                // 批次33：前卡走 easeIn（t），下层走统一 dismiss 进度 p
                // （拖拽跟手前移、飞出从释放进度 easeOutCubic 续进）。
                progress: layer == 0 ? t : dismissProgress,
                dragDx: dragDx,
                playingIndex: playingIndex,
                isPlaying: isPlaying,
              ));
            }
            return SizedBox(
              height: 320,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final child in children) Positioned.fill(child: child),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLayeredCard(
    BuildContext context,
    KugouSongDetail song, {
    required int layer,
    /// 层级进度（批次33 起下层改传统一 dismiss 进度）：
    /// 前卡（layer=0）= 飞出 easeIn 进度 t；下层 = 统一 dismiss 进度 p
    /// （拖拽中与手指 1:1，飞出中从释放进度 easeOutCubic 收敛到 1）。
    required double progress,
    required double dragDx,
    required int playingIndex,
    required bool isPlaying,
  }) {
    // 前卡：手势识别器常驻（位移只施加在子树，见 _buildFrontCardGesture）。
    if (layer == 0) {
      return _buildFrontCardGesture(
        context,
        song,
        playingIndex: playingIndex,
        isPlaying: isPlaying,
        flyProgress: progress,
        dragDx: dragDx,
      );
    }
    // 下方层：缩小下沉 + 半透明（层级暗示）；dismiss 进度越大越趋向
    // 全尺寸前移一级（批次33：progress = 统一 dismiss 进度 p，拖拽中
    // 即跟手前移，飞出中从释放进度 easeOutCubic 续进到 1，前快后慢）。
    final shrink = (layer - progress).clamp(0.0, layer.toDouble());
    return Transform.scale(
      scale: 1 - shrink * 0.04,
      child: Transform.translate(
        offset: Offset(0, shrink * 14.0),
        child: Opacity(
          opacity: 1 - shrink * 0.25,
          child: _buildCardFace(context, song),
        ),
      ),
    );
  }

  /// 前卡容器：**GestureDetector 常驻**，跟手拖拽/飞出位移一律施加在其
  /// 子树（Transform）上，绝不整体更换 widget 类型。
  ///
  /// 真机 bug 根因（批次 7 反馈「FM 卡片无法左右滑动切换」）：此前拖拽态
  /// 把 GestureDetector 换成 `Transform.translate` 直包卡面，首帧重建即
  /// 触发 `OneSequenceGestureRecognizer.dispose()`——它会把自己从
  /// pointerRouter 摘除（recognizer.dart:485-493），后续 move/up 事件再也
  /// 到不了，`onHorizontalDragEnd` 不触发，卡片停在几 px 位移处「滑不动」。
  /// 既有 widget 测试 moveBy 与 up 之间不插帧、识别器没被换掉才侥幸绿，
  /// 真机上 move 事件间必有帧落地，故 100% 复现。
  ///
  /// 与垂直滚动的竞争（arena）：HorizontalDragGestureRecognizer 在
  /// |Σdx| > touchSlop 时即 resolve(accepted)，同事件内比 Scrollable 的
  /// VerticalDragGestureRecognizer（更靠祖先、后入竞技场）先声夺势；纯水平
  ///  swipe 垂直向累计量不越 slop，滚动器不会抢。仍保留水平语义：以竖向
  /// 分量开头（|Σdy| 先越 slop）的手势交给页面滚动，属预期行为。
  Widget _buildFrontCardGesture(
    BuildContext context,
    KugouSongDetail song, {
    required int playingIndex,
    required bool isPlaying,
    required double flyProgress,
    required double dragDx,
  }) {
    Widget card = _buildFrontCard(context, song, playingIndex, isPlaying);
    // 飞出中的前卡：沿 _flyDx 平移 + 渐隐（_flying 优先于跟手位移）。
    // 批次32：flyProgress 为 easeIn 变换值——后段加速消失，视觉上
    // 「滑出去就没了」；t=1 时透明度精确收敛到 0。
    // 批次33：位移/透明度都从「释放位置」连续插值——旧公式
    // offset=_flyDx×(1−flyProgress) 方向反了（raw=0 时整卡已在边界
    // 外），松手首帧从释放位置瞬移到界外、再滑回原位渐隐，即用户反复
    // 反馈的「划走后往回闪一下」；且旧公式 t=0 透明度=1 与松手帧的
    // 跟手渐隐值也不连续（批次32 的 await 窗口是另一个闪回源，已修）。
    if (_flying) {
      // 飞出位移：t=0 精确 = _flyFromDx（松手帧跟手位移，无跳变），
      // t=1 到 _flyDx（容器宽 + _kFlyOutExtra 的界外）；方向沿拖拽、
      // 全程单调外出不回退。
      final flyOffset = _flyFromDx + (_flyDx - _flyFromDx) * flyProgress;
      // 飞出透明度：从释放帧的 _dragOpacity(_flyFromDx) 连续收敛到 0
      // （t=0 与松手前最后一帧一致，t=1 精确为 0）。
      card = Transform.translate(
        offset: Offset(flyOffset, 0),
        child: Opacity(
          opacity: _dragOpacity(_flyFromDx) * (1 - flyProgress),
          child: card,
        ),
      );
    } else if (dragDx != 0) {
      // 跟手拖拽/回弹（仅前卡）：位移/旋转施加在子树，识别器不重建。
      // 批次32：外层套渐隐——透明度随 |dx| 增长而下降（easeIn 型，
      // 越拖越透），下限 [_kDragOpacityFloor]；回弹中同拍生效（位移
      // 收敛回 0，透明度随之恢复）。
      card = Opacity(
        opacity: _dragOpacity(dragDx),
        child: Transform.translate(
          offset: Offset(dragDx, 0),
          child: Transform.rotate(
            angle: dragDx / 1200,
            child: card,
          ),
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) {
        // 飞出中忽略新手势：防 200ms 窗口内二次 dismiss
        if (_flying) return;
        setState(() {
          if (_springBackCtrl.isAnimating) {
            // 批次31：回弹中途再次跟手——从当前视觉位移无缝接续并停掉
            // 回弹，否则跟手值与回弹值两套位移打架（卡片会「跳」回
            // 松开点）。
            _dragDx = _springDx;
            _springBackCtrl.stop();
          }
          _dragDx += d.delta.dx;
        });
      },
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: () {
        if (_flying) return;
        // 批次31：一并停掉回弹（纵向滚动抢走手势时卡片瞬间归位，
        // 不留半截回弹与归位值打架）。
        _springBackCtrl.stop();
        setState(() => _dragDx = 0);
      },
      child: card,
    );
  }

  /// 批次31：回弹中的当前视觉位移（easeOutCubic 读时施加，与飞出同款）。
  /// 回弹中途再次跟手时以它为起点，保证位移连续。
  double get _springDx => _springFromDx *
      (1 - Curves.easeOutCubic.transform(_springBackCtrl.value));

  /// 批次32：跟手渐隐透明度。以 [_stackWidth] 归一化位移，easeIn 曲线
  /// （越拖越透：单位位移的透明度损失随位移加大而加速），下限
  /// [_kDragOpacityFloor]。回弹中同样生效（位移收敛回 0，透明度随之
  /// 恢复），与回弹位移动画天然同拍。
  double _dragOpacity(double dx) {
    if (_stackWidth <= 0) return 1.0; // 未测量（极端情形）：不渐隐
    final p = (dx.abs() / _stackWidth).clamp(0.0, 1.0);
    return _kDragOpacityFloor +
        (1 - _kDragOpacityFloor) * (1 - Curves.easeIn.transform(p));
  }

  /// 前卡：大图封面 + 歌名/歌手 + 播放暂停 + 收藏红心。
  Widget _buildFrontCard(
    BuildContext context,
    KugouSongDetail song,
    int playingIndex,
    bool isPlaying,
  ) {
    return _buildCardFace(
      context,
      song,
      isFront: true,
      isPlayingThis: playingIndex >= 0 && isPlaying,
      onPlayPause: _handlePlayPause,
    );
  }

  Widget _buildCardFace(
    BuildContext context,
    KugouSongDetail song, {
    bool isFront = false,
    bool isPlayingThis = false,
    VoidCallback? onPlayPause,
  }) {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    return SmoothClipRRect(
      borderRadius: BorderRadius.circular(SonifyRadius.card),
      child: Container(
        color: sonify.surfaceCard,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _buildCover(context, song.artworkUri),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.songName,
                          style: SonifyTextStyles.cardTitle.copyWith(
                            color: cs.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (song.artistName?.isNotEmpty ?? false) ...[
                          const Gap(2),
                          Text(
                            song.artistName!,
                            style: SonifyTextStyles.listItem.copyWith(
                              color: sonify.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (isFront) ...[
                    _buildFavoriteButton(context, song),
                    _buildPlayButton(context, isPlayingThis, onPlayPause),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(BuildContext context, String? url) {
    final cs = Theme.of(context).colorScheme;
    if (url == null || url.isEmpty) {
      return Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.radio, size: 40, color: cs.onSurfaceVariant),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      memCacheWidth: 640,
      memCacheHeight: 640,
      fit: BoxFit.cover,
      placeholder: (_, _) => Container(color: cs.surfaceContainerHighest),
      errorWidget: (_, _, _) => Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.music_note, size: 40, color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _buildFavoriteButton(BuildContext context, KugouSongDetail song) {
    return Selector<FavoritesProvider, bool>(
      selector: (_, favorites) => favorites.isFavorite(song.hash),
      builder: (context, isFavorite, _) {
        final cs = Theme.of(context).colorScheme;
        return IconButton(
          tooltip: isFavorite ? '取消收藏' : '收藏',
          onPressed: () => context
              .read<FavoritesProvider>()
              .toggleFavorite(song.toSong()),
          icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
          color: isFavorite ? cs.primary : cs.onSurfaceVariant,
        );
      },
    );
  }

  Widget _buildPlayButton(
    BuildContext context,
    bool isPlayingThis,
    VoidCallback? onPlayPause,
  ) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: isPlayingThis ? '暂停' : '播放',
      onPressed: onPlayPause,
      icon: _isLoading
          ? SizedBox(
              width: 20,
              height: 20,
              child: M3ELoadingIndicator(color: cs.primary),
            )
          : Icon(isPlayingThis ? Icons.pause_circle : Icons.play_circle),
      color: cs.primary,
      iconSize: 34,
    );
  }

  Widget _buildEmptyCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    return GestureDetector(
      onTap: _isLoading ? null : () => unawaited(_loadStation()),
      behavior: HitTestBehavior.opaque,
      child: SmoothClipRRect(
        borderRadius: BorderRadius.circular(SonifyRadius.card),
        child: Container(
          color: sonify.surfaceCard,
          height: 120,
          alignment: Alignment.center,
          child: _isLoading
              ? SizedBox(
                  width: 28,
                  height: 28,
                  child: M3ELoadingIndicator(color: cs.primary),
                )
              : Text(
                  '暂无推荐，点按或下拉刷新重试',
                  style: SonifyTextStyles.listItem.copyWith(
                    color: sonify.textSecondary,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildLoginPrompt(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      ),
      behavior: HitTestBehavior.opaque,
      child: SmoothClipRRect(
        borderRadius: BorderRadius.circular(SonifyRadius.card),
        child: Container(
          color: sonify.surfaceCard,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: cs.primaryContainer,
                ),
                child: Icon(Icons.radio, size: 22, color: cs.onPrimaryContainer),
              ),
              const Gap(AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '登录后开启你的专属电台',
                      style: SonifyTextStyles.cardTitle.copyWith(
                        color: cs.onSurface,
                      ),
                    ),
                    const Gap(2),
                    Text(
                      '按你的口味不断续播',
                      style: SonifyTextStyles.listItem.copyWith(
                        color: sonify.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首页「最近播放」大卡片：标题行（最近播放 + 右箭头）+ 封面 + 歌名 +
/// 歌手 + 播放态图标。
///
/// - 标题行整行可点 → [PlayHistoryPage]（照搬 library_page /
///   user_center_page 的 MaterialPageRoute push 用法，不造新路由；
///   history 模块只读参考）；
/// - 卡片本体点击语义（任务允许自定）：**播放/暂停切换**——暂停态点击
///   恢复播放，播放态点击暂停（对齐卡片上播放键的常规心智）；
/// - 无播放内容时整块隐藏（SizedBox.shrink，不占列表位）。
class DiscoverNowPlayingCard extends StatelessWidget {
  const DiscoverNowPlayingCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin, AppSpacing.sm, SonifySpacing.titleMargin, 0,
      ),
      // 只订阅 (当前曲目, 是否在播) 两个值：position 高频通知不触发重建
      //（record 值相等时 Selector 跳过重建）。
      child: Selector<PlayerProvider, (Song?, bool)>(
        selector: (_, player) => (player.currentSong, player.isPlaying),
        builder: (context, record, _) {
          final (song, isPlaying) = record;
          if (song == null) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeaderRow(context),
              const Gap(AppSpacing.xs),
              _buildNowPlayingCard(context, song, isPlaying),
            ],
          );
        },
      ),
    );
  }

  /// 标题行：「最近播放」+ 右侧箭头（整行点按进历史播放页）。
  ///
  /// 形态照 discover_page._sectionHeader 的「更多」行（18sp Bold 标题 +
  /// 24dp primary 右箭头）。内层 GestureDetector 在手势竞技场中优先于
  /// 卡片本体的播放/暂停手势（同搜索框内识曲按钮的层级套路）。
  Widget _buildHeaderRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      // 上下补 4dp：箭头 24dp 外再扩出舒适点按区
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PlayHistoryPage()),
        ),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            Expanded(
              child: Text(
                '最近播放',
                style: SonifyTextStyles.sectionTitle.copyWith(
                  color: cs.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Gap(AppSpacing.xs),
            Icon(Icons.chevron_right, size: 24, color: cs.primary),
          ],
        ),
      ),
    );
  }

  /// 卡片本体：封面 + 歌名/歌手 + 播放态图标；点击 = 播放/暂停切换。
  Widget _buildNowPlayingCard(
    BuildContext context,
    Song song,
    bool isPlaying,
  ) {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    return GestureDetector(
      onTap: () {
        final player = context.read<PlayerProvider>();
        if (player.isPlaying) {
          unawaited(player.pause());
        } else {
          unawaited(player.resume());
        }
      },
      behavior: HitTestBehavior.opaque,
      child: SmoothClipRRect(
        borderRadius: BorderRadius.circular(SonifyRadius.card),
        child: Container(
          color: sonify.surfaceCard,
          padding: const EdgeInsets.all(AppSpacing.sm),
          height: 100,
          child: Row(
            children: [
              SmoothClipRRect(
                borderRadius: BorderRadius.circular(SonifyRadius.cover),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: (song.artworkUri != null &&
                          song.artworkUri!.isNotEmpty)
                      ? CachedNetworkImage(
                          imageUrl: song.artworkUri!,
                          memCacheWidth: 216,
                          memCacheHeight: 216,
                          fit: BoxFit.cover,
                          placeholder: (_, _) => Container(
                            color: cs.surfaceContainerHighest,
                          ),
                          errorWidget: (_, _, _) => Container(
                            color: cs.surfaceContainerHighest,
                            child: Icon(
                              Icons.music_note,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        )
                      : Container(
                          color: cs.surfaceContainerHighest,
                          child: Icon(
                            Icons.music_note,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
              const Gap(AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.displayName,
                      style: SonifyTextStyles.cardTitle.copyWith(
                        color: cs.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Gap(2),
                    Text(
                      song.artist,
                      style: SonifyTextStyles.listItem.copyWith(
                        color: sonify.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Gap(AppSpacing.sm),
              Icon(
                isPlaying ? Icons.pause_circle : Icons.play_circle,
                size: 34,
                color: cs.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
