import 'package:material_ui/material_ui.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/kugou_provider.dart';
import 'sign_in_calendar_page.dart';

/// 设置页签到迷你日历卡：账号卡下方的紧凑签到入口。
///
/// 白卡 squircle 9dp（风格同账号卡）：标题行（签到日历 + 本月已签 N 天）
/// + 迷你月历点阵（周一起始，已签 primary 圆点 / 今天描边 / 未来置灰）
/// + 主按钮「签到」。整卡点击进入 [SignInCalendarPage]（完整签到 /
/// 听歌领取 / 广告领取 / 验证码流程都在那一页）。
///
/// 数据面（Selector 最小重建，选择面 `(本月已签天数, 今日是否已签, 签到中)`）：
/// - 已签日期：服务端 [KugouProvider.vipMonthRecord]（仅概念版 svip 记录）
///   合并本地兜底 [KugouProvider.localSignedDays]（按 userid 隔离）；
/// - 今日已签：[KugouProvider.isTodayYouthVip]；
/// - 签到中：[KugouProvider.manualSignInRunning]（provider 侧防重入）。
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

  /// 签到按钮点击：调 provider 手动签到（防重入由 manualSignInRunning +
  /// 按钮禁用双重保证），完成后 SnackBar 反馈。
  /// 本地已签标记与服务端记录刷新由 provider 内部完成（_markSignedToday /
  /// getVipMonthRecord），此处无需重复调用。
  Future<void> _onSignIn() async {
    final kugou = context.read<KugouProvider>();
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
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SignInCalendarPage()),
            ),
            borderRadius: BorderRadius.circular(SonifyRadius.card),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              child: Selector<KugouProvider, (int, bool, bool)>(
                selector: (_, kugou) => (
                  _currentMonthSignedDays(kugou).length,
                  kugou.isTodayYouthVip,
                  kugou.manualSignInRunning,
                ),
                builder: (context, state, _) {
                  final (signedCount, todaySigned, running) = state;
                  final signedDays = _currentMonthSignedDays(
                    context.read<KugouProvider>(),
                  );
                  final now = DateTime.now();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(sonify, colorScheme, signedCount),
                      const Gap(AppSpacing.sm),
                      _buildWeekdayHeader(colorScheme),
                      const Gap(2),
                      _buildDotGrid(colorScheme, signedDays, now),
                      const Gap(AppSpacing.sm),
                      _buildSignInButton(
                        colorScheme,
                        running: running,
                        todaySigned: todaySigned,
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

  /// 标题行：图标 + 「签到日历」+ 右侧「本月已签 N 天」。
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
          '签到日历',
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

  /// 周起始终止行（与月历点阵同构的 7 列）。
  Widget _buildWeekdayHeader(ColorScheme colorScheme) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    return Row(
      children: [
        for (final l in labels)
          Expanded(
            child: Center(
              child: Text(
                l,
                style: SonifyTextStyles.listItem.copyWith(
                  fontSize: 10,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 迷你月历点阵：周一开头；已签 = primary 实心圆点，
  /// 今天 = primary 描边，未来 = 置灰细边，过去未签 = 淡边。
  Widget _buildDotGrid(
    ColorScheme colorScheme,
    Set<int> signedDays,
    DateTime now,
  ) {
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    // weekday: Mon=1..Sun=7 → 周一开头，前导 (weekday-1) 个空位
    final leading = DateTime(now.year, now.month, 1).weekday - 1;

    final cells = <Widget>[
      for (var i = 0; i < leading; i++) const Expanded(child: SizedBox()),
      for (var day = 1; day <= daysInMonth; day++)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.5),
            child: Center(
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: signedDays.contains(day)
                      ? colorScheme.primary
                      : Colors.transparent,
                  border: signedDays.contains(day)
                      ? null
                      : Border.all(
                          color: day == now.day
                              ? colorScheme.primary
                              : (day > now.day
                                    ? colorScheme.onSurfaceVariant.withValues(
                                        alpha: 0.25,
                                      )
                                    : colorScheme.outlineVariant.withValues(
                                        alpha: 0.6,
                                      )),
                          width: day == now.day ? 1.5 : 1,
                        ),
                ),
              ),
            ),
          ),
        ),
    ];
    // 补齐整行（月历点阵按 7 列切行）
    while (cells.length % 7 != 0) {
      cells.add(const Expanded(child: SizedBox()));
    }

    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(Row(children: cells.sublist(i, i + 7)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  /// 签到主按钮：签到中 = loading 禁用；今日已签 = 「今日已签到」禁用。
  Widget _buildSignInButton(
    ColorScheme colorScheme, {
    required bool running,
    required bool todaySigned,
  }) {
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
        onPressed: (running || todaySigned) ? null : _onSignIn,
        icon: running
            ? M3ELoadingIndicator(
                constraints: BoxConstraints.tightFor(width: 16, height: 16),
                color: colorScheme.onSecondaryContainer,
              )
            : Icon(
                todaySigned ? Icons.check_circle : Icons.check_circle_outline,
                size: 16,
              ),
        label: Text(
          running ? '签到中' : (todaySigned ? '今日已签到' : '签到'),
        ),
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
