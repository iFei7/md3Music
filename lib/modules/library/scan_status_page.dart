import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/squircle.dart';
import '../../providers/library_provider.dart';
import '../../widgets/common/sonify_title_scaffold.dart';
import 'library_page.dart' show showLibraryScanMenu;

/// 扫描状态页（设计稿音乐库 9 项子页面之一，v6 新增）。
///
/// 最小实现：不引入新数据源，全部读 [LibraryProvider] 既有状态
/// （isScanning / error / songs / albums / artists / folders /
/// scanFolders / excludedFolders），扫描与目录管理动作复用面板既有
/// 的 [LibraryProvider.loadLocalMusic] / [LibraryProvider.addScanFolder]
/// / [LibraryProvider.addExcludedFolder] 与 [showLibraryScanMenu]，
/// 不造重复页。
///
/// 头部统一走 [SonifyTitleScaffold]（大标题折叠骨架），与首页同构。
class ScanStatusPage extends StatefulWidget {
  const ScanStatusPage({super.key});

  @override
  State<ScanStatusPage> createState() => _ScanStatusPageState();
}

class _ScanStatusPageState extends State<ScanStatusPage> {
  @override
  void initState() {
    super.initState();
    // 与本地音乐面板同口径恢复缓存/扫描目录，保证独立进入（如「扫描状态」
    // 可选 Tab 直达、未经本地音乐页）时也有数据可展示；调用幂等。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<LibraryProvider>();
      provider.loadSavedSongs();
      provider.loadScanFolders();
    });
  }

  @override
  Widget build(BuildContext context) {
    // watch：扫描开始/结束、目录增删后本页实时刷新
    final provider = context.watch<LibraryProvider>();
    final items = _buildItems(provider);
    return SonifyTitleScaffold(
      title: '扫描状态',
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }

  // ==================== 内容构建 ====================

  List<Widget> _buildItems(LibraryProvider provider) {
    final items = <Widget>[
      _buildStatusCard(provider),
      const Gap(AppSpacing.sm),
      _buildStatsCard(provider),
      const Gap(AppSpacing.sm),
      _buildActionRow(provider),
      const Gap(AppSpacing.sm),
    ];

    // 扫描目录
    items.add(_buildSectionHeader('扫描目录', provider.scanFolders.length));
    if (provider.scanFolders.isEmpty) {
      items.add(_buildHint('尚未配置扫描目录，点击「扫描音乐」按默认目录扫描'));
    } else {
      for (final folder in provider.scanFolders) {
        items.add(
          _buildFolderRow(
            folder: folder,
            onRemove: () => provider.removeScanFolder(folder),
          ),
        );
      }
    }
    items.add(_buildAddFolderButton(
      icon: Icons.create_new_folder_outlined,
      label: '添加扫描目录',
      onPressed: provider.isScanning ? null : () => provider.addScanFolder(),
    ));

    items.add(const Gap(AppSpacing.sm));

    // 排除目录
    items.add(_buildSectionHeader('排除目录', provider.excludedFolders.length));
    items.add(_buildHint('排除的文件夹及其子目录不会被扫描'));
    if (provider.excludedFolders.isEmpty) {
      items.add(_buildHint('暂无排除文件夹'));
    } else {
      for (final folder in provider.excludedFolders) {
        items.add(
          _buildFolderRow(
            folder: folder,
            onRemove: () => provider.removeExcludedFolder(folder),
          ),
        );
      }
    }
    items.add(_buildAddFolderButton(
      icon: Icons.folder_off_outlined,
      label: '添加排除目录',
      onPressed: provider.isScanning ? null : () => provider.addExcludedFolder(),
    ));

    // Dock 避让：消费底部手势条 + Dock 高度，让末项停在悬浮 Dock 上方
    items.add(SizedBox(height: MediaQuery.paddingOf(context).bottom));
    return items;
  }

  /// 状态卡：扫描中 / 空闲 / 错误三态。
  Widget _buildStatusCard(LibraryProvider provider) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isScanning = provider.isScanning;
    final error = provider.error;

    return _card(
      child: Row(
        children: [
          if (isScanning)
            const SizedBox(
              width: 28,
              height: 28,
              child: M3ELoadingIndicator(),
            )
          else
            Icon(
              error != null ? Icons.error_outline : Icons.check_circle,
              size: 28,
              color: error != null ? cs.error : cs.primary,
            ),
          const Gap(AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isScanning
                      ? '正在扫描本地音乐...'
                      : error != null
                      ? '上次扫描出错'
                      : '扫描空闲',
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Gap(AppSpacing.xxs),
                Text(
                  isScanning
                      ? '扫描在后台执行，可离开本页'
                      : (error ?? '共 ${provider.songs.length} 首本地音乐'),
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 统计卡：歌曲 / 专辑 / 艺术家 / 文件夹 四类计数。
  Widget _buildStatsCard(LibraryProvider provider) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final stats = <({String label, int count})>[
      (label: '歌曲', count: provider.songs.length),
      (label: '专辑', count: provider.albums.length),
      (label: '艺术家', count: provider.artists.length),
      (label: '文件夹', count: provider.folders.length),
    ];
    return _card(
      child: Row(
        children: [
          for (final stat in stats)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${stat.count}',
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
                  Text(
                    stat.label,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 操作行：扫描音乐（复用面板 FAB 同链路）+ 扫描选项（复用扫描菜单）。
  Widget _buildActionRow(LibraryProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.tonalIcon(
              // 扫描中禁用，防重复触发（与面板 FAB/扫描入口同规则）
              onPressed: provider.isScanning ? null : () => provider.loadLocalMusic(),
              icon: const Icon(Icons.refresh),
              label: Text(provider.isScanning ? '扫描中...' : '扫描音乐'),
            ),
          ),
          const Gap(AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: () => showLibraryScanMenu(context),
            icon: const Icon(Icons.tune),
            label: const Text('扫描选项'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xxs,
      ),
      child: Row(
        children: [
          Text(
            title,
            style: tt.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const Gap(AppSpacing.sm),
          Text(
            '$count',
            style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 目录行：名称 + 完整路径 + 移除按钮（复用 provider 既有增删 API）。
  Widget _buildFolderRow({
    required String folder,
    required VoidCallback onRemove,
  }) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final name = folder.split('/').where((p) => p.isNotEmpty).last;
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        folder,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.remove_circle_outline),
        tooltip: '移除',
        onPressed: onRemove,
      ),
    );
  }

  Widget _buildAddFolderButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.tonalIcon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        ),
      ),
    );
  }

  Widget _buildHint(String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ),
    );
  }

  /// squircle 9dp 卡底（与本地音乐面板搜索栏/ TabBar 容器同规格）。
  Widget _card({required Widget child}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
          shape: SmoothRectangleBorder(
            borderRadius: BorderRadius.circular(SonifyRadius.card),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: child,
        ),
      ),
    );
  }
}
