import 'package:flutter/widgets.dart';

import '../build_flags.dart';

/// tv: m3e 弹层（bottom sheet / dialog 路由）打开后把首焦点交给 [targetNode]。
///
/// `autofocus` 在 m3e 弹层这种复用/延迟挂载的路由里不可靠（2026-10-05 真机
/// 实测：首项拿不到焦点，焦点反而落到评分更高的末行控件上），必须在弹层
/// 挂载后显式 `requestFocus` 一次。此前该逻辑只存在于 library_page 的私有
/// `_tvEnsureSheetFocus`，各弹层各自复制易漏——扫描文件夹 / 排除文件夹
/// 管理面板、云音乐上传菜单都漏了接线，TV 上打开后遥控器无任何落点。
///
/// 用法：包在弹层内容根节点外层，[targetNode] 挂到主动作控件（首停点）上：
///
/// ```dart
/// return TvSheetFocus(
///   targetNode: _addButtonNode,
///   child: SafeArea(child: ...),
/// );
/// ```
///
/// 每 build 都会尝试挂 post-frame 回调，但内部自锁只真正请求一次；若焦点
/// 已落在弹层子树内（用户已手动移动）则不抢。非 TV 构建原样返回 [child]，
/// 触屏 / 桌面零变化。
class TvSheetFocus extends StatefulWidget {
  const TvSheetFocus({
    super.key,
    required this.targetNode,
    required this.child,
  });

  /// 首焦点落点，须挂在弹层内某个 [DpadFocusable] / 控件上。
  final FocusNode targetNode;

  final Widget child;

  @override
  State<TvSheetFocus> createState() => _TvSheetFocusState();
}

class _TvSheetFocusState extends State<TvSheetFocus> {
  /// 自锁：只真正请求一次，避免反复 requestFocus 打断用户后续移动。
  bool _requested = false;

  void _ensure() {
    if (!kTvBuild || _requested) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_requested) return;
      _requested = true;
      final target = widget.targetNode;
      if (!target.canRequestFocus) return;
      if (target.context == null || !target.context!.mounted) return;
      // 「弹层内是否已有人持焦」必须按子树归属判断，不能只看
      // primaryFocus.hasFocus：弹层打开瞬间焦点从页面移交到弹层路由是
      // 异步的，此刻 primaryFocus 仍是页面里的节点（如扫描 FAB）且
      // hasFocus == true，按 hasFocus 判会把首项焦点整个吞掉。
      final primary = FocusManager.instance.primaryFocus?.context;
      if (primary != null) {
        final sheet = context as Element;
        var inside = false;
        primary.visitAncestorElements((el) {
          if (identical(el, sheet)) {
            inside = true;
            return false;
          }
          return true;
        });
        // 焦点已在弹层子树内（用户已手动移动）就不抢；仍在页面旧位置
        // （打开瞬间的正常状态）则移交。
        if (inside) return;
      }
      target.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    _ensure();
    return widget.child;
  }
}
