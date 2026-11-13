// 批次58d：启动自动检查发现新版本时的弹窗组件与红点判定。
//
// 职责边界：只负责「确认式弹窗 + 设置页红点判定」的展示逻辑，
// 不做检查、不做下载；弹窗只在启动自动检查路径出现（设置页手动
// 检查有自己的流程弹窗，见 settings_page.dart）。
import 'package:flutter/material.dart';

import '../../bootstrap_common.dart' show appNavigatorKey;

/// 「检查更新」入口红点判定（确定性行为）：
/// [pendingIdentity] 非空且与 [currentVersion] 不匹配时显示红点。
///
/// 身份记法与 updateLastNotifiedVersion 一致：正式通道存 versionName
/// （形如 5.6.5），Beta 通道存快照 tag（形如 v5.9.27-lite-abc1234）。
/// Beta tag 含 versionName，故用包含关系判断：用户已更新到对应快照
/// （versionName 相同）即视为已处理；当前版本未知（空串）时宁可提示。
bool updateBadgeVisible({
  required String pendingIdentity,
  required String currentVersion,
}) {
  if (pendingIdentity.isEmpty) return false;
  if (currentVersion.isEmpty) return true;
  return !pendingIdentity.contains(currentVersion);
}

/// 启动自动检查发现新版本时的确认弹窗。
///
/// 标题「发现新版本」，正文带远端版本号与当前版本；「立即更新」关闭
/// 弹窗并跳转设置页（更新入口在「设置 → 关于」），「下次再说」仅关闭。
/// 经全局 [appNavigatorKey] showDialog；navigator 不可用（如无 UI 环境）
/// 时静默跳过，由调用方的 toast（notifier）兜底，行为退回纯 toast。
Future<void> showUpdateAvailablePrompt({
  required String remoteVersion,
  required String currentVersion,
}) async {
  final context = appNavigatorKey.currentContext;
  if (context == null) return;
  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('发现新版本'),
      content: Text(
        currentVersion.isEmpty
            ? '新版本 $remoteVersion 已发布，可前往「设置 → 关于」更新。'
            : '新版本 $remoteVersion 已发布（当前 $currentVersion），'
                '可前往「设置 → 关于」更新。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx),
          child: const Text('下次再说'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(dialogCtx);
            appNavigatorKey.currentState?.pushNamed('/settings');
          },
          child: const Text('立即更新'),
        ),
      ],
    ),
  );
}
