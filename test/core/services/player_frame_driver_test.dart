import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/player_frame_driver.dart';

void main() {
  setUp(() {
    // 每个用例都从 60fps 起步，防止上一用例留下的档位影响本用例时长
    PlayerFrameDriver.instance.setFrameRate(PlayerFrameDriver.kFrameRateHigh);
  });

  tearDown(() {
    // 必须复位：step 是全局静态，30fps 会污染后续用例与其他测试文件
    PlayerFrameDriver.instance.setFrameRate(PlayerFrameDriver.kFrameRateHigh);
    expect(
      PlayerFrameDriver.instance.frameRate,
      PlayerFrameDriver.kFrameRateHigh,
    );
  });

  test('同一帧中被其他回调移除的订阅者不会再收到回调', () async {
    final driver = PlayerFrameDriver.instance;
    var removedCallbackCount = 0;
    void removeLater() => removedCallbackCount++;
    void remover() => driver.removeListener(removeLater);

    driver.addListener(remover);
    driver.addListener(removeLater);
    try {
      await Future<void>.delayed(PlayerFrameDriver.step * 2);
      expect(removedCallbackCount, 0);
    } finally {
      driver.removeListener(remover);
      driver.removeListener(removeLater);
    }
  });

  test('重复 addListener 同一回调只收到一次回调', () async {
    final driver = PlayerFrameDriver.instance;
    var callbackCount = 0;
    void listener() => callbackCount++;

    driver.addListener(listener);
    driver.addListener(listener);
    try {
      final int tickBefore = driver.tickCount;
      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      final int ticks = driver.tickCount - tickBefore;
      expect(ticks, greaterThan(0));
      // 每拍只会回调一次，重复订阅不会放大回调次数
      expect(callbackCount, equals(ticks));
    } finally {
      driver.removeListener(listener);
    }
  });

  test('最后一个订阅者退订后停止计时（tickCount 不再增长）', () async {
    final driver = PlayerFrameDriver.instance;
    void listener() {}

    driver.addListener(listener);
    try {
      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      expect(driver.tickCount, greaterThan(0));
    } finally {
      driver.removeListener(listener);
    }
    expect(driver.hasListeners, isFalse);

    final int tickAfterRemoval = driver.tickCount;
    await Future<void>.delayed(PlayerFrameDriver.step * 3);
    expect(driver.tickCount, equals(tickAfterRemoval));
  });

  test('setAppSuspended(true) 后停止计时', () async {
    final driver = PlayerFrameDriver.instance;
    void listener() {}

    driver.addListener(listener);
    try {
      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      expect(driver.isAppSuspended, isFalse);
      driver.setAppSuspended(true);
      expect(driver.isAppSuspended, isTrue);

      final int tickAtSuspend = driver.tickCount;
      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      expect(driver.tickCount, equals(tickAtSuspend));
    } finally {
      driver.setAppSuspended(false);
      driver.removeListener(listener);
    }
  });

  test('挂起期间新增订阅者不会启动计时器（tickCount 不增长）', () async {
    final driver = PlayerFrameDriver.instance;
    void listener() {}

    driver.setAppSuspended(true);
    try {
      driver.addListener(listener);
      expect(driver.hasListeners, isTrue);

      final int tickAtSuspend = driver.tickCount;
      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      expect(driver.tickCount, equals(tickAtSuspend));
    } finally {
      driver.setAppSuspended(false);
      driver.removeListener(listener);
    }
  });

  test('恢复后既有订阅者继续收到回调', () async {
    final driver = PlayerFrameDriver.instance;
    var callbackCount = 0;
    void listener() => callbackCount++;

    driver.addListener(listener);
    try {
      driver.setAppSuspended(true);
      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      final int callbackAtSuspend = callbackCount;

      driver.setAppSuspended(false);
      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      expect(callbackCount, greaterThan(callbackAtSuspend));
    } finally {
      driver.setAppSuspended(false);
      driver.removeListener(listener);
    }
  });

  test('重复设置相同的挂起值不会启动第二个定时器（每拍仅一次回调）', () async {
    final driver = PlayerFrameDriver.instance;
    var callbackCount = 0;
    void listener() => callbackCount++;

    driver.addListener(listener);
    try {
      // 值未变化时应直接返回，不重排定时器
      driver.setAppSuspended(false);
      driver.setAppSuspended(false);

      final int tickBefore = driver.tickCount;
      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      final int ticks = driver.tickCount - tickBefore;
      expect(ticks, greaterThan(0));
      expect(callbackCount, equals(ticks));
    } finally {
      driver.setAppSuspended(false);
      driver.removeListener(listener);
    }
  });

  test('setFrameRate(30) 后步进落在 33ms 量级且读回 30fps', () {
    final driver = PlayerFrameDriver.instance;

    driver.setFrameRate(PlayerFrameDriver.kFrameRateLow);

    expect(driver.frameRate, 30);
    expect(PlayerFrameDriver.step.inMilliseconds, inInclusiveRange(32, 34));
    expect(PlayerFrameDriver.step.inMicroseconds, inInclusiveRange(32000, 34600));
  });

  test('setFrameRate(60) 后步进恢复到 16ms 量级', () {
    final driver = PlayerFrameDriver.instance;

    driver.setFrameRate(PlayerFrameDriver.kFrameRateLow);
    expect(driver.frameRate, 30);

    driver.setFrameRate(PlayerFrameDriver.kFrameRateHigh);

    expect(driver.frameRate, 60);
    expect(PlayerFrameDriver.step.inMilliseconds, inInclusiveRange(16, 17));
    expect(PlayerFrameDriver.step.inMicroseconds, lessThan(18000));
  });

  test('非法/中间值归一化到 30 或 60，且不会出现 0 或除零', () {
    final driver = PlayerFrameDriver.instance;

    // 中间值 45 → 30，59 → 60
    driver.setFrameRate(45);
    expect(driver.frameRate, 30);
    driver.setFrameRate(59);
    expect(driver.frameRate, 60);

    // 极端值不得产生 0 周期（否则 frameRate 会除零）
    driver.setFrameRate(0);
    expect(driver.frameRate, 30);
    expect(PlayerFrameDriver.step.inMicroseconds, greaterThan(0));
    driver.setFrameRate(-1);
    expect(driver.frameRate, 30);
    driver.setFrameRate(1000);
    expect(driver.frameRate, 60);
    expect(PlayerFrameDriver.step.inMicroseconds, greaterThan(0));
  });

  test('运行中改帧率会重建定时器并继续出拍', () async {
    final driver = PlayerFrameDriver.instance;
    var callbackCount = 0;
    void listener() => callbackCount++;

    driver.addListener(listener);
    try {
      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      final int tickBefore = driver.tickCount;
      final int callbackBefore = callbackCount;

      driver.setFrameRate(PlayerFrameDriver.kFrameRateLow);
      expect(driver.frameRate, 30);

      await Future<void>.delayed(PlayerFrameDriver.step * 3);
      final int tickAfter = driver.tickCount;
      // 定时器被重建后必须继续出拍，而不是停在旧周期上
      expect(tickAfter, greaterThan(tickBefore));
      expect(callbackCount, greaterThan(callbackBefore));
    } finally {
      driver.removeListener(listener);
    }
  });
}
