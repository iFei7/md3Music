/// SongListItem more 钮路由 + 本地歌曲「编辑歌曲信息」应用内编辑器测试。
///
/// 覆盖（批次：onMoreTap 死线修复 + 本地编辑闭环）：
/// 1. more 钮路由：传 `onMoreTap` 回调 → 调回调、内置菜单不开；
///    不传 → 内置更多菜单打开（修复前回调恒被内置菜单遮蔽）；
/// 2. 本地歌曲内置更多菜单：主入口「编辑歌曲信息」（应用内编辑器）
///    与第二项「用 Lyrico 编辑标签」并存；
/// 3. 编辑器保存：歌名/歌手/专辑写入 LibraryProvider（Selector 铁律：
///    列表整体换新实例）并持久化到 SharedPreferences 缓存；
/// 4. 编辑器校验：歌名为空 → Toast 拦截、不关闭、不保存。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/song_list_item.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地歌曲种子：有 localPath、非在线 → 命中内置菜单的本地分支
/// （「编辑歌曲信息」+「用 Lyrico 编辑标签」）。
Song _localSong({
  String id = 'local-1',
  String title = '本地歌曲甲',
  String artist = '本地歌手',
  String album = '本地专辑',
}) => Song(
  id: id,
  title: title,
  artist: artist,
  album: album,
  duration: const Duration(milliseconds: 180000),
  localPath: '/storage/emulated/0/Music/$id.mp3',
  isOnline: false,
);

/// mock fluttertoast 插件通道：编辑器校验/保存提示走 showToast，
/// 测试环境无插件宿主，必须拦截避免 MissingPluginException。
void _mockFlutterToast() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const services.MethodChannel('PonnamKarthik/fluttertoast'),
    (call) async => true,
  );
}

/// 多推几帧：让编辑器保存的异步持久化链走完（mock SharedPreferences
/// 即时完成，几帧足够）。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 打开内置更多菜单并等 M3E 入场弹簧完全落位。
///
/// M3EBottomSheet 入场是 200px 位移的弹簧动画（m3e_core），未落位时
/// 弹层下部位于视口外、tap 会 miss——必须 pumpAndSettle 再交互。
Future<void> _openMoreMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
}

/// 更多菜单内点「编辑歌曲信息」→ 应用内编辑器弹层落位。
Future<void> _openEditorFromMenu(WidgetTester tester) async {
  await tester.tap(find.text('编辑歌曲信息'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('more 钮路由：传 onMoreTap 回调 → 调回调，内置菜单不开',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _mockFlutterToast();
    var callbackCalls = 0;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => LibraryProvider()),
          ChangeNotifierProvider(create: (_) => PlayerProvider()),
          ChangeNotifierProvider(
            create: (_) => FavoritesProvider(syncOnStart: false),
          ),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SongListItem(
              song: _localSong(),
              onMoreTap: () => callbackCalls++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await _openMoreMenu(tester);

    // 回调被调用；内置菜单（「添加到歌单」等条目）没有打开
    expect(callbackCalls, 1);
    expect(find.text('添加到歌单'), findsNothing);
  });

  testWidgets('more 钮路由：不传 onMoreTap → 内置更多菜单打开',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _mockFlutterToast();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => LibraryProvider()),
          ChangeNotifierProvider(create: (_) => PlayerProvider()),
          ChangeNotifierProvider(
            create: (_) => FavoritesProvider(syncOnStart: false),
          ),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(body: SongListItem(song: _localSong())),
        ),
      ),
    );
    await tester.pump();

    await _openMoreMenu(tester);

    // 内置菜单条目在场（收藏 / 添加到歌单 / 下一首播放）
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('添加到歌单'), findsOneWidget);
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('本地歌曲更多菜单：「编辑歌曲信息」（应用内）+「用 Lyrico 编辑标签」并存',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _mockFlutterToast();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => LibraryProvider()),
          ChangeNotifierProvider(create: (_) => PlayerProvider()),
          ChangeNotifierProvider(
            create: (_) => FavoritesProvider(syncOnStart: false),
          ),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(body: SongListItem(song: _localSong())),
        ),
      ),
    );
    await tester.pump();

    await _openMoreMenu(tester);

    // 本地分支两个入口：应用内编辑器为主入口，Lyrico 为第二项
    expect(find.text('编辑歌曲信息'), findsOneWidget);
    expect(find.text('用 Lyrico 编辑标签'), findsOneWidget);
  });

  testWidgets('编辑器保存：标题改写 → provider 列表与 SharedPreferences 均更新',
      (tester) async {
    final song = _localSong();
    SharedPreferences.setMockInitialValues({
      'local_music_cached_songs': jsonEncode([song.toJson()]),
    });
    _mockFlutterToast();
    final library = LibraryProvider();
    await library.loadSavedSongs();
    expect(library.songs.single.title, '本地歌曲甲');

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider(create: (_) => PlayerProvider()),
          ChangeNotifierProvider(
            create: (_) => FavoritesProvider(syncOnStart: false),
          ),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(body: SongListItem(song: song)),
        ),
      ),
    );
    await tester.pump();

    // 更多菜单 → 「编辑歌曲信息」→ 应用内编辑器
    await _openMoreMenu(tester);
    await _openEditorFromMenu(tester);

    // 三个 TextField 预填当前值（歌曲名 / 歌手 / 专辑）
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, '本地歌曲甲');
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, '本地歌手');
    expect(tester.widget<TextField>(fields.at(2)).controller?.text, '本地专辑');

    // 改歌曲名 + 歌手，保存
    await tester.enterText(fields.at(0), '改后的歌名');
    await tester.enterText(fields.at(1), '改后的歌手');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await _settle(tester);

    // provider 内存态更新（Selector 铁律：列表整体换新实例）
    expect(library.songs.single.title, '改后的歌名');
    expect(library.songs.single.artist, '改后的歌手');
    expect(library.songs.single.album, '本地专辑', reason: '未改字段保持原值');
    // 持久化层同步更新（重装/重启后恢复的是编辑后的值）
    final prefs = await SharedPreferences.getInstance();
    final persisted = jsonDecode(
      prefs.getString(LocalMusicRepository.cachedSongsKeyForTest)!,
    ) as List<dynamic>;
    expect(persisted.single['title'], '改后的歌名');
    expect(persisted.single['artist'], '改后的歌手');

    // 编辑器已关闭（保存成功）
    expect(find.byType(TextField), findsNothing);

    // showToast 走 fluttertoast，内部 1s 计时器需在测试结束前跑完，
    // 否则 "A Timer is still pending" 断言失败（同仓库既有测试口径）。
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('编辑器校验：歌名为空 → Toast 拦截，不关闭不保存',
      (tester) async {
    final song = _localSong();
    SharedPreferences.setMockInitialValues({
      'local_music_cached_songs': jsonEncode([song.toJson()]),
    });
    _mockFlutterToast();
    final library = LibraryProvider();
    await library.loadSavedSongs();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider(create: (_) => PlayerProvider()),
          ChangeNotifierProvider(
            create: (_) => FavoritesProvider(syncOnStart: false),
          ),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(body: SongListItem(song: song)),
        ),
      ),
    );
    await tester.pump();

    await _openMoreMenu(tester);
    await _openEditorFromMenu(tester);

    // 清空歌曲名后点保存：被校验拦截
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await _settle(tester);

    // 编辑器未关闭、provider 未改动
    expect(find.byType(TextField), findsNWidgets(3));
    expect(library.songs.single.title, '本地歌曲甲');
    // 持久化也未改动
    final prefs = await SharedPreferences.getInstance();
    final persisted = jsonDecode(
      prefs.getString(LocalMusicRepository.cachedSongsKeyForTest)!,
    ) as List<dynamic>;
    expect(persisted.single['title'], '本地歌曲甲');

    // 校验 Toast 的 1s 计时器跑完（见上一用例同口径说明）
    await tester.pump(const Duration(seconds: 2));
  });
}
