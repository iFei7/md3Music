import 'package:material_ui/material_ui.dart';

import '../../modules/player/full_player_route.dart';

/// 悬浮 Dock 的「二级路由态」控制器（批次 24）。
///
/// 语义（用户口径）：二级 push 出来的页面**不显示悬浮导航，但显示悬浮
/// 播放器**（恒展开，见 [GlassDockPlayer.showNav]）；设置页
/// （`/settings` 路由）与完整播放页、DLNA 遥控页等沉浸式页面**两者都
/// 不显示**。一级 tab 页（主布局内）仍是「导航 + 播放器」完整 Dock
/// （由 `_MainLayout` 自己渲染）。
///
/// 实现要点：
/// - push 出来的路由是**整屏不透明**的，会连主布局带 Dock 一起盖住，
///   所以二级态的播放器不能放在主布局里，必须挂在
///   `MaterialApp.builder` 的 Stack（位于 Navigator **之上**）——与既有
///   的 `DlnaCastingOverlay` / `PlayerDragOverlay` 同一层；
/// - 「是否二级」用**栈顶之下是否还有路由**判定（栈深 >= 2）：
///   onboarding / 用户协议等首启路由是栈底唯一路由，天然不算二级；
/// - 栈重建不依赖「首路由一定回调 didPush」——Navigator 对 `home`
///   初始路由是否通知观察者并无契约，故 [SecondaryDockRouteObserver]
///   在每次回调里把 `previousRoute` 一并补录进栈（补齐栈底），保证
///   「一级 → push 二级」必然得到栈深 2；
/// - 排除项按路由身份判定：完整播放页是私有路由类
///   [DraggablePlayerRoute]（按类型排除）；`/settings` 与
///   `/dlna_remote` 是按名字排除的命名路由。
///
/// 只暴露一个布尔查询给 UI 层，build 侧据此渲染悬浮播放器 / 注入 Dock
/// 避让 padding。
class SecondaryDockController extends ChangeNotifier {
  SecondaryDockController();

  final List<Route<dynamic>> _stack = [];

  bool _visible = false;

  /// 二级态悬浮播放器是否可见（true = 当前应渲染仅播放器 Dock）。
  bool get visible => _visible;

  /// 应排除悬浮栏的路由名（设置页 / DLNA 遥控页）。
  static const Set<String> _excludedRouteNames = {'/settings', '/dlna_remote'};

  /// 把 [route] 补录进栈（已存在则忽略）。
  void _record(Route<dynamic>? route) {
    if (route == null) return;
    if (!_stack.contains(route)) _stack.add(route);
  }

  void _discard(Route<dynamic>? route) {
    if (route == null) return;
    final i = _stack.lastIndexOf(route);
    if (i >= 0) _stack.removeAt(i);
  }

  void _sync() {
    // 栈顶取最后一个 active 路由（pop 过渡期间旧路由尚未 dispose）；
    // 全部 inactive 时兜底取栈顶条目。
    Route<dynamic>? top;
    for (final r in _stack) {
      if (r.isActive) top = r;
    }
    top ??= _stack.isNotEmpty ? _stack.last : null;

    final isSecondary = _stack.length >= 2;
    final next = isSecondary && !_isExcluded(top);
    if (next != _visible) {
      _visible = next;
      notifyListeners();
    }
  }

  bool _isExcluded(Route<dynamic>? route) {
    if (route == null) return true;
    // 完整播放页本身就是播放器，不能再挂一份迷你播放器
    if (route is DraggablePlayerRoute) return true;
    return _excludedRouteNames.contains(route.settings.name);
  }

  /// push：先补录 `previousRoute`（栈底可能从未回调过 didPush，见类
  /// 文档），再录 [route]，保证「一级 → push 二级」得到栈深 2。
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record(previousRoute);
    _record(route);
    _sync();
  }

  /// pop：移除 [route]；回到的 `previousRoute` 若从未入栈则补录
  /// （此刻它成为栈顶）。
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _discard(route);
    _record(previousRoute);
    _sync();
  }

  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _discard(route);
    _record(previousRoute);
    _sync();
  }

  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      final i = _stack.lastIndexOf(oldRoute);
      if (i >= 0) {
        if (newRoute != null) {
          _stack[i] = newRoute;
        } else {
          _stack.removeAt(i);
        }
      } else {
        _record(newRoute);
      }
    }
    _sync();
  }

  @override
  void dispose() {
    _stack.clear();
    super.dispose();
  }
}

/// 把 [SecondaryDockController] 接成 [RouteObserver]。
///
/// 只观察 [PageRoute]：主布局 / 完整播放页 / 命名路由都是 PageRoute
/// 子类；匿名 `MaterialPageRoute`（详情页等绝大多数二级页）同样是。
class SecondaryDockRouteObserver extends RouteObserver<PageRoute<dynamic>> {
  SecondaryDockRouteObserver(this.controller);

  final SecondaryDockController controller;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    controller.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    controller.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    controller.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    controller.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}
