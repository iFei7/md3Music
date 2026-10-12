package com.gracemusic.player.queue

import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.model.PlaylistSortBy
import com.gracemusic.testutil.idsOf
import com.gracemusic.testutil.testSong
import com.gracemusic.testutil.testSongs
import kotlin.random.Random
import kotlin.time.Duration.Companion.seconds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PlaybackQueue] 的移植锁测试。
 *
 * 每个用例的 KDoc 标注对应的 Dart 原文行号（lib/providers/player_provider.dart），
 * 断言的是**语义等价**而不是实现细节：Dart 就地改字段、Kotlin 返回新值，两者
 * 的可见结果必须一致。
 *
 * 覆盖范围：装载（[PlaybackQueue.load]）/ 增（append / insertAfterCurrent）/
 * 删（removeAt / removeMany）/ 排（reorder / sortWith / updateSong）/
 * 模式（withLoopMode / toggledShuffle / cyclePlayMode）/
 * 索引推进（nextCandidateIndices / previousCandidateIndices / nextBoundary /
 * previousWrapAction / nextIndexForCrossfade）。
 */
class PlaybackQueueTest {

    private fun queueOf(vararg ids: String): PlaybackQueue =
        PlaybackQueue(playlist = testSongs(*ids), originalPlaylist = testSongs(*ids), currentIndex = 0)

    // ═══════════════════════════ 装载（_loadPlaylist） ═══════════════════════════

    @Test
    fun `装载_非随机时保持原序且当前索引为起始索引`() {
        val songs = testSongs("a", "b", "c")
        val q = PlaybackQueue(shuffleEnabled = false)
            .load(songs, startIndex = 2)!!

        assertEquals(listOf("a", "b", "c"), idsOf(q.playlist))
        assertEquals(listOf("a", "b", "c"), idsOf(q.originalPlaylist))
        assertEquals(2, q.currentIndex)
        assertEquals("c", q.currentSong?.id)
        assertFalse(q.shuffleEnabled)
    }

    @Test
    fun `装载_空列表返回 null`() {
        assertNull(PlaybackQueue().load(emptyList(), startIndex = 0))
    }

    @Test
    fun `装载_起始索引越界时收敛到合法区间_不抛异常`() {
        // Dart: songs[startIndex] 直接取值，越界抛 RangeError 并被 Future 静默吞掉。
        // native 刻意加固为 clamp（见 load 的 KDoc）。
        val songs = testSongs("a", "b", "c")
        assertEquals(2, PlaybackQueue().load(songs, startIndex = 99)!!.currentIndex)
        assertEquals(0, PlaybackQueue().load(songs, startIndex = -5)!!.currentIndex)
    }

    @Test
    fun `装载_随机模式下起始曲置于首位且当前索引归零`() {
        // Dart: _playlist = [currentSong, ...remaining]; _currentIndex = 0;
        val songs = testSongs("a", "b", "c", "d")
        val q = PlaybackQueue(shuffleEnabled = true).load(songs, startIndex = 2, random = Random(7))!!

        assertEquals("c", q.playlist.first().id)
        assertEquals(0, q.currentIndex)
        assertEquals("c", q.currentSong?.id)
        // 集合等价：随机只改顺序，不增不减
        assertEquals(setOf("a", "b", "c", "d"), q.playlist.mapTo(HashSet()) { it.id })
        assertEquals(4, q.playlist.size)
        assertTrue(q.shuffleEnabled)
    }

    @Test
    fun `装载_随机模式下原始队列保持传入顺序`() {
        val songs = testSongs("a", "b", "c", "d")
        val q = PlaybackQueue(shuffleEnabled = true).load(songs, startIndex = 0, random = Random(1))!!
        assertEquals(listOf("a", "b", "c", "d"), idsOf(q.originalPlaylist))
    }

    @Test
    fun `装载_随机模式下同 id 的重复曲目被一并排除在剩余集之外`() {
        // Dart: songs.where((s) => s.id != currentSong.id) —— 排除的是「同 id 的全部」，
        // 不只是第一首。这里构造一个同 id 出现两次的列表来钉死该语义。
        val duplicated = listOf(
            testSong("dup", title = "第一份"),
            testSong("x"),
            testSong("dup", title = "第二份"),
        )
        val q = PlaybackQueue(shuffleEnabled = true).load(duplicated, startIndex = 0, random = Random(3))!!

        // 起始曲（第一份 dup）在首位；剩余集里的「第二份 dup」因同 id 被过滤
        assertEquals(2, q.playlist.size)
        assertEquals("第一份", q.playlist.first().title)
        assertEquals(listOf("dup", "x"), idsOf(q.playlist))
    }

    // ═══════════════════════════ 增：append ═══════════════════════════

    @Test
    fun `追加_按 id 去重且报告新增曲目`() {
        val q = queueOf("a", "b")
        val m = q.append(listOf(testSong("b"), testSong("c"), testSong("d")))

        assertEquals(listOf("a", "b", "c", "d"), idsOf(m.queue.playlist))
        assertEquals(listOf("c", "d"), idsOf(m.addedSongs))
        assertTrue(m.structuralChange)
    }

    @Test
    fun `追加_全部重复时不产生结构变更`() {
        val q = queueOf("a", "b")
        val m = q.append(listOf(testSong("a"), testSong("b")))

        assertEquals(q, m.queue)
        assertTrue(m.addedSongs.isEmpty())
        assertFalse(m.structuralChange)
    }

    @Test
    fun `追加_同批次内的重复也被去重`() {
        // Dart 边遍历边比对不断变长的 _playlist，因此同批次重复同样会被吃掉。
        val m = queueOf("a").append(listOf(testSong("b"), testSong("b"), testSong("c")))
        assertEquals(listOf("a", "b", "c"), idsOf(m.queue.playlist))
        assertEquals(listOf("b", "c"), idsOf(m.addedSongs))
    }

    @Test
    fun `追加_原始队列刻意不同步_保留 lite 既有行为`() {
        // Dart appendPlaylist 不碰 _originalPlaylist。此不对称在 lite 上的表现是
        // 「随机播放追加歌曲后关闭随机会丢追加项」——保持行为一致，已登记待确认。
        val m = queueOf("a", "b").append(listOf(testSong("c")))
        assertEquals(listOf("a", "b", "c"), idsOf(m.queue.playlist))
        assertEquals(listOf("a", "b"), idsOf(m.queue.originalPlaylist))
    }

    // ═══════════════════════════ 增：insertAfterCurrent ═══════════════════════════

    @Test
    fun `下一首播放_空队列时退化为追加`() {
        val m = PlaybackQueue().insertAfterCurrent(listOf(testSong("a"), testSong("b")))
        assertEquals(listOf("a", "b"), idsOf(m.queue.playlist))
        assertEquals(listOf("a", "b"), idsOf(m.addedSongs))
    }

    @Test
    fun `下一首播放_新歌插到当前曲之后`() {
        // Dart: insertIndex = curIdx + 1; 新增在前、移动在后
        val q = queueOf("a", "b", "c") // currentIndex = 0（a）
        val m = q.insertAfterCurrent(listOf(testSong("x"), testSong("y")))

        assertEquals(listOf("a", "x", "y", "b", "c"), idsOf(m.queue.playlist))
        assertEquals(listOf("x", "y"), idsOf(m.addedSongs))
        assertEquals("a", m.queue.currentSong?.id)
        assertEquals(0, m.queue.currentIndex)
    }

    @Test
    fun `下一首播放_已在队列的歌被移动而非重复添加`() {
        // Dart: 先把待移动曲从 _playlist 摘掉，再统一插回当前曲之后；
        // 当前曲本身不下移（其索引按 id 重新定位）。
        val q = queueOf("a", "b", "c", "d") // current = a
        val m = q.insertAfterCurrent(listOf(testSong("d")))

        assertEquals(listOf("a", "d", "b", "c"), idsOf(m.queue.playlist))
        assertTrue(m.addedSongs.isEmpty()) // 无新增
        assertEquals("a", m.queue.currentSong?.id)
        assertEquals(0, m.queue.currentIndex)
        assertTrue(m.structuralChange)
    }

    @Test
    fun `下一首播放_当前曲被移动后索引按 id 重新定位`() {
        // current = c（index 2）；把 a 移到 c 之后。摘掉 a 后队列变 [b,c,d]（c 前移到 1），
        // 再把 a 插到 c 之后（index 2）→ [b,c,a,d]。**插入点在当前曲之后，不会把当前曲挤走**，
        // 所以 c 仍是 index 1；关键是要按 id 重新定位而不是沿用旧索引 2。
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d"),
            originalPlaylist = testSongs("a", "b", "c", "d"),
            currentIndex = 2,
        )
        val m = q.insertAfterCurrent(listOf(testSong("a")))

        assertEquals(listOf("b", "c", "a", "d"), idsOf(m.queue.playlist))
        assertEquals("c", m.queue.currentSong?.id)
        assertEquals(1, m.queue.currentIndex)
        // 语义校验：从 c 往后的下一首正是刚被移过来的 a
        assertEquals("a", m.queue.playlist[m.queue.currentIndex + 1].id)
    }

    @Test
    fun `下一首播放_入参含当前曲本身时被忽略`() {
        val q = queueOf("a", "b")
        val m = q.insertAfterCurrent(listOf(testSong("a")))
        assertEquals(q, m.queue)
        assertFalse(m.structuralChange)
    }

    @Test
    fun `下一首播放_新歌与移动曲混排时新增在前移动在后`() {
        val q = queueOf("a", "b", "c") // current = a
        val m = q.insertAfterCurrent(listOf(testSong("y"), testSong("c"), testSong("x")))

        // 分类遍历：y 新增、c 移动、x 新增 → [新增: y, x] 在前，[移动: c] 在后
        assertEquals(listOf("a", "y", "x", "c", "b"), idsOf(m.queue.playlist))
        assertEquals(listOf("y", "x"), idsOf(m.addedSongs))
    }

    @Test
    fun `下一首播放_同步原始队列到当前曲之后`() {
        val q = queueOf("a", "b", "c")
        val m = q.insertAfterCurrent(listOf(testSong("x")))
        assertEquals(listOf("a", "x", "b", "c"), idsOf(m.queue.originalPlaylist))
    }

    @Test
    fun `下一首播放_无新增无移动时不产生结构变更`() {
        val q = queueOf("a", "b")
        val m = q.insertAfterCurrent(emptyList())
        assertEquals(q, m.queue)
        assertFalse(m.structuralChange)
    }

    // ═══════════════════════════ 删：removeAt ═══════════════════════════

    @Test
    fun `删除_删除当前曲时切到同下标位置的新歌`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c"),
            originalPlaylist = testSongs("a", "b", "c"),
            currentIndex = 1,
        )
        val r = q.removeAt(1)

        assertTrue(r.applied)
        assertTrue(r.removedCurrent)
        assertFalse(r.emptied)
        assertEquals("b", r.removedSong?.id)
        assertEquals(listOf("a", "c"), idsOf(r.queue.playlist))
        assertEquals(1, r.queue.currentIndex)
        assertEquals("c", r.queue.currentSong?.id)
    }

    @Test
    fun `删除_删除最后一首的当前曲时索引 clamp 到新队尾`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c"),
            originalPlaylist = testSongs("a", "b", "c"),
            currentIndex = 2,
        )
        val r = q.removeAt(2)

        assertEquals(1, r.queue.currentIndex)
        assertEquals("b", r.queue.currentSong?.id)
    }

    @Test
    fun `删除_删除当前曲之前的歌时索引前移`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d"),
            originalPlaylist = testSongs("a", "b", "c", "d"),
            currentIndex = 2, // c
        )
        val r = q.removeAt(0)

        assertFalse(r.removedCurrent)
        assertEquals(1, r.queue.currentIndex)
        assertEquals("c", r.queue.currentSong?.id)
    }

    @Test
    fun `删除_删除当前曲之后的歌时索引不变`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d"),
            originalPlaylist = testSongs("a", "b", "c", "d"),
            currentIndex = 1, // b
        )
        val r = q.removeAt(3)

        assertEquals(1, r.queue.currentIndex)
        assertEquals("b", r.queue.currentSong?.id)
    }

    @Test
    fun `删除_删空队列时清空当前索引并标记 emptied`() {
        val q = PlaybackQueue(
            playlist = testSongs("only"),
            originalPlaylist = testSongs("only"),
            currentIndex = 0,
        )
        val r = q.removeAt(0)

        assertTrue(r.applied)
        assertTrue(r.emptied)
        assertTrue(r.removedCurrent)
        assertEquals(-1, r.queue.currentIndex)
        assertNull(r.queue.currentSong)
        assertTrue(r.queue.playlist.isEmpty())
        assertTrue(r.queue.originalPlaylist.isEmpty())
    }

    @Test
    fun `删除_越界时不产生任何变更`() {
        val q = queueOf("a", "b")
        assertFalse(q.removeAt(-1).applied)
        assertFalse(q.removeAt(2).applied)
        assertEquals(q, q.removeAt(5).queue)
    }

    @Test
    fun `删除_同步原始队列`() {
        val q = queueOf("a", "b", "c")
        val r = q.removeAt(1)
        assertEquals(listOf("a", "c"), idsOf(r.queue.originalPlaylist))
    }

    // ═══════════════════════════ 删：removeMany ═══════════════════════════

    @Test
    fun `批量删除_不含当前曲时只摘除并按 id 重新定位当前索引`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d"),
            originalPlaylist = testSongs("a", "b", "c", "d"),
            currentIndex = 2, // c
        )
        val m = q.removeMany(setOf("a", "d"))

        assertEquals(listOf("b", "c"), idsOf(m.queue.playlist))
        assertEquals(1, m.queue.currentIndex)
        assertEquals("c", m.queue.currentSong?.id)
        assertTrue(m.structuralChange)
        assertNull(m.removedCurrentSong)
    }

    @Test
    fun `批量删除_含当前曲时先摘其余再走删除当前曲语义`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d"),
            originalPlaylist = testSongs("a", "b", "c", "d"),
            currentIndex = 1, // b
        )
        val m = q.removeMany(setOf("b", "d"))

        // 先摘掉 d → [a, b, c]（current 仍是 b，index 1）
        // 再删除当前曲 b → 切到同下标 → c
        assertEquals(listOf("a", "c"), idsOf(m.queue.playlist))
        assertEquals("b", m.removedCurrentSong?.id)
        assertEquals("c", m.queue.currentSong?.id)
        assertTrue(m.structuralChange)
    }

    @Test
    fun `批量删除_含当前曲且删空时标记 emptied`() {
        val q = PlaybackQueue(
            playlist = testSongs("a"),
            originalPlaylist = testSongs("a"),
            currentIndex = 0,
        )
        val m = q.removeMany(setOf("a"))

        assertTrue(m.emptied)
        assertNull(m.queue.currentSong)
        assertEquals(-1, m.queue.currentIndex)
    }

    @Test
    fun `批量删除_空集合或空队列时不做任何事`() {
        val q = queueOf("a", "b")
        assertEquals(q, q.removeMany(emptySet()).queue)
        assertFalse(q.removeMany(emptySet()).structuralChange)

        val empty = PlaybackQueue()
        assertEquals(empty, empty.removeMany(setOf("a")).queue)
    }

    // ═══════════════════════════ 排：reorder ═══════════════════════════

    @Test
    fun `重排_遵循 ReorderableListView 约定的 newIndex 前移`() {
        // Dart: if (oldIndex < newIndex) newIndex -= 1;
        val q = queueOf("a", "b", "c", "d")
        val m = q.reorder(oldIndex = 0, newIndexRaw = 3)

        // old=0 < new=3 → new=2 → 把 a 插到下标 2
        assertEquals(listOf("b", "c", "a", "d"), idsOf(m.queue.playlist))
        assertTrue(m.structuralChange)
    }

    @Test
    fun `重排_拖动当前曲时索引跟随到新位置`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c"),
            originalPlaylist = testSongs("a", "b", "c"),
            currentIndex = 0,
        )
        val m = q.reorder(oldIndex = 0, newIndexRaw = 2)

        assertEquals(listOf("b", "a", "c"), idsOf(m.queue.playlist))
        assertEquals(1, m.queue.currentIndex)
        assertEquals("a", m.queue.currentSong?.id)
    }

    @Test
    fun `重排_当前曲被向后挤一位时索引自减`() {
        // old(0) < current(1)，落点 new(1) >= current(1) → currentIndex--
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c"),
            originalPlaylist = testSongs("a", "b", "c"),
            currentIndex = 1, // b
        )
        val m = q.reorder(oldIndex = 0, newIndexRaw = 2) // old<new → 落点 1

        assertEquals(listOf("b", "a", "c"), idsOf(m.queue.playlist))
        assertEquals(0, m.queue.currentIndex)
        assertEquals("b", m.queue.currentSong?.id)
    }

    @Test
    fun `重排_当前曲被向前挤一位时索引自增`() {
        // old(2) > current(1)，new(0) <= current(1) → currentIndex++
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c"),
            originalPlaylist = testSongs("a", "b", "c"),
            currentIndex = 1,
        )
        val m = q.reorder(oldIndex = 2, newIndexRaw = 0)

        assertEquals(listOf("c", "a", "b"), idsOf(m.queue.playlist))
        assertEquals(2, m.queue.currentIndex)
        assertEquals("b", m.queue.currentSong?.id)
    }

    @Test
    fun `重排_无效入参不产生变更`() {
        val q = queueOf("a", "b", "c")
        assertEquals(q, q.reorder(-1, 1).queue) // old 越界
        assertEquals(q, q.reorder(3, 1).queue) // old 越界
        assertEquals(q, q.reorder(1, 1).queue) // old == new
        assertEquals(q, q.reorder(1, 2).queue) // old < new → 落点回退成 1，仍相等
        assertEquals(q, q.reorder(2, 5).queue) // old < new → 落点 4 越过队尾
    }

    // ═══════════════════════════ 排：sortWith ═══════════════════════════

    @Test
    fun `排序_按播放顺序或不足两首时跳过`() {
        val q = queueOf("a", "b", "c")
        assertEquals(q, q.sortWith(PlaylistSortBy.QUEUE).queue)
        assertFalse(q.sortWith(PlaylistSortBy.QUEUE).structuralChange)

        val single = queueOf("a")
        assertEquals(single, single.sortWith(PlaylistSortBy.TITLE).queue)
        assertFalse(single.sortWith(PlaylistSortBy.TITLE).structuralChange)
    }

    @Test
    fun `排序_按标题使用 displayName 且大小写无关`() {
        val q = PlaybackQueue(
            playlist = listOf(
                testSong("1", title = "beta.mp3"),
                testSong("2", title = "Alpha.flac"),
                testSong("3", title = "gamma"),
            ),
            originalPlaylist = emptyList(),
            currentIndex = 0, // beta
        )
        val m = q.sortWith(PlaylistSortBy.TITLE, ascending = true)

        // Alpha < beta < gamma（displayName 已剥离扩展名，比较时忽略大小写）
        assertEquals(listOf("2", "1", "3"), idsOf(m.queue.playlist))
        assertEquals("1", m.queue.currentSong?.id)
        assertEquals(1, m.queue.currentIndex)
    }

    @Test
    fun `排序_降序为结果取反`() {
        val q = PlaybackQueue(
            playlist = listOf(testSong("1", title = "a"), testSong("2", title = "b")),
            currentIndex = 0,
        )
        assertEquals(listOf("2", "1"), idsOf(q.sortWith(PlaylistSortBy.TITLE, ascending = false).queue.playlist))
    }

    @Test
    fun `排序_按时长`() {
        val q = PlaybackQueue(
            playlist = listOf(
                testSong("slow", duration = 300.seconds),
                testSong("fast", duration = 100.seconds),
                testSong("mid", duration = 200.seconds),
            ),
            currentIndex = 0, // slow
        )
        val m = q.sortWith(PlaylistSortBy.DURATION)

        assertEquals(listOf("fast", "mid", "slow"), idsOf(m.queue.playlist))
        assertEquals("slow", m.queue.currentSong?.id)
        assertEquals(2, m.queue.currentIndex)
    }

    @Test
    fun `排序_结果成为新的原始顺序`() {
        // Dart: _originalPlaylist = List.from(sorted);
        val q = PlaybackQueue(
            playlist = listOf(testSong("b", title = "b"), testSong("a", title = "a")),
            originalPlaylist = listOf(testSong("b", title = "b"), testSong("a", title = "a")),
            currentIndex = 0,
        )
        val m = q.sortWith(PlaylistSortBy.TITLE)
        assertEquals(listOf("a", "b"), idsOf(m.queue.playlist))
        assertEquals(listOf("a", "b"), idsOf(m.queue.originalPlaylist))
    }

    // ═══════════════════════════ 排：updateSong ═══════════════════════════

    @Test
    fun `更新歌曲_替换同 id 项且不产生结构变更`() {
        val q = queueOf("a", "b")
        val refreshed = testSong("b", url = "http://cdn/b.mp3")
        val m = q.updateSong(refreshed)

        assertEquals("http://cdn/b.mp3", m.queue.playlist[1].url)
        assertFalse(m.structuralChange)
        assertFalse(m.preparedArtifactInvalid)
    }

    @Test
    fun `更新歌曲_队列中不存在时不做任何事`() {
        val q = queueOf("a", "b")
        assertEquals(q, q.updateSong(testSong("zzz")).queue)
    }

    // ═══════════════════════════ 模式：循环 ═══════════════════════════

    @Test
    fun `循环模式_设置相同值时不做任何事`() {
        val q = queueOf("a")
        assertEquals(q, q.withLoopMode(AppLoopMode.OFF).queue)
    }

    @Test
    fun `循环模式_设置新值只作废预加载产物不动队列修订号`() {
        // Dart _applyLoopMode 调了 _resetCrossfadePrepared 但没有 _queueRevision++。
        val q = queueOf("a", "b")
        val m = q.withLoopMode(AppLoopMode.ALL)

        assertEquals(AppLoopMode.ALL, m.queue.loopMode)
        assertFalse(m.structuralChange)
        assertTrue(m.preparedArtifactInvalid)
    }

    // ═══════════════════════════ 模式：随机 ═══════════════════════════

    @Test
    fun `开启随机_当前曲提到首位且索引归零`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d"),
            originalPlaylist = testSongs("a", "b", "c", "d"),
            currentIndex = 2, // c
            shuffleEnabled = false,
        )
        val m = q.toggledShuffle(Random(11))
        val next = m.queue

        assertTrue(next.shuffleEnabled)
        assertEquals("c", next.playlist.first().id)
        assertEquals(0, next.currentIndex)
        assertEquals(4, next.playlist.size)
        // 原始队列在开启随机时不被修改，供关闭时还原
        assertEquals(listOf("a", "b", "c", "d"), idsOf(next.originalPlaylist))
        assertTrue(m.structuralChange)
        assertTrue(m.preparedArtifactInvalid)
    }

    @Test
    fun `关闭随机_从原始队列还原并按 id 定位当前曲`() {
        val shuffled = PlaybackQueue(
            playlist = testSongs("c", "a", "d", "b"),
            originalPlaylist = testSongs("a", "b", "c", "d"),
            currentIndex = 0, // c
            shuffleEnabled = true,
        )
        val next = shuffled.toggledShuffle(Random(1)).queue

        assertFalse(next.shuffleEnabled)
        assertEquals(listOf("a", "b", "c", "d"), idsOf(next.playlist))
        assertEquals(2, next.currentIndex)
        assertEquals("c", next.currentSong?.id)
    }

    @Test
    fun `关闭随机_当前曲已不在原始队列时索引落零`() {
        val shuffled = PlaybackQueue(
            playlist = testSongs("ghost", "a"),
            originalPlaylist = testSongs("a", "b"),
            currentIndex = 0, // ghost
            shuffleEnabled = true,
        )
        val next = shuffled.toggledShuffle(Random(1)).queue

        assertEquals(listOf("a", "b"), idsOf(next.playlist))
        assertEquals(0, next.currentIndex)
    }

    @Test
    fun `随机_连按两次回到原始顺序`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d", "e"),
            originalPlaylist = testSongs("a", "b", "c", "d", "e"),
            currentIndex = 3, // d
        )
        val once = q.toggledShuffle(Random(42)).queue
        val twice = once.toggledShuffle(Random(99)).queue

        assertFalse(twice.shuffleEnabled)
        assertEquals(listOf("a", "b", "c", "d", "e"), idsOf(twice.playlist))
        assertEquals(3, twice.currentIndex)
    }

    @Test
    fun `随机_空队列时安全`() {
        val next = PlaybackQueue().toggledShuffle(Random(1)).queue
        assertTrue(next.shuffleEnabled)
        assertTrue(next.playlist.isEmpty())
        assertEquals(0, next.currentIndex)
    }

    // ═══════════════════════════ 模式：合并按钮 ═══════════════════════════

    @Test
    fun `模式循环_不循环到列表循环到单曲循环到随机再到不循环`() {
        var q = queueOf("a", "b", "c")
        assertEquals(AppLoopMode.OFF, q.loopMode)

        q = q.cyclePlayMode(Random(5)).queue
        assertEquals(AppLoopMode.ALL, q.loopMode)
        assertFalse(q.shuffleEnabled)

        q = q.cyclePlayMode(Random(5)).queue
        assertEquals(AppLoopMode.ONE, q.loopMode)
        assertFalse(q.shuffleEnabled)

        // 单曲循环 → 随机：先把 loopMode 置 all，再开启随机
        q = q.cyclePlayMode(Random(5)).queue
        assertEquals(AppLoopMode.ALL, q.loopMode)
        assertTrue(q.shuffleEnabled)

        // 随机 → 不循环：先关随机（还原原始顺序），再置 off
        q = q.cyclePlayMode(Random(5)).queue
        assertEquals(AppLoopMode.OFF, q.loopMode)
        assertFalse(q.shuffleEnabled)
        assertEquals(listOf("a", "b", "c"), idsOf(q.playlist))
    }

    @Test
    fun `模式循环_四步回到起点`() {
        val start = queueOf("a", "b", "c")
        var q = start
        repeat(4) { q = q.cyclePlayMode(Random(17)).queue }
        assertEquals(start, q)
    }

    // ═══════════════════════════ 索引推进：next ═══════════════════════════

    @Test
    fun `下一首候选_从当前位的下一个开始环状前进直到绕回起点`() {
        // 只有在列表循环下才会走满整圈（非列表循环会在队尾截断，见下一个用例）。
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d"),
            currentIndex = 1,
            loopMode = AppLoopMode.ALL,
        )
        assertEquals(listOf(2, 3, 0), q.nextCandidateIndices())
    }

    @Test
    fun `下一首候选_单首队列没有候选`() {
        val q = PlaybackQueue(playlist = testSongs("a"), currentIndex = 0)
        assertTrue(q.nextCandidateIndices().isEmpty())
    }

    @Test
    fun `下一首候选_两首队列恰有一个候选`() {
        val q = PlaybackQueue(playlist = testSongs("a", "b"), currentIndex = 0)
        assertEquals(listOf(1), q.nextCandidateIndices())
    }

    @Test
    fun `下一首候选_非列表循环模式下走到队尾即停止尝试`() {
        // Dart: if (_currentIndex >= _playlist.length - 1 && _loopMode != all) break;
        // start=2（c），候选 3,0,1 → 走到 3（队尾）即截断
        val off = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d"),
            currentIndex = 2,
            loopMode = AppLoopMode.OFF,
        )
        assertEquals(listOf(3), off.nextCandidateIndices())

        val all = off.withSongs(loopMode = AppLoopMode.ALL)
        assertEquals(listOf(3, 0, 1), all.nextCandidateIndices())

        // 单曲循环同样受「非列表循环」截断约束（Dart 只排除 all）
        val one = off.withSongs(loopMode = AppLoopMode.ONE)
        assertEquals(listOf(3), one.nextCandidateIndices())
    }

    @Test
    fun `下一首候选_无当前曲时为空`() {
        val q = PlaybackQueue(playlist = testSongs("a", "b"), currentIndex = -1)
        assertTrue(q.nextCandidateIndices().isEmpty())
    }

    // ═══════════════════════════ 索引推进：previous ═══════════════════════════

    @Test
    fun `上一首候选_从当前位往回环状前进直到绕回起点`() {
        val q = PlaybackQueue(playlist = testSongs("a", "b", "c", "d"), currentIndex = 1)
        assertEquals(listOf(0, 3, 2), q.previousCandidateIndices())
    }

    @Test
    fun `上一首候选_不受循环模式影响_off 模式也一路试到队首`() {
        // 与 next 的关键差异：previous 的循环体没有「到队尾/队首截断」的 break。
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c", "d"),
            currentIndex = 3,
            loopMode = AppLoopMode.OFF,
        )
        assertEquals(listOf(2, 1, 0), q.previousCandidateIndices())
    }

    @Test
    fun `上一首候选_单首队列为空`() {
        val q = PlaybackQueue(playlist = testSongs("a"), currentIndex = 0)
        assertTrue(q.previousCandidateIndices().isEmpty())
    }

    // ═══════════════════════════ 边界判定 ═══════════════════════════

    @Test
    fun `下一首边界_空队列直接返回`() {
        assertEquals(NextBoundary.Nothing, PlaybackQueue().nextBoundary())
    }

    @Test
    fun `下一首边界_非循环停在最后一首时提示并暂停`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b"),
            currentIndex = 1,
            loopMode = AppLoopMode.OFF,
        )
        val b = q.nextBoundary()
        assertTrue(b is NextBoundary.HintAndPause)
        assertTrue((b as NextBoundary.HintAndPause).showHint)
    }

    @Test
    fun `下一首边界_单曲循环且仅一首时重播当前曲`() {
        val q = PlaybackQueue(
            playlist = testSongs("a"),
            currentIndex = 0,
            loopMode = AppLoopMode.ONE,
        )
        assertEquals(NextBoundary.RestartSingle, q.nextBoundary())
    }

    @Test
    fun `下一首边界_单曲循环且多首时进入候选循环`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b"),
            currentIndex = 1,
            loopMode = AppLoopMode.ONE,
        )
        assertEquals(NextBoundary.Proceed, q.nextBoundary())
    }

    @Test
    fun `下一首边界_列表循环在最后一首也继续推进`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b"),
            currentIndex = 1,
            loopMode = AppLoopMode.ALL,
        )
        assertEquals(NextBoundary.Proceed, q.nextBoundary())
    }

    @Test
    fun `上一首绕回_列表循环什么都不做_非列表循环重播当前曲`() {
        val base = PlaybackQueue(playlist = testSongs("a"), currentIndex = 0)
        assertEquals(PreviousWrapAction.NoOp, base.withSongs(loopMode = AppLoopMode.ALL).previousWrapAction())
        assertEquals(PreviousWrapAction.RestartCurrent, base.withSongs(loopMode = AppLoopMode.OFF).previousWrapAction())
        assertEquals(PreviousWrapAction.RestartCurrent, base.withSongs(loopMode = AppLoopMode.ONE).previousWrapAction())
    }

    // ═══════════════════════════ 交叉淡化预取下标 ═══════════════════════════

    @Test
    fun `交叉淡化_中间位置取下一首`() {
        val q = PlaybackQueue(playlist = testSongs("a", "b", "c"), currentIndex = 0)
        assertEquals(1, q.nextIndexForCrossfade())
    }

    @Test
    fun `交叉淡化_队尾且列表循环时绕回队首`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c"),
            currentIndex = 2,
            loopMode = AppLoopMode.ALL,
        )
        assertEquals(0, q.nextIndexForCrossfade())
    }

    @Test
    fun `交叉淡化_队尾且非列表循环时没有下一首`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b", "c"),
            currentIndex = 2,
            loopMode = AppLoopMode.OFF,
        )
        assertNull(q.nextIndexForCrossfade())
    }

    @Test
    fun `交叉淡化_空队列或无当前曲时没有下一首`() {
        assertNull(PlaybackQueue().nextIndexForCrossfade())
        assertNull(PlaybackQueue(playlist = testSongs("a"), currentIndex = -1).nextIndexForCrossfade())
    }

    // ═══════════════════════════ 清空 / 定位 / 回写 ═══════════════════════════

    @Test
    fun `清空_队列与原始队列同时清空并报告被移除的当前曲`() {
        val q = queueOf("a", "b")
        val m = q.cleared()

        assertTrue(m.queue.playlist.isEmpty())
        assertTrue(m.queue.originalPlaylist.isEmpty())
        assertEquals(-1, m.queue.currentIndex)
        assertTrue(m.emptied)
        assertEquals("a", m.removedCurrentSong?.id)
        assertTrue(m.structuralChange)
    }

    @Test
    fun `定位到下标_越界时保持不变`() {
        val q = queueOf("a", "b")
        assertEquals(1, q.positionedAt(1).currentIndex)
        assertEquals(0, q.positionedAt(5).currentIndex)
        assertEquals(0, q.positionedAt(-2).currentIndex)
    }

    @Test
    fun `回写当前曲_按下标替换而不按 id 查找`() {
        val q = PlaybackQueue(
            playlist = testSongs("a", "b"),
            originalPlaylist = testSongs("a", "b"),
            currentIndex = 1,
        )
        // 传入的是一首 id 完全不同的歌：按 id 查找会 miss，按下标写入才会生效
        val next = q.replaceCurrent(testSong("resolved"))
        assertEquals("resolved", next.playlist[1].id)
        assertEquals("a", next.playlist[0].id)
    }

    @Test
    fun `回写当前曲_无当前曲时保持不变`() {
        val q = PlaybackQueue(playlist = testSongs("a"), currentIndex = -1)
        assertEquals(q, q.replaceCurrent(testSong("x")))
    }

    // ═══════════════════════════ shouldHintQueueEnd ═══════════════════════════

    @Test
    fun `队尾提示_仅非循环模式停在最后一首时为真`() {
        assertTrue(shouldHintQueueEnd(AppLoopMode.OFF, currentIndex = 1, playlistLength = 2))
        assertTrue(shouldHintQueueEnd(AppLoopMode.OFF, currentIndex = 4, playlistLength = 5))
        // 非 off 一律不提示
        assertFalse(shouldHintQueueEnd(AppLoopMode.ALL, currentIndex = 1, playlistLength = 2))
        assertFalse(shouldHintQueueEnd(AppLoopMode.ONE, currentIndex = 1, playlistLength = 2))
        // 不在队尾
        assertFalse(shouldHintQueueEnd(AppLoopMode.OFF, currentIndex = 0, playlistLength = 2))
        // 空队列
        assertFalse(shouldHintQueueEnd(AppLoopMode.OFF, currentIndex = 0, playlistLength = 0))
        assertFalse(shouldHintQueueEnd(AppLoopMode.OFF, currentIndex = -1, playlistLength = 0))
    }

    @Test
    fun `队尾提示_在 HintAndPause 分支内恒为真`() {
        // `next()` 的 HintAndPause 分支已把 loopMode 限定为 OFF，
        // 而 shouldHintQueueEnd 只在非 off 时返回 false —— 两者叠加后 showHint 恒真。
        for (n in 1..6) {
            val q = PlaybackQueue(
                playlist = testSongs(*(0 until n).map { "s$it" }.toTypedArray()),
                currentIndex = n - 1,
                loopMode = AppLoopMode.OFF,
            )
            val boundary = q.nextBoundary()
            assertTrue("n=$n 应为 HintAndPause", boundary is NextBoundary.HintAndPause)
            assertTrue("n=$n showHint 应为真", (boundary as NextBoundary.HintAndPause).showHint)
        }
    }

    // ═══════════════════════════ 值语义 ═══════════════════════════

    @Test
    fun `不可变性_转换不修改原队列`() {
        val original = queueOf("a", "b")
        val snapshotPlaylist = original.playlist
        val snapshotIndex = original.currentIndex

        original.append(listOf(testSong("c")))
        original.removeAt(0)
        original.toggledShuffle(Random(1))
        original.sortWith(PlaylistSortBy.TITLE)
        original.cleared()

        assertEquals(listOf("a", "b"), idsOf(original.playlist))
        assertEquals(snapshotPlaylist, original.playlist)
        assertEquals(snapshotIndex, original.currentIndex)
        assertEquals(AppLoopMode.OFF, original.loopMode)
        assertFalse(original.shuffleEnabled)
    }

    @Test
    fun `队列相等性_逐字段比较`() {
        val a = queueOf("a", "b")
        val b = PlaybackQueue(
            playlist = testSongs("a", "b"),
            originalPlaylist = testSongs("a", "b"),
            currentIndex = 0,
        )
        assertEquals(a, b)
        assertFalse(a == a.copy(currentIndex = 1))
        assertFalse(a == a.copy(loopMode = AppLoopMode.ALL))
        assertFalse(a == a.copy(shuffleEnabled = true))
        assertNotNull(a.hashCode())
    }
}
