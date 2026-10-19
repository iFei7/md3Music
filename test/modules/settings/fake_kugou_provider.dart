import 'package:md3music/data/models/kugou_account.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 设置页卡片类测试（账号卡 / 签到迷你卡）共用的 [KugouProvider] 替身。
///
/// 只覆盖被测 getter 与「手动签到」入口；基类构造走
/// `registerDeviceOnStart: false`，不触发启动期网络请求。
/// 可变字段供测试在运行中改状态后调 `notifyListeners()`（继承自
/// ChangeNotifier）验证 Selector 重建路径。
class FakeKugouProvider extends KugouProvider {
  FakeKugouProvider({
    bool loggedIn = false,
    KugouUserDetail? userInfo,
    KugouGradeInfo? gradeInfo,
    List<KugouAccount> savedAccounts = const [],
    Set<String> localSignedDays = const {},
    bool todaySigned = false,
    bool signInRunning = false,
    Map<String, dynamic>? vipMonthRecord,
    (bool, String) signInResult = (true, '签到成功（概念版会员）'),
  }) : _loggedIn = loggedIn,
       _userInfo = userInfo,
       _gradeInfo = gradeInfo,
       _savedAccounts = savedAccounts,
       _localSignedDays = localSignedDays,
       _todaySigned = todaySigned,
       _signInRunning = signInRunning,
       _vipMonthRecord = vipMonthRecord,
       _signInResult = signInResult,
       super(registerDeviceOnStart: false);

  bool _loggedIn;
  KugouUserDetail? _userInfo;
  KugouGradeInfo? _gradeInfo;
  List<KugouAccount> _savedAccounts;
  Set<String> _localSignedDays;
  bool _todaySigned;
  bool _signInRunning;
  Map<String, dynamic>? _vipMonthRecord;
  (bool, String) _signInResult;

  /// manualSignIn 被调用次数（断言入口生效 / 防重入）。
  int manualSignInCalls = 0;

  @override
  bool get isLoggedIn => _loggedIn;

  @override
  KugouUserDetail? get userInfo => _userInfo;

  @override
  KugouGradeInfo? get gradeInfo => _gradeInfo;

  @override
  List<KugouAccount> get savedAccounts => _savedAccounts;

  @override
  Set<String> get localSignedDays => _localSignedDays;

  @override
  bool get isTodayYouthVip => _todaySigned;

  @override
  bool get manualSignInRunning => _signInRunning;

  @override
  Map<String, dynamic>? get vipMonthRecord => _vipMonthRecord;

  @override
  Future<void> getVipMonthRecord() async {}

  @override
  Future<(bool, String)> manualSignIn() async {
    manualSignInCalls++;
    return _signInResult;
  }
}
