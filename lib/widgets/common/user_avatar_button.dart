import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';

/// 统一的用户头像钮（设置入口）。
///
/// 批次18：默认四个 tab 页（首页/音乐库/FM/搜索）顶栏右上角固定头像，
/// 点击进入设置页（设置页账号卡即账号管理入口）。未登录显示占位人形图标。
/// 头像经 Selector 按 `userInfo?.avatar` 最小重建，登录/登出/切号即时刷新。
class UserAvatarButton extends StatelessWidget {
  const UserAvatarButton({
    super.key,
    this.radius = 18,
    this.onTap,
  });

  /// 头像半径（默认 18，顶栏 36dp 规格）。
  final double radius;

  /// 自定义点击行为；默认 push 命名路由 `/settings`。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap ?? () => Navigator.of(context).pushNamed('/settings'),
      behavior: HitTestBehavior.opaque,
      child: Selector<KugouProvider, String?>(
        selector: (_, kugou) => kugou.userInfo?.avatar,
        builder: (context, avatar, _) => CircleAvatar(
          radius: radius,
          backgroundColor: cs.surfaceContainerHighest,
          backgroundImage: (avatar != null && avatar.isNotEmpty)
              ? CachedNetworkImageProvider(avatar)
              : null,
          child: (avatar == null || avatar.isEmpty)
              ? Icon(
                  Icons.person,
                  size: radius,
                  color: cs.onSurfaceVariant,
                )
              : null,
        ),
      ),
    );
  }
}
