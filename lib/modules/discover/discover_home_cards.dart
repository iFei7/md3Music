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

  @override
  State<DiscoverFmStackCard> createState() => _DiscoverFmStackCardState();
}

class _DiscoverFmStackCardState extends State<DiscoverFmStackCard>
    with SingleTickerProviderStateMixin {
  bool _isLoading = false;
  int _stationIndex = 0;

  /// 未在播放时的视觉指针（前卡 = 列表第 _stackOffset 首之后的卡）。
  int _stackOffset = 0;

  /// 前卡拖拽位移（跟手）。
  double _dragDx = 0;

  /// dismiss 飞出动画：0→1，飞出位移 = _flyDx × (1 − t)。
  late final AnimationController _flyCtrl;
  double _flyDx = 0;
  bool _flying = false;

  bool _prefetching = false;

  FmStation get _station => kHomeFmStations[_stationIndex];

  @override
  void initState() {
    super.initState();
    _flyCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreStation();
    });
  }

  @override
  void dispose() {
    _flyCtrl.dispose();
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

  Future<void> _loadStation() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await context.read<KugouProvider>().getPersonalFm(
            mode: _station.mode,
            songPoolId: _station.songPoolId,
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
  Future<void> _prefetchMore() async {
    if (_prefetching) return;
    _prefetching = true;
    try {
      final kugou = context.read<KugouProvider>();
      final songs = kugou.personalFmSongs;
      final last = songs.isNotEmpty ? songs.last : null;
      final fresh = await kugou.fetchMorePersonalFm(
        mode: _station.mode,
        songPoolId: _station.songPoolId,
        hash: last?.hash,
        songId: last?.songId,
      );
      if (fresh != null && fresh.isNotEmpty && mounted) {
        kugou.appendFmSongs(fresh);
      }
    } catch (_) {
    } finally {
      _prefetching = false;
    }
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

  /// 前卡滑出后的切歌联动：
  /// - 正在播本电台队列且播放中 → player.next()（播放跟随滑动）；
  /// - 其余（未播/暂停在别的队列）→ 只前移视觉指针，不打断/抢启动播放。
  Future<void> _onDismissed() async {
    final kugou = context.read<KugouProvider>();
    final player = context.read<PlayerProvider>();
    final songs = kugou.personalFmSongs;
    final playingId = player.currentSong?.id;
    final playingIndex = playingId == null
        ? -1
        : songs.indexWhere((s) => s.hash == playingId);
    if (playingIndex >= 0 && player.isPlaying) {
      await player.next();
    } else {
      if (mounted) setState(() => _stackOffset += 1);
    }
  }

  void _onDragEnd(DragEndDetails details) {
    final dx = _dragDx;
    const threshold = 90.0;
    final velocity = details.velocity.pixelsPerSecond.dx;
    if (dx.abs() > threshold || velocity.abs() > 700) {
      // 飞出方向沿拖拽方向（速度够时即使位移不足也放行）
      final dir = (dx != 0) ? dx.sign : velocity.sign;
      setState(() {
        _flying = true;
        _flyDx = dir * 480;
        _dragDx = 0;
      });
      _flyCtrl.forward(from: 0).whenComplete(() {
        if (!mounted) return;
        setState(() {
          _flying = false;
          _flyDx = 0;
        });
        unawaited(_onDismissed());
      });
    } else {
      setState(() => _dragDx = 0);
    }
  }

  // —— 构建 ——

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.titleMargin, AppSpacing.sm, SonifySpacing.titleMargin, 0,
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
    return AnimatedBuilder(
      animation: _flyCtrl,
      builder: (context, _) {
        final t = _flying ? Curves.easeOutCubic.transform(_flyCtrl.value) : 0.0;
        final children = <Widget>[];
        for (var layer = _kStackDepth - 1; layer >= 0; layer--) {
          final idx = base + _stackOffset + layer;
          if (idx >= songs.length) continue;
          children.add(_buildLayeredCard(
            context,
            songs[idx],
            layer: layer,
            flyProgress: t,
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
  }

  Widget _buildLayeredCard(
    BuildContext context,
    KugouSongDetail song, {
    required int layer,
    required double flyProgress,
    required int playingIndex,
    required bool isPlaying,
  }) {
    // 飞出中的前卡：沿 _flyDx 平移 + 渐隐
    if (layer == 0 && _flying) {
      final ft = flyProgress;
      return Transform.translate(
        offset: Offset(_flyDx * (1 - ft), 0),
        child: Opacity(
          opacity: 1 - ft,
          child: _buildFrontCard(context, song, playingIndex, isPlaying),
        ),
      );
    }
    // 跟手拖拽（仅前卡）
    if (layer == 0 && _dragDx != 0) {
      return Transform.translate(
        offset: Offset(_dragDx, 0),
        child: Transform.rotate(
          angle: _dragDx / 1200,
          child: _buildFrontCard(context, song, playingIndex, isPlaying),
        ),
      );
    }
    if (layer == 0) {
      // 前卡静止态同样走 _buildFrontCard（isFront: true，带播放/暂停 +
      // 收藏按钮）：此前只在拖拽/飞出分支用 _buildFrontCard，静止态
      // 落到 isFront:false 的裸卡面，按钮凭空消失，与类文档语义不符。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) =>
            setState(() => _dragDx += d.delta.dx),
        onHorizontalDragEnd: _onDragEnd,
        onHorizontalDragCancel: () => setState(() => _dragDx = 0),
        child: _buildFrontCard(context, song, playingIndex, isPlaying),
      );
    }
    // 下方层：缩小下沉 + 半透明（层级暗示）；飞出时随 t 前移一级
    final shrink = (layer - flyProgress).clamp(0.0, layer.toDouble());
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
                  '暂无推荐，点按加载',
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

/// 首页「正在播放」大卡片：封面 + 歌名 + 歌手。
///
/// 点击语义（任务允许自定）：**播放/暂停切换**——暂停态点击恢复播放
/// （任务要求的「点击继续播放」），播放态点击暂停（对齐卡片上播放键的
/// 常规心智）。无播放内容时整块隐藏（SizedBox.shrink，不占列表位）。
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
        },
      ),
    );
  }
}
