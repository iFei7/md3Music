package com.gracemusic.player.queue

import com.gracemusic.data.model.Song
import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.model.PlaylistSortBy
import com.gracemusic.player.model.comparator
import com.gracemusic.player.model.isNoOpFor
import kotlin.random.Random

/**
 * 播放队列域（不可变值对象 + 纯转换函数）。
 *
 * 1:1 移植自 lib/providers/player_provider.dart 中维护队列的三个字段与
 * 全部队列操作（Dart 原文见各方法 KDoc）。**唯一的结构性改造是把可变字段
 * 变成不可变值 + 返回新队列的纯函数**，语义逐行对齐：
 *
 * | Dart 字段 | 本类字段 |
 * |---|---|
 * | `_playlist` | [playlist] |
 * | `_originalPlaylist` | [originalPlaylist] |
 * | `_currentIndex` | [currentIndex] |
 * | `_shuffleEnabled` | [shuffleEnabled] |
 * | `_loopMode` | [loopMode] |
 *
 * 之所以要做这个改造：Dart 侧「就地改字段 + 中途 await」的写法在多处出现过
 * 状态被异步回调污染的事故（`_currentSong` 与 `_playlist[cur]` 不一致等）。
 * 不可变值让「一次转换 = 一个结果」变得可单测，并让 store 侧的副作用
 * （持久化、引擎队列同步、通知刷新）由调用方显式编排。
 *
 * **本类不含任何副作用**：不落盘、不碰引擎、不弹提示、不上报听歌。凡 Dart
 * 原文里与队列字段无关的动作（`_savePlaylistIfChanged`、`_updateNotification`、
 * `_audioService.*`、`ListenReportService`、`notifyListeners`）一律留在
 * PlaybackStore 侧，由返回结果驱动。
 *
 * ## 与 lite 的三处刻意保留（不是漏改）
 *
 * 1. **`originalPlaylist` 的维护范围**：Dart 只在 `_loadPlaylist` / `reorderPlaylist`
 *    / `sortPlaylist` / `toggleShuffle`(关闭态) / `removeFromPlaylist` / `insertAfterCurrent`
 *    里同步它；[append] **刻意不同步**（Dart `appendPlaylist` 也不同步），改由后续
 *    [sortWith] / 重新装载覆盖。此不对称在 lite 上表现为「随机播放追加歌曲后关闭
 *    随机会丢追加项」——属于既有行为，此处保持一致以免线上表现漂移，已在 T45
 *    任务记录里登记为待确认项。
 * 2. **同 id 去重**：得益于 [Song.equals] 仅比较 [Song.id]，集合运算天然按 id 去重。
 * 3. **[toggledShuffle] 没有幂等守卫**：Dart `toggleShuffle` 也是纯粹取反，连按两次
 *    会回到原始顺序（而不是停留在随机态）。保持取反语义，不做「设置式」改写。
 */
data class PlaybackQueue(
    /** 当前实际播放顺序（随机播放下为打乱后的顺序）。 */
    val playlist: List<Song> = emptyList(),
    /** 关闭随机播放时用于还原的原始顺序。 */
    val originalPlaylist: List<Song> = emptyList(),
    /** 当前播放歌曲在 [playlist] 中的下标；-1 表示无当前歌曲。 */
    val currentIndex: Int = -1,
    /** 随机播放开关。 */
    val shuffleEnabled: Boolean = false,
    /** 应用层循环模式。 */
    val loopMode: AppLoopMode = AppLoopMode.OFF,
) {
    /** 当前播放歌曲；[currentIndex] 越界时为 null（等价 Dart `_currentSong`）。 */
    val currentSong: Song?
        get() = playlist.getOrNull(currentIndex)

    val size: Int get() = playlist.size

    val isEmpty: Boolean get() = playlist.isEmpty()

    /** 队列是否为「非空但无当前曲」（`currentIndex < 0`）。 */
    val hasNoCurrent: Boolean get() = currentIndex < 0

    /**
     * 只替换字段，不动任何派生态。
     */
    fun withSongs(
        playlist: List<Song> = this.playlist,
        originalPlaylist: List<Song> = this.originalPlaylist,
        currentIndex: Int = this.currentIndex,
        shuffleEnabled: Boolean = this.shuffleEnabled,
        loopMode: AppLoopMode = this.loopMode,
    ): PlaybackQueue = copy(
        playlist = playlist,
        originalPlaylist = originalPlaylist,
        currentIndex = currentIndex,
        shuffleEnabled = shuffleEnabled,
        loopMode = loopMode,
    )

    // ─────────────────────────── 装载 ───────────────────────────

    /**
     * 装载新队列，1:1 移植自 player_provider.dart:3260-3275（`_loadPlaylist`）：
     *
     * ```dart
     * _originalPlaylist = List.from(songs);
     * if (_shuffleEnabled) {
     *   final currentSong = songs[startIndex];
     *   final remaining = songs.where((s) => s.id != currentSong.id).toList();
     *   remaining.shuffle();
     *   _playlist = [currentSong, ...remaining];
     *   _currentIndex = 0;
     * } else {
     *   _playlist = List.from(songs);
     *   _currentIndex = startIndex;
     * }
     * ```
     *
     * 随机的处理方式值得注意：**起始曲恒排在第 0 位**（随机只打乱其余部分），
     * 因为用户刚刚点的那首必须立刻播，不能被洗到后面去。
     *
     * @param random 随机源（注入以便单测确定化；默认与 Dart 的全局 RNG 等价）。
     * @return 新队列；[songs] 为空时返回 null（Dart 调用方在进入 `_loadPlaylist`
     *   前就 `if (songs.isEmpty) return;` 提前返回，此处用可空返回强制调用方处理）。
     *
     * **一处刻意加固**：Dart 直接 `songs[startIndex]` 取值，越界会抛 RangeError
     * 并让 `playPlaylist` 的 Future 静默失败（调用方普遍不 await）。此处把
     * [startIndex] 收敛到合法区间，崩溃降级为「从边界曲起播」。
     */
    fun load(songs: List<Song>, startIndex: Int, random: Random = Random.Default): PlaybackQueue? {
        if (songs.isEmpty()) return null
        val safeStart = startIndex.coerceIn(0, songs.lastIndex)
        val original = songs.toList()
        return if (shuffleEnabled) {
            val current = songs[safeStart]
            val remaining = songs.filter { it.id != current.id }
            copy(
                originalPlaylist = original,
                playlist = buildList(remaining.size + 1) {
                    add(current)
                    addAll(remaining.shuffled(random))
                },
                currentIndex = 0,
            )
        } else {
            copy(originalPlaylist = original, playlist = original.toList(), currentIndex = safeStart)
        }
    }

    // ─────────────────────────── 增 ───────────────────────────

    /**
     * 追加歌曲（同名 id 去重），1:1 移植自 player_provider.dart:4754-4768
     * （`appendPlaylist` 的列表维护部分）。
     *
     * **`originalPlaylist` 刻意不同步**——见类 KDoc 第 1 条。
     */
    fun append(songs: List<Song>): QueueMutation {
        if (songs.isEmpty()) return QueueMutation(this)
        val seen = playlist.mapTo(HashSet(playlist.size)) { it.id }
        val added = ArrayList<Song>(songs.size)
        for (song in songs) {
            // 逐曲去重：既排除已在队列中的，也排除同批次内重复的（与 Dart 相同）
            if (seen.add(song.id)) added += song
        }
        if (added.isEmpty()) return QueueMutation(this)
        return QueueMutation(
            queue = withSongs(playlist = playlist + added),
            structuralChange = true,
            addedSongs = added,
        )
    }

    /**
     * 在当前播放歌曲之后插入歌曲（「下一首播放」），1:1 移植自
     * player_provider.dart:4810-4890（`insertAfterCurrent` 的列表维护部分）。
     *
     * 语义分两类：
     * - 不在队列中的歌曲：新增并插到当前位置之后；
     * - 已在队列中的歌曲：**移动**到现在播放的这首之后（不重复添加）。
     *
     * 队列为空或无当前曲时退化为 [append]，与 Dart 一致。
     *
     * 插入顺序恒为「新增在前、移动在后」，并各自保持调用顺序。
     *
     * **同步 `originalPlaylist` 的偏移规则与 Dart 略有出入**：Dart 用
     * `origOld`（移动曲在原始列表中的位置）作为插入点，此处保持同一算法
     * （见下方步骤 5），不做「更正确」的改写。
     */
    fun insertAfterCurrent(songs: List<Song>): QueueMutation {
        if (songs.isEmpty()) return QueueMutation(this)
        if (playlist.isEmpty() || currentIndex < 0) return append(songs)

        val currentId = playlist[currentIndex].id
        val existingIds = playlist.mapTo(HashSet(playlist.size)) { it.id }
        val newSongs = ArrayList<Song>()
        val moveSongs = ArrayList<Song>()
        for (song in songs) {
            if (song.id == currentId) continue // 当前曲本身就是「当前」，无需移动
            if (song.id in existingIds) moveSongs += song else newSongs += song
        }
        if (newSongs.isEmpty() && moveSongs.isEmpty()) return QueueMutation(this)

        // 1. 先从 playlist 移除待移动歌曲（稍后统一插回当前歌曲之后）
        var working = playlist
        if (moveSongs.isNotEmpty()) {
            val moveIds = moveSongs.mapTo(HashSet(moveSongs.size)) { it.id }
            working = working.filterNot { it.id in moveIds }
        }

        // 2. 重新定位当前歌曲索引（前面被移除的歌曲会使当前歌曲前移）
        var curIdx = working.indexOfFirst { it.id == currentId }
        if (curIdx < 0) curIdx = if (working.isEmpty()) 0 else working.lastIndex
        val insertIndex = curIdx + 1

        // 3. 插入：新增在前、移动在后
        val inserted = newSongs + moveSongs
        working = buildList(working.size + inserted.size) {
            addAll(working.subList(0, insertIndex.coerceIn(0, working.size)))
            addAll(inserted)
            addAll(working.subList(insertIndex.coerceIn(0, working.size), working.size))
        }

        // 4. 当前歌曲本身未移动，但其前后增删歌曲会改变索引：按 id 重新定位
        var newCurrent = working.indexOfFirst { it.id == currentId }
        if (newCurrent < 0) newCurrent = 0

        // 5. 同步 originalPlaylist：把新增 + 移动的歌曲插到当前歌曲之后
        var orig = originalPlaylist
        if (moveSongs.isNotEmpty()) {
            val moveIds = moveSongs.mapTo(HashSet(moveSongs.size)) { it.id }
            orig = orig.filterNot { it.id in moveIds }
        }
        val origCurIdx = orig.indexOfFirst { it.id == currentId }
        val origInsert = if (origCurIdx >= 0) (origCurIdx + 1).coerceIn(0, orig.size) else orig.size
        orig = buildList(orig.size + inserted.size) {
            addAll(orig.subList(0, origInsert))
            addAll(inserted)
            addAll(orig.subList(origInsert, orig.size))
        }

        return QueueMutation(
            queue = withSongs(playlist = working, originalPlaylist = orig, currentIndex = newCurrent),
            structuralChange = true,
            addedSongs = newSongs,
        )
    }

    // ─────────────────────────── 删 ───────────────────────────

    /**
     * 删除指定下标的歌曲，1:1 移植自 player_provider.dart:4903-4977
     * （`removeFromPlaylist` 的步骤 1-2，纯队列部分）。
     *
     * 索引维护的三条规则（Dart 原注释）：
     * - 列表为空：清空播放状态；
     * - 删除的是当前播放歌曲：自动切到同下标位置的新歌（需 clamp）；
     * - 删除的在当前歌曲之前：`currentIndex` 前移。
     *
     * 步骤 3（引擎队列重建 / 解析新当前曲 URL）属于副作用，由 PlaybackStore
     * 依据返回的 [QueueRemoval.removedCurrent] / [QueueRemoval.emptied] 编排。
     */
    fun removeAt(index: Int): QueueRemoval {
        if (index < 0 || index >= playlist.size) {
            return QueueRemoval(this, removedSong = null, removedCurrent = false, emptied = false, applied = false)
        }
        val removedSong = playlist[index]
        val wasCurrent = index == currentIndex

        val nextPlaylist = buildList(playlist.size - 1) {
            addAll(playlist.subList(0, index))
            addAll(playlist.subList(index + 1, playlist.size))
        }
        val nextOriginal = originalPlaylist.filterNot { it.id == removedSong.id }

        val nextIndex: Int
        val emptied = nextPlaylist.isEmpty()
        when {
            emptied -> nextIndex = -1
            wasCurrent -> nextIndex = index.coerceIn(0, nextPlaylist.lastIndex)
            index < currentIndex -> nextIndex = currentIndex - 1
            else -> nextIndex = currentIndex
        }

        return QueueRemoval(
            queue = withSongs(
                playlist = nextPlaylist,
                originalPlaylist = nextOriginal,
                currentIndex = nextIndex,
            ),
            removedSong = removedSong,
            removedCurrent = wasCurrent,
            emptied = emptied,
            applied = true,
        )
    }

    /**
     * 批量删除，1:1 移植自 player_provider.dart:5112-5136
     * （`removeManyFromPlaylist` 的「不含/含当前曲」分流部分）。
     *
     * 不含当前播放歌曲：只摘掉其余歌曲、按 id 重新定位当前索引。
     * 含当前播放歌曲：先摘掉其余歌曲，再把队列交给 [removeAt] 处理当前曲
     * （Dart 同样复用 `removeFromPlaylist`）。
     *
     * **`structuralChange` 可能连续置位两次**（先摘其余、再删当前），与 Dart
     * 里 `_queueRevision++` 被执行两次一致；它只是单调失效器，重复自增无害。
     */
    fun removeMany(songIds: Set<String>): QueueMutation {
        if (songIds.isEmpty() || playlist.isEmpty()) return QueueMutation(this)

        val currentId = currentSong?.id
        val removingCurrent = currentId != null && currentId in songIds
        val others = if (removingCurrent) songIds - currentId else songIds

        var working = this
        var structural = false
        if (others.isNotEmpty()) {
            val nextPlaylist = working.playlist.filterNot { it.id in others }
            val nextOriginal = working.originalPlaylist.filterNot { it.id in others }
            var nextIndex = if (currentId == null) {
                -1
            } else {
                nextPlaylist.indexOfFirst { it.id == currentId }
            }
            if (nextIndex < 0) nextIndex = if (nextPlaylist.isEmpty()) -1 else 0
            working = working.withSongs(
                playlist = nextPlaylist,
                originalPlaylist = nextOriginal,
                currentIndex = nextIndex,
            )
            structural = true
        }

        if (removingCurrent) {
            val removal = working.removeAt(working.currentIndex)
            return QueueMutation(
                queue = removal.queue,
                structuralChange = true,
                removedCurrentSong = removal.removedSong,
                emptied = removal.emptied,
            )
        }

        return QueueMutation(working, structuralChange = structural)
    }

    // ─────────────────────────── 排 ───────────────────────────

    /**
     * 重排播放列表，1:1 移植自 player_provider.dart:5018-5057（`reorderPlaylist`）。
     *
     * 参数遵循 Flutter `ReorderableListView` 约定：`oldIndex < newIndex` 时
     * `newIndex` 需要 -1 才是实际插入位置。
     */
    fun reorder(oldIndex: Int, newIndexRaw: Int): QueueMutation {
        if (oldIndex < 0 || oldIndex >= playlist.size) return QueueMutation(this)

        var newIndex = newIndexRaw
        if (oldIndex < newIndex) newIndex -= 1
        if (oldIndex == newIndex) return QueueMutation(this)
        if (newIndex < 0 || newIndex >= playlist.size) return QueueMutation(this)

        val song = playlist[oldIndex]
        val nextPlaylist = playlist.toMutableList().apply {
            removeAt(oldIndex)
            add(newIndex, song)
        }

        // 同步 originalPlaylist：按其自身位置做同样的移除 + 插回
        val origOld = originalPlaylist.indexOfFirst { it.id == song.id }
        val nextOriginal = if (origOld == -1) {
            originalPlaylist
        } else {
            originalPlaylist.toMutableList().apply {
                removeAt(origOld)
                add(origOld.coerceIn(0, size), song)
            }
        }

        // 当前播放索引的三种位移
        val nextIndex = when {
            oldIndex == currentIndex -> newIndex
            oldIndex < currentIndex && newIndex >= currentIndex -> currentIndex - 1
            oldIndex > currentIndex && newIndex <= currentIndex -> currentIndex + 1
            else -> currentIndex
        }

        return QueueMutation(
            queue = withSongs(
                playlist = nextPlaylist,
                originalPlaylist = nextOriginal,
                currentIndex = nextIndex,
            ),
            structuralChange = true,
        )
    }

    /**
     * 按维度重排整个队列，1:1 移植自 player_provider.dart:5067-5104（`sortPlaylist`）。
     *
     * 排序结果**同时写回** [playlist] 与 [originalPlaylist]——因为队列顺序本身
     * 就是播放顺序，排序后的顺序成为新的「原始顺序」（关闭随机播放时回到这里）。
     */
    fun sortWith(by: PlaylistSortBy, ascending: Boolean = true): QueueMutation {
        if (by.isNoOpFor(playlist.size)) return QueueMutation(this)

        val currentId = currentSong?.id
        val sorted = playlist.sortedWith(by.comparator(ascending))
        var nextIndex = if (currentId == null) -1 else sorted.indexOfFirst { it.id == currentId }
        if (nextIndex < 0) nextIndex = if (sorted.isEmpty()) -1 else 0

        return QueueMutation(
            queue = withSongs(
                playlist = sorted,
                originalPlaylist = sorted.toList(),
                currentIndex = nextIndex,
            ),
            structuralChange = true,
        )
    }

    /**
     * 用更新后的歌曲替换队列中同 id 的那一项，1:1 移植自
     * player_provider.dart:4793-4803（`updateSongInPlaylist`）。
     *
     * 用场景：NAS 按需下载后回写 `localPath`、URL 解析成功后回写 `url`。
     * 不做结构变更（不重建引擎队列、不打断播放），因此
     * [QueueMutation.structuralChange] 恒为 false。
     */
    fun updateSong(updatedSong: Song): QueueMutation {
        val idx = playlist.indexOfFirst { it.id == updatedSong.id }
        if (idx < 0) return QueueMutation(this)
        val nextPlaylist = playlist.toMutableList().apply { this[idx] = updatedSong }
        return QueueMutation(queue = withSongs(playlist = nextPlaylist))
    }

    // ─────────────────────────── 模式 ───────────────────────────

    /**
     * 切换循环模式：不循环 → 列表循环 → 单曲循环 → 不循环。
     *
     * 1:1 移植自 player_provider.dart:5143-5153（`toggleLoopMode`）与
     * `AppLoopMode.toggled()`。
     *
     * 纯队列语义上只改 [loopMode]；「预加载结果作废」（Dart
     * `_resetCrossfadePrepared`）由 store 消费 [QueueMutation.structuralChange]
     * 完成。注意 Dart 的 `_applyLoopMode` **没有** `_queueRevision++`，
     * 但确实调用了 `_resetCrossfadePrepared`——因此这里置
     * [QueueMutation.structuralChange] = false，另用
     * [QueueMutation.preparedArtifactInvalid] = true 表达「只需作废预加载」。
     */
    fun withLoopMode(mode: AppLoopMode): QueueMutation {
        if (mode == loopMode) return QueueMutation(this)
        return QueueMutation(
            queue = withSongs(loopMode = mode),
            structuralChange = false,
            preparedArtifactInvalid = true,
        )
    }

    /**
     * 切换随机播放，1:1 移植自 player_provider.dart:5199-5230（`toggleShuffle`）。
     *
     * 开启：把当前曲提到第 0 位、其余打乱，`currentIndex = 0`。
     * 关闭：从 [originalPlaylist] 还原顺序，并按 id 重新定位当前曲
     * （找不到则落 0；当前曲为 null 时索引不动）。
     *
     * **注意 Dart 侧 `_originalPlaylist` 在开启随机时不被修改**，因此
     * 「随机 → 关闭」能还原到原始顺序。
     */
    fun toggledShuffle(random: Random = Random.Default): QueueMutation {
        val enabled = !shuffleEnabled
        if (!enabled) {
            val current = currentSong
            val restored = originalPlaylist.toList()
            val restoredIndex = if (current == null) {
                currentIndex
            } else {
                val found = restored.indexOfFirst { it.id == current.id }
                if (found < 0) 0 else found
            }
            return QueueMutation(
                queue = withSongs(
                    playlist = restored,
                    currentIndex = restoredIndex,
                    shuffleEnabled = false,
                ),
                structuralChange = true,
                preparedArtifactInvalid = true,
            )
        }

        val current = currentSong
        val remaining = if (current == null) {
            playlist.toList()
        } else {
            playlist.filter { it.id != current.id }
        }.shuffled(random)
        val nextPlaylist = if (current == null) remaining else listOf(current) + remaining

        return QueueMutation(
            queue = withSongs(
                playlist = nextPlaylist,
                currentIndex = 0,
                shuffleEnabled = true,
            ),
            structuralChange = true,
            preparedArtifactInvalid = true,
        )
    }

    /**
     * 合并后的播放模式循环（播放器底部只有一个模式按钮）：
     * 不循环 → 列表循环 → 单曲循环 → 随机播放 → 不循环。
     *
     * 1:1 移植自 player_provider.dart:5176-5197（`cyclePlayMode`）：
     *
     * ```dart
     * if (_shuffleEnabled) {
     *   await toggleShuffle();            // 随机 → 恢复原始顺序
     *   await _applyLoopMode(AppLoopMode.off);
     *   return;
     * }
     * switch (_loopMode) {
     *   case off:  await _applyLoopMode(all); break;
     *   case all:  await _applyLoopMode(one); break;
     *   case one:  await _applyLoopMode(all); await toggleShuffle(); break;
     * }
     * ```
     *
     * 随机播放视作「列表循环 + 打乱顺序」，因此**进入随机时先把 loopMode
     * 置为 all**，退出随机时关掉循环。
     */
    fun cyclePlayMode(random: Random = Random.Default): QueueMutation {
        if (shuffleEnabled) {
            val unshuffled = toggledShuffle(random)
            return QueueMutation(
                queue = unshuffled.queue.withSongs(loopMode = AppLoopMode.OFF),
                structuralChange = unshuffled.structuralChange,
                preparedArtifactInvalid = true,
            )
        }
        return when (loopMode) {
            AppLoopMode.OFF -> withLoopMode(AppLoopMode.ALL)
            AppLoopMode.ALL -> withLoopMode(AppLoopMode.ONE)
            AppLoopMode.ONE -> {
                val looped = withLoopMode(AppLoopMode.ALL)
                val shuffled = looped.queue.toggledShuffle(random)
                QueueMutation(
                    queue = shuffled.queue,
                    structuralChange = shuffled.structuralChange,
                    preparedArtifactInvalid = true,
                )
            }
        }
    }

    /**
     * 清空队列，1:1 移植自 player_provider.dart:4750-4756（`clearPlaylist` 的
     * 列表维护部分）。引擎停止、听歌上报、通知刷新由 store 编排。
     */
    fun cleared(): QueueMutation = QueueMutation(
        queue = withSongs(playlist = emptyList(), originalPlaylist = emptyList(), currentIndex = -1),
        structuralChange = true,
        removedCurrentSong = currentSong,
        emptied = true,
    )

    /** 直接落位到某个下标（[PlaybackStore] 在解析失败后逐曲尝试时使用）。 */
    fun positionedAt(index: Int): PlaybackQueue =
        if (index < 0 || index >= playlist.size) this else withSongs(currentIndex = index)

    /**
     * 把解析后的歌曲回写到队列中当前下标处（URL / 真实本地路径回写）。
     * 与 [updateSong] 的区别：本方法按**下标**定位，用于「当前曲刚被解析完」
     * 的场景（Dart 里写作 `_playlist[_currentIndex] = resolvedSong`）。
     */
    fun replaceCurrent(song: Song): PlaybackQueue {
        if (currentIndex < 0 || currentIndex >= playlist.size) return this
        val next = playlist.toMutableList().apply { this[currentIndex] = song }
        return withSongs(playlist = next)
    }

    // ─────────────────────── 索引推进（纯算术） ───────────────────────

    /**
     * `next()` 进入候选循环前的边界判定，1:1 移植自 player_provider.dart:4560-4578：
     *
     * ```dart
     * if (_currentIndex >= _playlist.length - 1 && _loopMode != AppLoopMode.all) {
     *   if (_loopMode != AppLoopMode.one) {
     *     if (shouldHintQueueEnd(...)) showToast('已经是最后一首了');
     *     await _audioService?.pause();
     *     return;
     *   }
     *   if (_playlist.length == 1) {
     *     await seek(Duration.zero);
     *     if (autoPlay) await _audioService?.playCommand();
     *     return;
     *   }
     * }
     * ```
     */
    fun nextBoundary(): NextBoundary {
        val n = playlist.size
        if (n == 0) return NextBoundary.Nothing
        if (currentIndex >= n - 1 && loopMode != AppLoopMode.ALL) {
            if (loopMode != AppLoopMode.ONE) {
                return NextBoundary.HintAndPause(
                    showHint = shouldHintQueueEnd(loopMode, currentIndex, n),
                )
            }
            if (n == 1) return NextBoundary.RestartSingle
        }
        return NextBoundary.Proceed
    }

    /**
     * `next()` 的实际候选下标序列——**逐行模拟** player_provider.dart:4583-4614
     * 的 for 循环控制流（含循环体内的两处 `break`）：
     *
     * ```dart
     * final startIndex = _currentIndex;
     * for (int i = 0; i < _playlist.length; i++) {
     *   final nextIndex = (_currentIndex + 1) % _playlist.length;
     *   if (nextIndex == startIndex) break;          // 绕回起点：全部试过
     *   _currentIndex = nextIndex;
     *   final result = await _resolveAndPlayCurrentSong(...);
     *   if (result.succeeded) return;
     *   _resolveError = _resolveErrorText(_currentSong);
     *   // 非列表循环模式下，到末尾就停止尝试
     *   if (_currentIndex >= _playlist.length - 1 && _loopMode != AppLoopMode.all) break;
     * }
     * ```
     *
     * 由于 `_currentIndex` 在循环内被赋值为 `nextIndex`，`(_currentIndex + 1) % n`
     * 每轮恰好前进一位；序列因此是「从起始位的下一个开始、环状前进、直到绕回
     * 起始位之前」共 n-1 项。非列表循环模式下再在队尾截断。
     */
    fun nextCandidateIndices(): List<Int> {
        val n = playlist.size
        if (n <= 1 || currentIndex < 0) return emptyList()
        val start = currentIndex
        val out = ArrayList<Int>(n - 1)
        var cursor = start
        for (i in 0 until n) {
            val next = (cursor + 1) % n
            if (next == start) break
            out += next
            cursor = next
            if (cursor >= n - 1 && loopMode != AppLoopMode.ALL) break
        }
        return out
    }

    /**
     * `previous()` 的候选下标序列——逐行模拟 player_provider.dart:4658-4671：
     *
     * ```dart
     * final startIndex = _currentIndex;
     * int prevIndex = _currentIndex;
     * for (int i = 0; i < _playlist.length; i++) {
     *   prevIndex = prevIndex > 0 ? prevIndex - 1 : _playlist.length - 1;
     *   if (prevIndex == startIndex) {
     *     if (_loopMode == AppLoopMode.all) break;
     *     await seek(Duration.zero);
     *     return;
     *   }
     *   ...
     *   if (result.succeeded) { ...; return; }
     * }
     * ```
     *
     * **与 `next` 的关键差异**：`previous` 的候选循环**没有**「非列表循环时在
     * 队尾截断」的 break——它在 off 模式下也会一路往回试到队首。因此
     * [previousCandidateIndices] 恒为 n-1 项（n>1 时），不受 [loopMode] 影响。
     *
     * 绕回起点时的动作由 [previousWrapAction] 决定（与候选序列分离，因为
     * Dart 在循环体内 `return`，而这里要让调用方显式决定后续副作用）。
     */
    fun previousCandidateIndices(): List<Int> {
        val n = playlist.size
        if (n <= 0 || currentIndex < 0) return emptyList()
        val start = currentIndex
        val out = ArrayList<Int>(maxOf(0, n - 1))
        var cursor = start
        for (i in 0 until n) {
            cursor = if (cursor > 0) cursor - 1 else n - 1
            if (cursor == start) break
            out += cursor
        }
        return out
    }

    /**
     * `previous()` 绕回起点（所有候选都试过）时的动作，1:1 移植自
     * player_provider.dart:4661-4665：
     *
     * ```dart
     * if (prevIndex == startIndex) {
     *   if (_loopMode == AppLoopMode.all) break;   // 跳出循环 → 仅落盘 + 通知
     *   await seek(Duration.zero);                 // 非列表循环 → 当前曲回到 0
     *   return;
     * }
     * ```
     *
     * 也就是说：**单曲队列 + 列表循环下按「上一首」什么都不会发生**（仅落盘），
     * 而 off/one 模式下会把当前曲定位回开头。这与 `next` 在单曲 + 单曲循环下
     * 「重播当前曲」的行为**不对称**，是 Dart 既有设计，此处保持一致。
     */
    fun previousWrapAction(): PreviousWrapAction =
        if (loopMode == AppLoopMode.ALL) PreviousWrapAction.NoOp else PreviousWrapAction.RestartCurrent

    /** 下一首预加载的候选下标，1:1 移植自 player_provider.dart:2748-2753。 */
    fun nextIndexForCrossfade(): Int? {
        if (playlist.isEmpty() || currentIndex < 0) return null
        if (currentIndex < playlist.lastIndex) return currentIndex + 1
        if (loopMode == AppLoopMode.ALL) return 0
        return null
    }
}

/**
 * 一次队列转换的结果。
 *
 * @property queue 转换后的新队列。
 * @property structuralChange 是否需要 `queueRevision++` 并作废预加载/交叉淡化
 *   产物（对应 Dart 里 `_queueRevision++; _resetCrossfadePrepared();` 同时出现的路径）。
 * @property preparedArtifactInvalid 是否需要**仅**作废预加载/交叉淡化产物而不动
 *   `queueRevision`（对应 `_applyLoopMode`：它只调 `_resetCrossfadePrepared`）。
 * @property addedSongs 需要同步到引擎播放源的新增歌曲（[PlaybackQueue.append]
 *   / [PlaybackQueue.insertAfterCurrent] 专用）。
 * @property removedCurrentSong 被移除的当前曲（[PlaybackQueue.removeAt]
 *   / [PlaybackQueue.removeMany] / [PlaybackQueue.cleared] 专用）——store 据此
 *   决定是否重建引擎队列或停止播放。
 * @property emptied 转换后队列是否已清空（触发「用户主动停止」语义）。
 */
data class QueueMutation(
    val queue: PlaybackQueue,
    val structuralChange: Boolean = false,
    val preparedArtifactInvalid: Boolean = false,
    val addedSongs: List<Song> = emptyList(),
    val removedCurrentSong: Song? = null,
    val emptied: Boolean = false,
)

/**
 * [PlaybackQueue.removeAt] 的结果。字段语义见各属性 KDoc。
 */
data class QueueRemoval(
    val queue: PlaybackQueue,
    val removedSong: Song?,
    val removedCurrent: Boolean,
    val emptied: Boolean,
    /** 是否为有效删除（下标越界时为 false，调用方应立即返回）。 */
    val applied: Boolean,
)

/**
 * `next()` 在进入候选循环前的走向。
 */
sealed interface NextBoundary {
    /** 空队列：`next()` 首行 `if (_playlist.isEmpty) return;` 直接返回。 */
    data object Nothing : NextBoundary

    /** 进入候选循环（单曲循环且多首时也走这里）。 */
    data object Proceed : NextBoundary

    /**
     * 非循环模式已停在最后一首：提示并暂停。
     * @property showHint 是否弹「已经是最后一首了」（恒为 true——本分支已限定
     *   `loopMode == OFF`，而 [shouldHintQueueEnd] 只在非 off 时返回 false；保留
     *   该字段是为了与 Dart 的调用结构一致并让单测能钉死这个恒等关系）。
     */
    data class HintAndPause(val showHint: Boolean) : NextBoundary

    /** 单曲循环且队列只有一首：定位回 0（autoPlay 时继续播放）。 */
    data object RestartSingle : NextBoundary
}

/**
 * `previous()` 绕回起点时的动作，见 [PlaybackQueue.previousWrapAction]。
 */
enum class PreviousWrapAction {
    /** 列表循环：仅落盘 + 通知，不改播放。 */
    NoOp,

    /** 非列表循环：当前曲 seek 回 0。 */
    RestartCurrent,
}

/**
 * 队列末尾「切不动下一首」的提示判定，1:1 移植自 player_provider.dart:5884-5894：
 *
 * ```dart
 * bool shouldHintQueueEnd({required String loopMode, required int currentIndex, required int playlistLength}) {
 *   if (loopMode != 'off') return false;
 *   if (playlistLength <= 0) return false;
 *   return currentIndex >= playlistLength - 1;
 * }
 * ```
 *
 * 列表循环会绕回队首、单曲循环会重播当前曲，两者都不存在「切不动」，
 * 故只有非循环模式（[AppLoopMode.OFF]）下已停在最后一首时才提示。
 *
 * Dart 侧 `loopMode` 传的是 `AppLoopMode.name` 字符串；此处用类型化的枚举
 * 比较，判定结果等价。
 */
fun shouldHintQueueEnd(
    loopMode: AppLoopMode,
    currentIndex: Int,
    playlistLength: Int,
): Boolean {
    if (loopMode != AppLoopMode.OFF) return false
    if (playlistLength <= 0) return false
    return currentIndex >= playlistLength - 1
}
