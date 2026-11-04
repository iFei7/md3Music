import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/display_refresh_service.dart';

/// 批次44：滑动期高刷服务的单元测试。
///
/// 全部用例都用 [DisplayRefreshService.debugChannelOverride] 注入假通道 +
/// [DisplayRefreshService.debugPlatformOverride] 把平台判定固定为 Android，
/// 因此可以在桌面宿主 / CI 上跑，不依赖真机与原生实现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = DisplayRefreshService.instance;
  final calls = <String>[];

  /// 安装假通道。`throwError` 非空时每次调用都抛出该异常（模拟缺插件）。
  void installChannel({double fps = 120.0, Object? throwError}) {
    DisplayRefreshService.debugChannelOverride = (method) async {
      calls.add(method);
      if (throwError != null) throw throwError;
      if (method == 'requestMax') return fps;
      return null;
    };
  }

  int countOf(String method) => calls.where((c) => c == method).length;

  setUp(() async {
    // 先复位上一个用例可能残留的高刷态 / 降级态，再清空调用记录
    await service.dispose();
    calls.clear();
    DisplayRefreshService.debugPlatformOverride = true;
    installChannel();
  });

  tearDown(() async {
    await service.dispose();
    DisplayRefreshService.debugChannelOverride = null;
    DisplayRefreshService.debugPlatformOverride = null;
  });

  test('滑动中连续 beginScroll 只请求一次 requestMax', () async {
    await service.beginScroll();
    await service.beginScroll();
    await service.beginScroll();

    expect(countOf('requestMax'), 1, reason: '首次请求后应处于高刷态，不再重复请求');
    expect(countOf('release'), 0, reason: '滑动过程中不应回落');
    expect(service.isHighRefreshActive, isTrue);
    expect(service.lastReportedMaxFps, 120.0);
  });

  test('700ms 内持续 beginScroll 不回落，超时后 release 一次', () {
    fakeAsync((async) {
      service.beginScroll();
      async.flushMicrotasks();

      // 每 300ms 一次滚动更新，累计 900ms：定时器被不断续命，不能释放
      for (var i = 0; i < 3; i++) {
        async.elapse(const Duration(milliseconds: 300));
        service.beginScroll();
        async.flushMicrotasks();
      }
      expect(countOf('requestMax'), 1);
      expect(countOf('release'), 0);
      expect(service.isHighRefreshActive, isTrue);

      // 距最后一次更新满 700ms → 回落
      async.elapse(const Duration(milliseconds: 700));
      async.flushMicrotasks();
      expect(countOf('release'), 1);
      expect(service.isHighRefreshActive, isFalse);

      service.dispose();
      async.flushMicrotasks();
    });
  });

  test('endScroll 后 700ms 才 release（不立即切换）', () {
    fakeAsync((async) {
      service.beginScroll();
      async.flushMicrotasks();
      service.endScroll();
      async.flushMicrotasks();

      async.elapse(const Duration(milliseconds: 699));
      expect(countOf('release'), 0, reason: '700ms 未到不应切换，避免短间隔抖动');

      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(countOf('release'), 1);
      expect(service.isHighRefreshActive, isFalse);

      service.dispose();
      async.flushMicrotasks();
    });
  });

  test('通道抛 MissingPluginException 后永久降级，不再重试', () async {
    installChannel(throwError: MissingPluginException('通道未注册'));
    await service.beginScroll();

    expect(service.isHighRefreshActive, isFalse);
    expect(countOf('requestMax'), 1);
    expect(service.lastReportedMaxFps, 0.0);

    final afterFailure = calls.length;
    await service.beginScroll();
    await service.beginScroll();
    // 计数不增长：说明降级后连通道都不再进（每帧重试会拖慢主线程）
    expect(calls.length, afterFailure);
    expect(service.isHighRefreshActive, isFalse);
  });

  test('通道抛 PlatformException 同样永久降级', () async {
    installChannel(throwError: PlatformException(code: 'UNSUPPORTED'));
    await service.beginScroll();
    expect(service.isHighRefreshActive, isFalse);

    final afterFailure = calls.length;
    await service.beginScroll();
    expect(calls.length, afterFailure);
  });

  test('原生返回 0（取不到最高刷新率）视为不支持', () async {
    installChannel(fps: 0);
    await service.beginScroll();
    expect(service.isHighRefreshActive, isFalse);
    expect(countOf('requestMax'), 1);

    final afterFailure = calls.length;
    await service.beginScroll();
    expect(calls.length, afterFailure);
  });

  test('非 Android 平台不调用通道', () async {
    DisplayRefreshService.debugPlatformOverride = false;
    await service.beginScroll();
    await service.endScroll();
    expect(calls, isEmpty);
    expect(service.isHighRefreshActive, isFalse);
  });

  test('dispose 在处于高刷态时释放一次，并复位状态', () async {
    await service.beginScroll();
    expect(service.isHighRefreshActive, isTrue);

    await service.dispose();
    expect(countOf('release'), 1);
    expect(service.isHighRefreshActive, isFalse);
    expect(service.lastReportedMaxFps, 0.0);
  });
}
