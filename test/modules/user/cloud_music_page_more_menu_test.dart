/// 云盘音乐页 more 钮删除入口测试（D）。
///
/// 背景：SongListItem.onMoreTap 死线修复前，本页传入的
/// `onMoreTap: _showSongMoreMenu`（含「删除」+ 确认框 + _deleteCloudSongs）
/// 从不生效；修复后自动接通。本用例验证该链路：more 钮 → 含「删除」
/// 的菜单 → 确认框 → 删除成功（stub 返回 status 1）→ 列表刷新。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/user/cloud_music_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 云盘列表 stub adapter：/user/cloud 返回一首云盘歌曲；
/// /user/cloud/del 返回 status==1（删除成功）；其余路径空响应。
/// 记录请求次数供「删除后刷新列表」断言。
class _CloudStubAdapter implements HttpClientAdapter {
  final Map<String, int> callCounts = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCounts[options.path] = (callCounts[options.path] ?? 0) + 1;
    if (options.path.contains('/user/cloud/del')) {
      return ResponseBody.fromString(
        jsonEncode({'status': 1}),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.path.contains('/user/cloud')) {
      return ResponseBody.fromString(
        jsonEncode({
          'data': {
            'info': [
              {
                'hash': 'cloud-hash-1',
                'songname': '云盘歌曲甲',
                'singername': '云盘歌手',
                'duration': 180,
                'kv_id': '901',
                'album_audio_id': '777',
              },
            ],
          },
        }),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// mock fluttertoast 插件通道：删除成功提示走 showToast。
void _mockFlutterToast() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const services.MethodChannel('PonnamKarthik/fluttertoast'),
    (call) async => true,
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('more 钮弹出含「删除」的菜单，确认后删除并刷新列表', (tester) async {
    // KugouApiClient 单例构造前必须 setMockInitialValues（任务约束）
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final adapter = _CloudStubAdapter();
    final client = KugouApiClient();
    client.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
    await client.setLoginCookies('test-token', 'test-uid');
    _mockFlutterToast();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => PlayerProvider()),
          ChangeNotifierProvider(create: (_) => LibraryProvider()),
          ChangeNotifierProvider(
            create: (_) => FavoritesProvider(syncOnStart: false),
          ),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ],
        child: const MaterialApp(home: CloudMusicPage()),
      ),
    );
    await _settle(tester);

    // 列表渲染（云盘歌曲来自 stub）
    expect(find.text('云盘歌曲甲'), findsOneWidget);
    final initialCloudCalls =
        adapter.callCounts['/user/cloud'] ?? 0;
    expect(initialCloudCalls, greaterThanOrEqualTo(1));

    // more 钮 → 单曲菜单（含「删除」）
    // 注意：M3E 弹层入场是弹簧动画（内容初帧在视口下方），必须
    // pumpAndSettle 落位后再 tap，否则点击坐标落在视口外（miss）。
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);

    // 「删除」→ 确认框
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除这首歌曲？'), findsOneWidget);

    // 确认删除：_deleteCloudSongs（stub status=1）→ 刷新列表
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('删除'),
    ));
    await _settle(tester);

    // 删除请求已发出且列表已刷新（getUserCloud 再次调用）
    expect(adapter.callCounts['/user/cloud/del'], 1);
    expect(
      adapter.callCounts['/user/cloud']!,
      greaterThan(initialCloudCalls),
      reason: '删除成功后云盘列表刷新（onMoreTap 链路自动生效）',
    );
    expect(tester.takeException(), isNull);

    // 「已删除 N 首」的 showToast 1s 计时器需跑完，避免测试收尾时
    // "A Timer is still pending"（同仓库既有测试口径）
    await tester.pump(const Duration(seconds: 2));

    // 清理登录态，避免污染同文件后续用例
    await client.clearCookies();
    uninstallFakeSecureStorage();
  });
}
