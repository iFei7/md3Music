import 'package:flutter/widgets.dart';

/// tv: → 迷你播放条的**焦点移交桥**（批次44 自上游
/// origin/rust-local-force 整搬；批次50 起 lite 自研顶栏（TvTopChrome /
/// TvMiniBar）删除、TV 渲染树切 tv_ui 体系，桥本身作为批次43 基础件保留，
/// 登记方为 tv_ui 的 MiniPlayer（tv_ui/modules/player/mini_player.dart，
/// 自带同款桥的自洽拷贝）——本文件当前无 lib 内消费者，留作基础件）。
///
/// ## 为什么是节点池
///
/// 迷你条移到顶部第一层后，桥的消费者从「内容区下边缘」变成「顶栏长按
/// 上键 / 第二层上边缘」。同一根桥上可能有多个登记者（主壳层顶栏常驻
/// 实例 + 二级路由自带的迷你条实例）。单节点会被后登记者覆盖，先登记者
/// 卸载时又被 `unregister` 清空——长按上键随即失效。
/// 故按登记顺序存池，取**最后可用的**（视觉最上层）节点。
///
/// 仅 TV 构建使用。
class TvPlayerBarFocusBridge {
  TvPlayerBarFocusBridge._();

  static final TvPlayerBarFocusBridge instance = TvPlayerBarFocusBridge._();

  /// 已登记的迷你播放器焦点节点（按登记顺序）。
  final List<FocusNode> _nodes = <FocusNode>[];

  /// 登记 [node]。重复登记幂等（FocusNode 的 == 是恒等）。
  void register(FocusNode node) {
    if (!_nodes.contains(node)) _nodes.add(node);
  }

  /// 撤销 [node] 的登记。
  void unregister(FocusNode node) {
    _nodes.remove(node);
  }

  /// 把焦点移交给最上层可用的迷你播放器。返回是否成功发出移交请求。
  ///
  /// [FocusNode.requestFocus] 异步生效，故只表示「请求已发出」。
  bool focusMiniPlayer() {
    for (final FocusNode node in _nodes.reversed) {
      if (!node.canRequestFocus) continue;
      if (node.hasFocus) return true;
      node.requestFocus();
      return true;
    }
    return false;
  }

  /// [node] 是否属于某个已登记的迷你播放器（焦点校正判定用）。
  bool isMiniNode(FocusNode node) {
    for (final FocusNode n in _nodes) {
      if (identical(n, node)) return true;
    }
    return false;
  }
}
