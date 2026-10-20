import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../providers/library_provider.dart';
import '../../widgets/song_menu_header.dart';

/// 编辑器输入长度上限：歌名/歌手/专辑均为展示字段，超长无意义且会
/// 破坏列表/详情布局（安全审计要求：编辑器输入做非空 + 长度校验，
/// 输入侧用 [LengthLimitingTextInputFormatter] 硬限、保存侧再兜底）。
const int _kMaxFieldLength = 100;

/// 本地歌曲「编辑歌曲信息」应用内编辑器（底部弹层）。
///
/// 与更多菜单第二项「用 Lyrico 编辑标签」的分工（两者区别）：
/// - 本编辑器：只改**本机曲库记录**——[LibraryProvider.updateSongInfo]
///   更新内存态并持久化到 SharedPreferences 缓存；**不触碰音频文件**，
///   因此重新扫描（以文件标签为准）会覆盖本次编辑结果；
/// - Lyrico：把文件交给外部编辑器写**音频文件内嵌标签**，下次扫描时
///   才反映到曲库（未安装则提示）。
///
/// 保存成功后 Toast「已保存」并关闭弹层；歌名空校验 / 长度超限 /
/// 持久化失败时 Toast 提示且保持打开（不丢用户已填内容）。
class LocalSongEditSheet extends StatefulWidget {
  final Song song;

  const LocalSongEditSheet({super.key, required this.song});

  @override
  State<LocalSongEditSheet> createState() => _LocalSongEditSheetState();
}

class _LocalSongEditSheetState extends State<LocalSongEditSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;
  late final TextEditingController _albumController;

  /// 保存中防重入（持久化未返回前禁用按钮，避免重复写）。
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 预填当前曲库记录值（与列表显示同源：song.title 原始值）
    _titleController = TextEditingController(text: widget.song.title);
    _artistController = TextEditingController(text: widget.song.artist);
    _albumController = TextEditingController(text: widget.song.album);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // trim 后校验：纯空白歌名视为空（Toast 拦截，不关闭）
    final title = _titleController.text.trim();
    final artist = _artistController.text.trim();
    final album = _albumController.text.trim();
    if (title.isEmpty) {
      showToast('歌名不能为空');
      return;
    }
    if (title.length > _kMaxFieldLength ||
        artist.length > _kMaxFieldLength ||
        album.length > _kMaxFieldLength) {
      showToast('内容过长（最多 $_kMaxFieldLength 字）');
      return;
    }

    setState(() => _saving = true);
    final ok = await context.read<LibraryProvider>().updateSongInfo(
      widget.song.id,
      title: title,
      artist: artist,
      album: album,
    );
    if (!mounted) return;
    if (ok) {
      showToast('已保存');
      Navigator.pop(context);
    } else {
      // 持久化失败：保持弹层打开，用户可重试（不丢已填内容）
      setState(() => _saving = false);
      showToast('保存失败，请重试', long: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        // 键盘避让：isScrollControlled 弹层下用 viewInsets 底距把
        // 操作行顶到键盘之上
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          bottom: AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部：复用更多菜单同款封面 + 歌名/歌手/专辑（简化头部，
            // 不另造标题组件）
            SongMenuHeader(song: widget.song),
            const Divider(height: 1),
            const Gap(AppSpacing.sm),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: '歌曲名'),
              inputFormatters: [
                LengthLimitingTextInputFormatter(_kMaxFieldLength),
              ],
              textInputAction: TextInputAction.next,
            ),
            const Gap(AppSpacing.sm),
            TextField(
              controller: _artistController,
              decoration: const InputDecoration(labelText: '歌手'),
              inputFormatters: [
                LengthLimitingTextInputFormatter(_kMaxFieldLength),
              ],
              textInputAction: TextInputAction.next,
            ),
            const Gap(AppSpacing.sm),
            TextField(
              controller: _albumController,
              decoration: const InputDecoration(labelText: '专辑'),
              inputFormatters: [
                LengthLimitingTextInputFormatter(_kMaxFieldLength),
              ],
            ),
            const Gap(AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ),
                const Gap(AppSpacing.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开「编辑歌曲信息」应用内编辑器（更多菜单本地分支主入口）。
Future<void> showLocalSongEditSheet(BuildContext context, Song song) {
  return showM3EModalBottomSheet(
    context: context,
    builder: (_) => LocalSongEditSheet(song: song),
  );
}
