import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/cloud_song_mapper.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/song_list_item.dart';
import '../login/login_page.dart';
import '../user/cloud_music_page.dart';

/// 音乐库「云盘」段内嵌面板（[CloudMusicPage] 精简列表复用）。
///
/// 云盘的上传/多选删除/搜索过滤等管理能力与页面 AppBar actions 强耦合，
/// 不便整页抽离；此处仅复用其分页数据加载逻辑（getUserCloud 100/页拉满
/// 6000 首，[mapCloudApiItemToSong] 解析），列表点击即播（playCloudPlaylist
/// 同源）；「查看全部」跳 [CloudMusicPage] 承载完整管理。未登录显示引导
/// 登录空态（与已购段同款模式）。
class CloudHubPanel extends StatefulWidget {
  const CloudHubPanel({super.key});

  @override
  State<CloudHubPanel> createState() => _CloudHubPanelState();
}

class _CloudHubPanelState extends State<CloudHubPanel> {
  static const String _notLoggedIn = '请先登录';

  /// 云盘歌曲加载上限，与 CloudMusicPage._maxCloudSongs 对齐。
  static const int _maxCloudSongs = 6000;

  List<Song> _songs = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _error = null;
      _isLoading = true;
    });
    try {
      final api = KugouApiClient();
      if (!api.isLoggedIn) {
        _finish(error: _notLoggedIn);
        return;
      }
      const pageSize = 100;
      // 向上取整，保证能拉满 _maxCloudSongs 首（100*60=6000）
      const maxPages = (_maxCloudSongs + pageSize - 1) ~/ pageSize;
      final songs = <Song>[];
      for (var page = 1; page <= maxPages; page++) {
        final result =
            await api.getUserCloud(page: page, pagesize: pageSize, noCache: true);
        if (!mounted) return;
        if (result == null) {
          // 第一页失败才报错，后续页失败静默停止（CloudMusicPage 同口径）
          if (page == 1) {
            _finish(error: '加载失败，请稍后重试');
            return;
          }
          break;
        }
        final list = _extractList(result['data']);
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
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _isLoading = false;
      });
    } catch (_) {
      _finish(error: '加载失败，请稍后重试');
    }
  }

  void _finish({String? error}) {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _error = error;
    });
  }

  /// CloudMusicPage._safeExtractList 同款多形状兼容（data 为 List /
  /// JSON 字符串 / Map（info|list，值可为 List 或 JSON 字符串））。
  static List<dynamic>? _extractList(dynamic data) {
    if (data is List) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is List) return decoded;
        if (decoded is Map) {
          final inner = decoded['info'] ?? decoded['list'];
          if (inner is List) return inner;
          if (inner is String) {
            final innerDecoded = jsonDecode(inner);
            if (innerDecoded is List) return innerDecoded;
          }
        }
      } catch (_) {
        return null;
      }
      return null;
    }
    if (data is Map<String, dynamic>) {
      for (final key in const ['info', 'list']) {
        final inner = data[key];
        if (inner is List) return inner;
        if (inner is String) {
          try {
            final decoded = jsonDecode(inner);
            if (decoded is List) return decoded;
          } catch (_) {
            // 继续尝试下个字段
          }
        }
      }
    }
    return null;
  }

  void _openFullPage() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CloudMusicPage()),
    );
  }

  void _openLogin() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: M3ELoadingIndicator());
    if (_error == _notLoggedIn) return _buildLoginPrompt();
    if (_error != null) return _buildErrorRetry();
    if (_songs.isEmpty) return _buildEmpty();
    return Column(
      children: [
        // 头部：总数 + 「查看全部」跳云盘管理页（上传/删除在完整页承载）
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SonifySpacing.titleMargin,
            AppSpacing.xs,
            SonifySpacing.titleMargin,
            AppSpacing.xs,
          ),
          child: Row(
            children: [
              Text(
                '共 ${_songs.length} 首',
                style: SonifyTextStyles.listItem.copyWith(
                  color: SonifyColors.of(context).textSecondary,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: _openFullPage,
                borderRadius: BorderRadius.circular(AppRadius.xs),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                  child: Text(
                    '查看全部',
                    style: SonifyTextStyles.listItem.copyWith(
                      color: SonifyColors.of(context).primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            key: const PageStorageKey('hub_cloud_list'),
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom,
            ),
            itemCount: _songs.length,
            itemBuilder: (context, index) {
              return SongListItem(
                song: _songs[index],
                onTap: () {
                  context
                      .read<PlayerProvider>()
                      .playCloudPlaylist(_songs, index);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// 未登录引导空态（与已购面板同款模式）。
  Widget _buildLoginPrompt() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person_outline, size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
          const Gap(AppSpacing.md),
          Text(
            '登录后查看云盘音乐',
            style: SonifyTextStyles.cardTitle.copyWith(
              color: SonifyColors.of(context).textSecondary,
            ),
          ),
          const Gap(AppSpacing.lg),
          FilledButton.tonal(
            onPressed: _openLogin,
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorRetry() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: cs.error.withValues(alpha: 0.5)),
          const Gap(AppSpacing.md),
          Text(
            _error!,
            style: SonifyTextStyles.cardTitle.copyWith(
              color: SonifyColors.of(context).textSecondary,
            ),
          ),
          const Gap(AppSpacing.lg),
          FilledButton.tonal(
            onPressed: _load,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off, size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
          const Gap(AppSpacing.md),
          Text(
            '云盘暂无音乐',
            style: SonifyTextStyles.cardTitle.copyWith(
              color: SonifyColors.of(context).textSecondary,
            ),
          ),
          const Gap(AppSpacing.lg),
          FilledButton.tonal(
            onPressed: _openFullPage,
            child: const Text('查看全部'),
          ),
        ],
      ),
    );
  }
}
