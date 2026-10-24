import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('提醒开关默认开启', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getUpdateReminderEnabled(), isTrue);
  });

  test('提醒开关写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setUpdateReminderEnabled(false);
    expect(await repo.getUpdateReminderEnabled(), isFalse);
  });

  test('上次检查时间为空时返回 0', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getUpdateLastCheckMs(), 0);
  });

  test('上次检查时间写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setUpdateLastCheckMs(1735660800000);
    expect(await repo.getUpdateLastCheckMs(), 1735660800000);
  });

  test('已提醒版本为空时返回空串', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getUpdateLastNotifiedVersion(), '');
  });

  test('已提醒版本写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setUpdateLastNotifiedVersion('5.6.5');
    expect(await repo.getUpdateLastNotifiedVersion(), '5.6.5');
  });

  // 批次34：切提醒开关同时清检查时间戳，避免 12h 窗口吞掉开关切换的即时生效
  test('开启提醒开关时清空上次检查时间', () async {
    SharedPreferences.setMockInitialValues({
      'settings_update_reminder_enabled': false,
      'update_last_check_ms': 1735660800000,
    });
    final repo = SettingsRepository();
    await repo.setUpdateReminderEnabled(true);
    expect(await repo.getUpdateReminderEnabled(), isTrue);
    expect(await repo.getUpdateLastCheckMs(), 0);
  });

  test('关闭提醒开关时也清空上次检查时间', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': 1735660800000,
    });
    final repo = SettingsRepository();
    await repo.setUpdateReminderEnabled(false);
    expect(await repo.getUpdateReminderEnabled(), isFalse);
    expect(await repo.getUpdateLastCheckMs(), 0);
  });

  // 批次34：Beta 通道开关（pre-release 更新源），默认关闭
  test('Beta 通道开关默认关闭', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsRepository().getBetaChannelEnabled(), isFalse);
  });

  test('Beta 通道开关写入后可读回', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.setBetaChannelEnabled(true);
    expect(await repo.getBetaChannelEnabled(), isTrue);
    await repo.setBetaChannelEnabled(false);
    expect(await repo.getBetaChannelEnabled(), isFalse);
  });
}
