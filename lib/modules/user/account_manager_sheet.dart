import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/kugou_account.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../login/login_page.dart';

/// 「账号管理」底部面板：展示已保存账号，支持切换 / 删除 / 过期处理 /
/// 登录新账号。
///
/// 从 user_center_page 抽取为共享组件（原私有方法逐字迁移，行为不变），
/// 供「我的」页用户卡片与设置页账号卡共用。依赖统一走
/// `context.read<KugouProvider>()` / `context.read<FavoritesProvider>()`
/// （Provider 在面板之上，语义与原传入实例一致）。
Future<void> showAccountManagerSheet(BuildContext context) async {
  // 调用方 navigator：关闭面板与 push 登录页都用它，避免持有面板内部
  // 已被回收的 context
  final navigator = Navigator.of(context);
  await showM3EModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    builder: (_) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Consumer<KugouProvider>(
            builder: (context, provider, _) {
              final cs = Theme.of(context).colorScheme;
              final tt = Theme.of(context).textTheme;
              final accounts = provider.savedAccounts;
              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.7,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          '账号管理',
                          style: tt.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        if (accounts.length > 1)
                          Text(
                            '${accounts.length} 个账号',
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    const Gap(AppSpacing.sm),
                    if (accounts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xxl,
                        ),
                        child: Column(
                          children: [
                            Icon(
                              Icons.person_outline,
                              size: 48,
                              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                            ),
                            const Gap(AppSpacing.sm),
                            Text(
                              '暂无已保存的账号',
                              style: tt.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: accounts.length,
                          separatorBuilder: (_, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) => _buildAccountTile(
                            context,
                            accounts[index],
                          ),
                        ),
                      ),
                    const Gap(AppSpacing.md),
                    FilledButton.icon(
                      // 登录页用调用方 navigator push：面板关闭后也不会失效
                      onPressed: () => navigator.push(
                        MaterialPageRoute(builder: (_) => const LoginPage()),
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('登录新账号'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

/// 单个已保存账号的行
Widget _buildAccountTile(BuildContext context, KugouAccount account) {
  final cs = Theme.of(context).colorScheme;
  final tt = Theme.of(context).textTheme;
  final kugou = context.read<KugouProvider>();
  final isCurrent = account.userid == kugou.userid;
  final displayName = (account.nickname != null && account.nickname!.isNotEmpty)
      ? account.nickname!
      : '用户 ${account.userid}';
  return ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
    leading: _accountAvatar(account, cs),
    title: Row(
      children: [
        Flexible(
          child: Text(
            displayName,
            style: tt.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              // 过期账号的昵称置灰
              color: account.expired ? cs.onSurfaceVariant : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (account.expired) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: cs.errorContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '登录已过期',
              style: tt.labelSmall?.copyWith(
                color: cs.onErrorContainer,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ],
    ),
    subtitle: Text('ID: ${account.userid}', style: tt.bodySmall),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isCurrent)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: Icon(Icons.check_circle, color: cs.primary, size: 20),
          ),
        IconButton(
          tooltip: '删除账号',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _confirmRemoveAccount(context, account),
        ),
      ],
    ),
    // 过期账号点击直接引导重新登录/删除，不再走切换（凭证已失效）
    onTap: account.expired
        ? () => _handleExpiredAccount(context, account)
        : (isCurrent ? null : () => _switchToAccount(context, account)),
  );
}

/// 账号头像：有头像用缓存图，无则显示昵称首字
Widget _accountAvatar(KugouAccount account, ColorScheme cs) {
  final avatarUrl = account.avatar;
  final nickname = account.nickname;
  final fallback = Text(
    (nickname != null && nickname.isNotEmpty)
        ? nickname.characters.first
        : '?',
    style: TextStyle(color: cs.onPrimaryContainer, fontSize: 16),
  );
  if (avatarUrl == null || avatarUrl.isEmpty) {
    return CircleAvatar(
      radius: 20,
      backgroundColor: cs.primary.withValues(alpha: 0.15),
      child: fallback,
    );
  }
  final safeUserId = account.userid.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
  return CircleAvatar(
    radius: 20,
    backgroundColor: cs.primary.withValues(alpha: 0.15),
    child: ClipOval(
      child: CachedNetworkImage(
        imageUrl: avatarUrl,
        memCacheWidth: 96,
        memCacheHeight: 96,
        cacheKey: 'avatar_$safeUserId',
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorWidget: (c, u, e) => fallback,
      ),
    ),
  );
}

/// 切换账号（确认 → 切换 + 过期检测 → 重载收藏 → 关闭面板）
Future<void> _switchToAccount(
  BuildContext context,
  KugouAccount account,
) async {
  final kugou = context.read<KugouProvider>();
  final navigator = Navigator.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('切换账号'),
      content: Text('切换到「${account.nickname ?? account.userid}」？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('切换'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final result = await kugou.switchAccount(account.userid);
  if (!context.mounted) return;
  switch (result) {
    case SwitchAccountResult.success:
      navigator.pop(); // 关闭账号管理面板
      context.read<FavoritesProvider>().loadFavorites();
      showToast('已切换到 ${account.nickname ?? account.userid}', long: true);
    case SwitchAccountResult.tokenExpired:
      // 凭证已切换但登录态过期：引导重新登录或删除该账号
      navigator.pop();
      await _handleExpiredAccount(context, account);
    case SwitchAccountResult.noCredentials:
      showToast('切换失败，该账号凭证已失效', long: true);
  }
}

/// 账号登录态已过期：提示并引导重新登录 / 删除该账号。
Future<void> _handleExpiredAccount(
  BuildContext context,
  KugouAccount account,
) async {
  final kugou = context.read<KugouProvider>();
  if (!context.mounted) return;
  final navigator = Navigator.of(context);
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('登录已过期'),
      content: Text(
        '「${account.nickname ?? account.userid}」的登录状态已过期，'
        '需重新登录后才能使用该账号。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'remove'),
          child: const Text('删除该账号'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'relogin'),
          child: const Text('重新登录'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;

  switch (action) {
    case 'relogin':
      // 重新登录：登录成功后 setLoginCookies 会清除该账号的过期标记
      await navigator.push(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    case 'remove':
      await kugou.removeAccount(account.userid);
      if (!context.mounted) return;
      context.read<FavoritesProvider>().loadFavorites();
      showToast('已删除过期账号', long: true);
  }
}

/// 删除账号（确认 → 删除 → 若为当前账号则重载收藏 → 关闭面板）
Future<void> _confirmRemoveAccount(
  BuildContext context,
  KugouAccount account,
) async {
  final kugou = context.read<KugouProvider>();
  final isCurrent = account.userid == kugou.userid;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除账号'),
      content: Text(
        isCurrent
            ? '将删除当前账号并退出登录（若有其他账号会自动切换）。确定？'
            : '确定删除该账号？其登录态将被清除。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  await kugou.removeAccount(account.userid);
  if (!context.mounted) return;
  if (isCurrent) {
    context.read<FavoritesProvider>().loadFavorites();
  }
  Navigator.of(context).pop(); // 关闭账号管理面板
  showToast('已删除账号 ${account.nickname ?? account.userid}', long: true);
}
