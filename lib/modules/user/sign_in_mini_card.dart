import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/kugou_provider.dart';
import '../login/login_page.dart';
import 'sign_in_calendar_page.dart';

/// 设置页签到迷你卡：账号卡下方的紧凑签到入口。
///
/// 白卡 squircle 9dp（风格同账号卡）：标题行（签到 + 本月已签 N 天）
/// + 主按钮「签到」。整卡点击进入 [SignInCalendarPage]（完整月历 /
/// 签到 / 听歌领取 / 广告领取 / 验证码流程都在那一页）。
///
/// 数据面（Selector 最小重建，选择面 `(本月已签天数, 今日是否已签,
/// 签到中, 是否登录)`）：
/// - 已签日期：服务端 [KugouProvider.vipMonthRecord]（仅概念版 svip 记录）
///   合并本地兜底 [KugouProvider.localSignedDays]（按 userid 隔离）；
/// - 今日已签：[KugouProvider.hasSignedToday]（签到语义，与概念版徽章
///   [KugouProvider.isTodayYouthVip] 解耦）；
/// - 签到中：[KugouProvider.manualSignInRunning]（provider 侧防重入）；
/// - 是否登录：[KugouProvider.isLoggedIn]（未登录按钮引导去登录页）。
class SignInMiniCard extends StatefulWidget {
  const SignInMiniCard({super.key});

  @override
  State<SignInMiniCard> createState() => _SignInMiniCardState();
}

class _SignInMiniCardState extends State<SignInMiniCard> {
  /// provider 引用：initState 时取一次，监听注册/移除都走它，
  /// 避免在 dispose 里再走 context。
  late final KugouProvider _kugou;

  /// 本卡发起的签到是否仍在进行（用于验证码委托判定，见 _onProviderChanged）。
  bool _awaitingSignIn = false;

  /// 验证码委托去重：一次签到只跳转一次签到日历页。
  bool _captchaDelegated = false;

  @override
  void initState() {
    super.initState();
    _kugou = context.read<KugouProvider>();
    // 20028 二次安全验证委托：迷你卡不内置滑块验证码弹窗，
    // 见 _onProviderChanged
    _kugou.addListener(_onProviderChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 进入设置页时补拉一次服务端打卡记录（本地兜底之外以服务端为准）
      if (_kugou.isLoggedIn) _kugou.getVipMonthRecord();
    });
  }

  @override
  void dispose() {
    _kugou.removeListener(_onProviderChanged);
    super.dispose();
  }

  /// 监听 20028 验证码请求：仅当验证码由本卡发起的签到触发时，
  /// 跳转签到日历页处理（该页实现了完整的腾讯滑块验证码弹窗流程）；
  /// 若用户已在签到日历页内签到，则由该页自行处理，本卡不重复跳转。
  void _onProviderChanged() {
    if (!mounted || _captchaDelegated) return;
    if (!_awaitingSignIn) return;
    if (_kugou.pendingVerifyCaptcha == null) return;
    _captchaDelegated = true;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SignInCalendarPage()),
    );
  }

  /// 进入签到日历页（整卡点击与「今日已签到」按钮共用同一跳转路径）。
  void _openSignInCalendar() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SignInCalendarPage()),
    );
  }

  /// 未登录点击签到按钮：提示后进入登录页（与全站其它未登录入口一致）。
  void _onLoginRequired() {
    showToast('请先登录后再签到');
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  /// 签到按钮点击：调 provider 手动签到（防重入由 manualSignInRunning +
  /// 按钮禁用双重保证），完成后 SnackBar 反馈。
  /// 本地已签标记与服务端记录刷新由 provider 内部完成（_markSignedToday /
  /// getVipMonthRecord），此处无需重复调用。
  Future<void> _onSignIn() async {
    final kugou = context.read<KugouProvider>();
    // 未登录守卫：按钮态已前置拦截，这里兜底避免直接调用 provider 只拿到失败文案
    if (!kugou.isLoggedIn) {
      showToast('请先登录后再签到');
      return;
    }
    _awaitingSignIn = true;
    // 每次发起签到都重置委托去重：本次若再遇验证码仍可跳转一次
    _captchaDelegated = false;
    final (_, msg) = await kugou.manualSignIn();
    _awaitingSignIn = false;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      showToast(msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SonifySpacing.cardMargin,
        AppSpacing.sm,
        SonifySpacing.cardMargin,
        0,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: sonify.surfaceCard,
          shape: SmoothRectangleBorder(
            borderRadius: BorderRadius.circular(SonifyRadius.card),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            // 整卡进入签到日历页（按钮区域由按钮自身消费手势，不冒泡）
            onTap: _openSignInCalendar,
            borderRadius: BorderRadius.circular(SonifyRadius.card),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              child: Selector<KugouProvider, (int, bool, bool, bool)>(
                selector: (_, kugou) => (
                  _currentMonthSignedDays(kugou).length,
                  kugou.hasSignedToday,
                  kugou.manualSignInRunning,
                  kugou.isLoggedIn,
                ),
                builder: (context, state, _) {
                  final (signedCount, todaySigned, running, loggedIn) = state;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(sonify, colorScheme, signedCount),
                      const Gap(AppSpacing.sm),
                      _buildSignInButton(
                        colorScheme,
                        running: running,
                        todaySigned: todaySigned,
                        loggedIn: loggedIn,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 标题行：图标 + 「签到」+ 右侧「本月已签 N 天」。
  Widget _buildHeader(
    SonifyColors sonify,
    ColorScheme colorScheme,
    int signedCount,
  ) {
    return Row(
      children: [
        Icon(Icons.event_available, size: 18, color: colorScheme.primary),
        const Gap(AppSpacing.sm),
        Text(
          '签到',
          style: SonifyTextStyles.cardTitle.copyWith(
            color: colorScheme.onSurface,
          ),
        ),
        const Spacer(),
        Text(
          '本月已签 $signedCount 天',
          style: SonifyTextStyles.listItem.copyWith(
            color: sonify.textSecondary,
          ),
        ),
      ],
    );
  }

  /// 签到主按钮四态：
  /// - 签到中 → loading + 禁用；
  /// - 未登录 → 「登录后签到」可点，进登录页；
  /// - 今日已签 → 「今日已签到」可点，进签到日历看记录；
  /// - 未签 → 「签到」。
  Widget _buildSignInButton(
    ColorScheme colorScheme, {
    required bool running,
    required bool todaySigned,
    required bool loggedIn,
  }) {
    final VoidCallback? onPressed;
    final Widget icon;
    final String label;
    if (running) {
      onPressed = null;
      icon = M3ELoadingIndicator(
        constraints: BoxConstraints.tightFor(width: 16, height: 16),
        color: colorScheme.onSecondaryContainer,
      );
      label = '签到中';
    } else if (!loggedIn) {
      onPressed = _onLoginRequired;
      icon = const Icon(Icons.login, size: 16);
      label = '登录后签到';
    } else if (todaySigned) {
      onPressed = _openSignInCalendar;
      icon = const Icon(Icons.check_circle, size: 16);
      label = '今日已签到';
    } else {
      onPressed = _onSignIn;
      icon = const Icon(Icons.check_circle_outline, size: 16);
      label = '签到';
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonalIcon(
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 6,
          ),
          minimumSize: const Size(0, 32),
        ),
        onPressed: onPressed,
        icon: icon,
        label: Text(label),
      ),
    );
  }
}

/// 合并服务端签到记录与本地兜底记录，得到「本月已签日期」集合。
///
/// 服务端记录只取概念版（svip）条目（与 SignInCalendarPage 口径一致）；
/// 本地 [KugouProvider.localSignedDays] 按 userid 隔离、跨天自动失效判定
/// 由 provider 负责，这里仅做当月过滤合并。
Set<int> _currentMonthSignedDays(KugouProvider kugou) {
  final now = DateTime.now();
  final days = <int>{};
  final record = kugou.vipMonthRecord;
  if (record != null) {
    final data = record['data'] as Map<String, dynamic>?;
    final list = data?['list'] ?? data?['record_list'] ?? record['list'];
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          // 只显示概念版(svip)签到记录，过滤畅听(tvip)
          final vipType = item['vip_type']?.toString() ?? '';
          if (vipType != 'svip') continue;
          final day = _parseReceivedDay(item['day']);
          if (day != null &&
              day.year == now.year &&
              day.month == now.month) {
            days.add(day.day);
          }
        }
      }
    }
  }
  // 本地兜底：服务端记录不及时时，合并本地已签日期，保证今天立即打点
  for (final key in kugou.localSignedDays) {
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(key);
    if (m != null &&
        int.parse(m.group(1)!) == now.year &&
        int.parse(m.group(2)!) == now.month) {
      days.add(int.parse(m.group(3)!));
    }
  }
  return days;
}

/// 解析服务端打卡条目日期：'yyyy-MM-dd' 字符串或 epoch 秒/毫秒。
DateTime? _parseReceivedDay(dynamic day) {
  if (day is String) {
    final m = RegExp(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(day);
    if (m != null) {
      return DateTime(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
      );
    }
  }
  if (day is int && day > 1000000000) {
    final ms = day > 1e12 ? day : day * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  return null;
}
