import 'package:flutter/foundation.dart';

/// 长按多选/批量操作的可复用控制器（方案 §4.1「抽公共 MultiSelectController」）。
///
/// 从歌单页（playlist_page.dart）既有多选逻辑抽取，语义逐项保持一致：
/// - [enterSelectMode]：长按进入多选，首个 item 自动选中；
/// - [toggle]：tap 切换选中；取消最后一首选中时自动退出多选模式；
/// - [toggleSelectAll]：与当前列表比较——未全选则全选，已全选则清空，
///   清空后**保持**多选模式（不自动退出，与歌单页 `_toggleSelectAll` 一致）；
/// - [exitSelectMode]：退出并清空选中。
///
/// 控制器只持有 id 集合与模式状态，不持有页面状态（搜索框/删除流程等）；
/// 消费方监听 [ChangeNotifier] 自行 setState。id 到 Song 的映射、批量
/// 操作（删除/加队列/加入歌单）由页面实现——不同页面的可执行操作不同。
class MultiSelectController extends ChangeNotifier {
  MultiSelectController();

  /// 是否处于多选模式。
  bool isSelectMode = false;

  final Set<String> _selectedIds = {};

  /// 当前选中的歌曲 id 集合。只读约定：消费方不得直接修改，
  /// 变更一律经 [toggle]/[toggleSelectAll]/[exitSelectMode]/[enterSelectMode]。
  Set<String> get selectedIds => _selectedIds;

  /// 已选数量。
  int get selectedCount => _selectedIds.length;

  /// 是否存在至少一个选中项。
  bool get hasSelection => _selectedIds.isNotEmpty;

  /// 是否选中了 [songId]。
  bool isSelected(String songId) => _selectedIds.contains(songId);

  /// 长按进入多选模式：首个 item 自动选中。
  ///
  /// 已处于多选模式时调用无副作用（保持现状，用于防御性调用）。
  void enterSelectMode(String firstSongId) {
    if (isSelectMode) return;
    isSelectMode = true;
    _selectedIds.clear();
    _selectedIds.add(firstSongId);
    notifyListeners();
  }

  /// 退出多选模式并清空选中。
  void exitSelectMode() {
    if (!isSelectMode && _selectedIds.isEmpty) return;
    isSelectMode = false;
    _selectedIds.clear();
    notifyListeners();
  }

  /// 切换 [songId] 的选中状态。
  ///
  /// 取消最后一首选中时自动退出多选模式（与歌单页 `_toggleSongSelection`
  /// 行为一致）。
  void toggle(String songId) {
    if (_selectedIds.contains(songId)) {
      _selectedIds.remove(songId);
      if (_selectedIds.isEmpty) {
        isSelectMode = false;
      }
    } else {
      _selectedIds.add(songId);
    }
    notifyListeners();
  }

  /// 全选/取消全选（与歌单页 `_toggleSelectAll` 行为一致）：
  /// 当前已全选 → 清空但保持多选模式；否则全选 [allSongIds]。
  void toggleSelectAll(Iterable<String> allSongIds) {
    if (_selectedIds.length == allSongIds.length && _selectedIds.isNotEmpty) {
      _selectedIds.clear();
    } else {
      _selectedIds
        ..clear()
        ..addAll(allSongIds);
    }
    notifyListeners();
  }
}
