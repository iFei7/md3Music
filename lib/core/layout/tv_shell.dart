import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/tab_config_provider.dart';
import '../../tv/design/tv_design.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../build_flags.dart';
import 'tv_nav_focus_bridge.dart';

/// tv: lite 版 TV 主壳层——左侧玻璃导航 Rail + 右侧内容区（批次43）。
///
/// ## 结构
///
/// - **Rail**（宽 240 设计px，经 [TvLayoutScale] 换算）：悬浮在环境背景上的
///   **玻璃面板**（[LiquidGlassSurface]，fillAlpha≈0.12、blur σ=[tvBlurSigma]，
///   无实色底）——用户口径「空间 UI 用手机端半透明模糊玻璃设计语言」。
///   导航项 = 搜索 / 推荐 / 我的音乐 / 现场电台 / 其余可见 tab + **设置固定
///   追加在 Rail 末尾**（参照上游 tab_config_provider.dart 的 TV 强制追加
///   模式，在 shell 内处理、不动 provider）。顶部留登录/头像位（占位，
///   批次44 扫码）；底部留二维码入口占位（批次44 实装）。
/// - **内容区**：批次43 为占位（Center 显示当前 tab 名 + 「TV 内容流批次44」），
///   外层 [DpadRegion]（memoryKey `'tv_content'`）。批次44 接入真实内容流。
/// - **焦点桥**：Rail 项焦点节点登记到 [TvNavFocusBridge] 节点池——Rail 在
///   Navigator scope 之外，内容区 dpad 遍历的候选收集看不到它，必须显式桥接；
///   内容区 [DpadRegion] 左边缘 → [TvNavFocusBridge.focusNavItem]（当前 index），
///   Rail 项右方向键 → 内容区焦点节点。
///
/// ## 聚焦即选中
///
/// 参照上游 tv_shell.dart 的 TvTabBarItem 语义：方向键把焦点移到某导航项的
/// 瞬间即切换选中（无需 OK 确认），选中态 = 文字变白 + 玻璃底块 + 左侧品牌色
/// 指示条（120ms 淡入）。OK 键保留为兼容入口。
///
/// ## 选中状态
///
/// **TV 下 `_MainLayout` 不在树里，没人监听 `shortcutTabRequest`**，故本壳
/// 自持选中状态（内部 `ValueNotifier<int>`），切内容占位即可。批次44 内容流
/// 接入时统一到真实数据路由。
class TvMainShell extends StatefulWidget {
  const TvMainShell({super.key, required this.visibleTabs});

  /// 来自 `TabConfigProvider.visibleTabs` 的可见 tab 列表（不含设置——
  /// 设置由本壳固定追加在 Rail 末尾）。
  final List<TabItem> visibleTabs;

  @override
  State<TvMainShell> createState() => _TvMainShellState();
}

class _TvMainShellState extends State<TvMainShell> {
  /// 固定追加的设置项（TV：设置必须从 Rail 可达，用户不能隐藏）。
  static const TabItem _settingsTab = TabItem(id: 'settings', label: '设置');

  /// tv: Rail 导航项焦点节点池（每项 1 个，随本 State dispose）。
  /// 每次构建新建节点会逐帧泄漏，且选中态切换时节点身份变化会丢焦点，
  /// 必须池化复用（同上游 tv_shell 的 _tabNodes 口径）。
  final Map<int, FocusNode> _railNodes = <int, FocusNode>{};

  /// 内容区焦点节点：Rail 项右方向键 / 内容区左边缘桥接的落点。
  final FocusNode _contentNode = FocusNode(debugLabel: 'tv/content');

  /// 选中状态（自持，见类注释「选中状态」）。
  final ValueNotifier<int> _selectedIndex = ValueNotifier<int>(0);

  /// Rail 全部导航项（含固定追加的设置）。
  List<TabItem> get _items => [...widget.visibleTabs, _settingsTab];

  @override
  void dispose() {
    for (final FocusNode node in _railNodes.values) {
      node.dispose();
    }
    _railNodes.clear();
    _contentNode.dispose();
    _selectedIndex.dispose();
    super.dispose();
  }

  /// tab id → Rail 显示名（批次43 口径：搜索/推荐/我的音乐/现场电台，其余原名）。
  String _labelFor(TabItem tab) {
    switch (tab.id) {
      case 'search':
        return '搜索';
      case 'discover':
        return '推荐';
      case 'library':
        return '我的音乐';
      case 'fm':
        return '现场电台';
      default:
        return tab.label;
    }
  }

  /// tab id → Rail 图标（可选开启的非默认 tab 用占位图标）。
  IconData _iconFor(TabItem tab) {
    switch (tab.id) {
      case 'search':
        return Icons.search;
      case 'discover':
        return Icons.explore;
      case 'library':
        return Icons.library_music;
      case 'fm':
        return Icons.radio;
      case 'settings':
        return Icons.settings;
      default:
        return Icons.circle_outlined;
    }
  }

  FocusNode _railNodeFor(int index) {
    return _railNodes.putIfAbsent(
      index,
      () => FocusNode(debugLabel: 'tv/rail-$index'),
    );
  }

  /// 聚焦即选中：焦点到达第 [index] 项即切换选中（无需 OK）。
  void _select(int index) {
    if (_selectedIndex.value == index) return;
    _selectedIndex.value = index;
  }

  /// 把焦点交还内容区（Rail 项右方向键）。返回 true = 消费按键。
  bool _focusContent() {
    if (!_contentNode.canRequestFocus) return false;
    _contentNode.requestFocus();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // 设计稿像素 → 实际布局换算系数（契约见 tv_design.dart）。
    final double scale = TvLayoutScale.of(context);
    // 96/1920 比例安全区：Rail 与内容全部落入（10-foot 过扫描余量按设计稿
    // 等比换算，不写死 dp）。
    final double safeInset = 96 * scale;
    return Padding(
      padding: EdgeInsets.all(safeInset),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildRail(context, scale),
          SizedBox(width: 48 * scale),
          Expanded(child: _buildContent(context, scale)),
        ],
      ),
    );
  }

  // ── Rail ─────────────────────────────────────────────────

  Widget _buildRail(BuildContext context, double scale) {
    return SizedBox(
      width: 240 * scale,
      child: LiquidGlassSurface(
        // 玻璃材质：悬浮在环境背景上、无实色底。blur σ 经 tvBlurSigma
        // 钳制（TV 弱 GPU 上限 kTvMaxBlurSigma），fillAlpha 对齐手机端
        // 玻璃设计语言（0.12）。
        shape: GlassShape.roundedRect,
        borderRadius: 24 * scale,
        blurSigma: tvBlurSigma(18),
        fillAlpha: 0.12,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 20 * scale,
            vertical: 24 * scale,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 登录/头像位（占位，批次44 扫码登录接入）。
              _buildAccountPlaceholder(context, scale),
              SizedBox(height: 32 * scale),
              // 导航项（含固定追加的设置）。
              for (int i = 0; i < _items.length; i++) ...[
                _buildRailItem(context, i, scale),
                SizedBox(height: 12 * scale),
              ],
              const Spacer(),
              // 二维码入口占位（仅画小图标，批次44 实装——「我的音乐」
              // 项右上 80×80 设计px 命中区，先落在 Rail 底部）。
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 80 * scale,
                  height: 80 * scale,
                  child: Center(
                    child: Icon(
                      Icons.qr_code_2,
                      size: 24 * scale,
                      color: const Color(0xFF8E929E),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 登录/头像位（批次43 占位：画头像圈 + 「登录」字样，批次44 扫码）。
  Widget _buildAccountPlaceholder(BuildContext context, double scale) {
    return SizedBox(
      height: 64 * scale,
      child: Row(
        children: [
          CircleAvatar(
            radius: 20 * scale,
            backgroundColor: Colors.white.withValues(alpha: 0.10),
            child: Icon(
              Icons.person_outline,
              size: 24 * scale,
              color: const Color(0xFF8E929E),
            ),
          ),
          SizedBox(width: 12 * scale),
          Text(
            '登录',
            style: TextStyle(fontSize: 26 * scale, color: Color(0xFF8E929E)),
          ),
        ],
      ),
    );
  }

  /// Rail 导航项：图标 + 文字（26 设计px），常态 #8E929E；获焦（=选中）
  /// 白字 + 玻璃底块（200×64 圆角12）+ 左侧 4×32 品牌色指示条（120ms 淡入）。
  Widget _buildRailItem(BuildContext context, int index, double scale) {
    final TabItem tab = _items[index];
    return ValueListenableBuilder<int>(
      valueListenable: _selectedIndex,
      builder: (context, selected, _) {
        final bool isSelected = selected == index;
        // 焦点节点登记到桥接池：内容区左边缘按当前 index 移交焦点。
        final FocusNode node = _railNodeFor(index);
        TvNavFocusBridge.instance.register(index, node);
        return DpadFocusable(
          focusNode: node,
          autofocus: index == 0,
          debugLabel: 'tv/rail-item-${tab.id}',
          // 聚焦即选中（批次43 口径）：方向键移入即切换 tab，无需 OK。
          onFocusChange: (focused) {
            if (focused) _select(index);
          },
          // OK 键兼容入口（读屏/指针设备）：再次确认当前项。
          onSelect: () => _select(index),
          // 右方向键 → 内容区（Rail 在 Navigator scope 外，靠桥接落地）。
          onDirection: (direction) {
            if (direction == TraversalDirection.right) return _focusContent();
            return false;
          },
          child: Container(
            width: 200 * scale,
            height: 64 * scale,
            padding: EdgeInsets.symmetric(horizontal: 16 * scale),
            decoration: BoxDecoration(
              // 获焦玻璃底块：半透明白块叠在 Rail 玻璃面板上（无实色底）。
              color: isSelected
                  ? Colors.white.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12 * scale),
            ),
            child: Row(
              children: [
                // 左侧品牌色指示条：4×32 设计px，120ms 淡入。
                AnimatedOpacity(
                  opacity: isSelected ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: Container(
                    width: 4 * scale,
                    height: 32 * scale,
                    margin: EdgeInsets.only(right: 12 * scale),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(2 * scale),
                    ),
                  ),
                ),
                Icon(
                  _iconFor(tab),
                  size: 26 * scale,
                  color: isSelected ? Colors.white : const Color(0xFF8E929E),
                ),
                SizedBox(width: 12 * scale),
                Expanded(
                  child: Text(
                    _labelFor(tab),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 26 * scale,
                      color: isSelected
                          ? Colors.white
                          : const Color(0xFF8E929E),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── 内容区 ───────────────────────────────────────────────

  /// 内容区（批次43 占位）：DpadRegion(memoryKey 'tv_content')，左边缘
  /// 桥接回 Rail 当前项。批次44 在此接入真实内容流。
  Widget _buildContent(BuildContext context, double scale) {
    return DpadRegion(
      memoryKey: 'tv_content',
      // 左边缘 stop + onEdge：焦点到内容区左缘时显式移交回 Rail（内容区
      // 的 dpad 候选收集看不到 Navigator scope 外的 Rail 节点，必须桥接）。
      leftEdge: DpadEdgeBehavior.stop,
      onEdge: (direction) {
        if (direction == TraversalDirection.left) {
          TvNavFocusBridge.instance.focusNavItem(_selectedIndex.value);
        }
      },
      child: DpadFocusable(
        focusNode: _contentNode,
        debugLabel: 'tv/content-placeholder',
        child: ValueListenableBuilder<int>(
          valueListenable: _selectedIndex,
          builder: (context, index, _) {
            final String label = _labelFor(_items[index]);
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 48 * scale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 16 * scale),
                  Text(
                    'TV 内容流批次44',
                    style: TextStyle(
                      fontSize: 26 * scale,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// tv: TV 主壳宿主（无参包装，路由表 `'/'` 在 kTvBuild 分支挂载）。
///
/// 从 [TabConfigProvider] 读 visibleTabs 交给 [TvMainShell]；选中状态由
/// TvMainShell 自持（TV 下 `_MainLayout` 不在树里，没人监听
/// `shortcutTabRequest`，批次44 内容流接入时统一到真实数据）。
class TvMainShellHost extends StatelessWidget {
  const TvMainShellHost({super.key});

  @override
  Widget build(BuildContext context) {
    final List<TabItem> visibleTabs = context.watch<TabConfigProvider>()
        .visibleTabs;
    return TvLayoutScale(child: TvMainShell(visibleTabs: visibleTabs));
  }
}
