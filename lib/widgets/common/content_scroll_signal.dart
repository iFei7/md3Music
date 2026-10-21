import 'package:material_ui/material_ui.dart';

/// 内层滚动信号泵：把子树内**纵向滚动列表**的「已离开顶部」状态写入
/// [signal]，供宿主注入 [SonifyTitleScaffold.actionsVisible] /
/// [SonifyTitleScaffold.barBackgroundVisible]。
///
/// 批次 24 背景：主页管理里多数 tab 页（音乐库 hub / 我的收藏 / FM /
/// 识曲 / 播放历史 / 设置总览）外层骨架是「单固定高 item」结构，骨架
/// 自身最多橡皮筋滚动一个标题区高度，**内层列表滚动时骨架 offset 恒为
/// 0**——于是这些页的顶栏渐变模糊带永不浮现、依赖滚动浮现的动作钮
/// 也不出现，与首页「滚动即出带」不一致（用户反馈：tab 页顶栏背景不
/// 一致）。
///
/// 用法（页面持有一个 `ValueNotifier<bool>`，把它同时传给骨架的
/// `barBackgroundVisible` / `actionsVisible`，再用本组件包住业务区）：
/// ```dart
/// final ValueNotifier<bool> _scrolled = ValueNotifier(false);
/// // build:
/// ContentScrollSignal(
///   signal: _scrolled,
///   child: SizedBox(height: fixed, child: 业务区),
/// )
/// ```
///
/// 过滤规则：只认 `axis == vertical` 的 ScrollUpdate/End 通知（TabBarView
/// 自身 PageView 的横滑通知轴为水平，天然排除；嵌套列表的 `depth > 0`
/// 不是必须条件——外层骨架的通知由骨架自己的监听器处理，不会冒泡到本
/// 组件内部，见 [ScrollNotification] 的冒泡方向）。列表回顶
/// （pixels <= 0，含顶部橡皮筋负数）时信号复位为 false。
class ContentScrollSignal extends StatelessWidget {
  const ContentScrollSignal({
    super.key,
    required this.signal,
    required this.child,
  });

  /// 「已离开顶部」信号（true = 浮现）。生命周期归宿主页面。
  final ValueNotifier<bool> signal;

  /// 业务区子树（通常为固定高的 item 内容）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification ||
            notification is ScrollEndNotification) {
          final scrolled =
              notification.metrics.axis == Axis.vertical &&
              notification.metrics.pixels > 0;
          if (signal.value != scrolled) signal.value = scrolled;
        }
        return false;
      },
      child: child,
    );
  }
}
