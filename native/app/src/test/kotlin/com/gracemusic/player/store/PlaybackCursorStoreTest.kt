package com.gracemusic.player.store

import android.content.Context
import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.queue.PlaybackQueue
import com.gracemusic.player.state.PlaybackState
import com.gracemusic.testutil.testSong
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * 播放状态持久化测试（T-P1-10）。
 *
 * 分三层：
 * 1. [SharedPreferencesPlaybackCursorStore] —— 真实 SharedPreferences（Robolectric）
 *    的读写、版本门、损坏容错、连续写入、flush；
 * 2. [PersistenceCoordinator] —— 值去重、失败不伪装成功；
 * 3. [shouldSkipRestoredSong] / [shouldSkipRestoredQueue] —— 幽灵歌曲守卫（纯函数）。
 */
@RunWith(RobolectricTestRunner::class)
class PlaybackCursorStoreTest {

    private fun newStore(): SharedPreferencesPlaybackCursorStore {
        val context = RuntimeEnvironment.getApplication()
        // 每个用例前清空：Robolectric 的 prefs 在同一 JVM 内跨用例共享。
        context.getSharedPreferences("gracemusic_player_state", Context.MODE_PRIVATE)
            .edit().clear().commit()
        return SharedPreferencesPlaybackCursorStore(context, UnconfinedTestDispatcher())
    }

    private fun cursor(
        queue: PlaybackQueue = queueOf("a", "b", "c"),
        positionMs: Long = 12_345,
        volume: Double = 0.8,
    ) = PersistedPlaybackCursor(
        queue = queue,
        position = positionMs.milliseconds,
        volume = volume,
    )

    private fun queueOf(vararg ids: String, currentIndex: Int = 0): PlaybackQueue {
        val songs = ids.map { testSong(it) }
        return PlaybackQueue(
            playlist = songs,
            originalPlaylist = songs,
            currentIndex = currentIndex,
            shuffleEnabled = false,
            loopMode = AppLoopMode.ALL,
        )
    }

    // ═══════════════════ SharedPreferences 实现 ═══════════════════

    @Test
    fun `save 后 restore 得到等价快照`() = runTest {
        val store = newStore()
        val snapshot = cursor()

        store.save(snapshot)
        val restored = store.restore()!!

        assertEquals(listOf("a", "b", "c"), restored.queue.playlist.map { it.id })
        assertEquals(0, restored.queue.currentIndex)
        assertEquals(AppLoopMode.ALL, restored.queue.loopMode)
        assertEquals(12_345, restored.position.inWholeMilliseconds)
        assertEquals(0.8, restored.volume, 0.0001)
        assertEquals(PlaybackCursorStore.CURRENT_DATA_VERSION, restored.dataVersion)
    }

    @Test
    fun `无数据时 restore 返回 null`() = runTest {
        assertNull(newStore().restore())
    }

    @Test
    fun `clear 后 restore 返回 null`() = runTest {
        val store = newStore()
        store.save(cursor())

        store.clear()

        assertNull(store.restore())
    }

    @Test
    fun `版本不匹配时 restore 返回 null`() = runTest {
        val context = RuntimeEnvironment.getApplication()
        val store = SharedPreferencesPlaybackCursorStore(context, UnconfinedTestDispatcher())
        store.save(cursor())
        // 手工写入一个未来版本号，模拟「旧版本数据」。
        context.getSharedPreferences("gracemusic_player_state", Context.MODE_PRIVATE)
            .edit().putInt("player_state_data_version", 99).commit()

        assertNull(store.restore())
    }

    @Test
    fun `连续快速写入_最后一次生效`() = runTest {
        val store = newStore()

        store.save(cursor(positionMs = 1_000))
        store.save(cursor(positionMs = 2_000))
        store.save(cursor(positionMs = 3_000))
        store.flush()

        assertEquals(3_000, store.restore()!!.position.inWholeMilliseconds)
    }

    @Test
    fun `flush 返回后写入已可见`() = runTest {
        val store = newStore()
        store.save(cursor(positionMs = 777))

        store.flush()

        assertEquals(777, store.restore()!!.position.inWholeMilliseconds)
    }

    @Test
    fun `队列 JSON 损坏时 restore 返回 null 不抛异常`() = runTest {
        val context = RuntimeEnvironment.getApplication()
        val store = SharedPreferencesPlaybackCursorStore(context, UnconfinedTestDispatcher())
        store.save(cursor())
        context.getSharedPreferences("gracemusic_player_state", Context.MODE_PRIVATE)
            .edit().putString("player_playlist", "{broken").commit()

        assertNull(store.restore())
    }

    @Test
    fun `音量与位置分别持久化`() = runTest {
        val store = newStore()
        store.save(cursor(positionMs = 0, volume = 1.0))

        val restored = store.restore()!!

        assertEquals(0, restored.position.inWholeMilliseconds)
        assertEquals(1.0, restored.volume, 0.0001)
    }

    // ═══════════════════ 协调器 ═══════════════════

    @Test
    fun `协调器_相同快照不重复写入`() = runTest {
        val backing = RecordingCursorStore()
        val scope = TestScope(UnconfinedTestDispatcher())
        val coordinator = PersistenceCoordinator(backing, scope)
        val state = PlaybackState(queue = queueOf("a"), position = 5.milliseconds, volume = 0.5)

        coordinator.persistCursor(state)
        coordinator.persistCursor(state)
        coordinator.persistCursor(state.copy(volume = 0.5)) // 值等价

        assertEquals(1, backing.saveCount)
    }

    @Test
    fun `协调器_状态变化触发新写入`() = runTest {
        val backing = RecordingCursorStore()
        val scope = TestScope(UnconfinedTestDispatcher())
        val coordinator = PersistenceCoordinator(backing, scope)

        coordinator.persistCursor(PlaybackState(queue = queueOf("a"), volume = 0.5))
        coordinator.persistCursor(PlaybackState(queue = queueOf("a"), volume = 0.7))

        assertEquals(2, backing.saveCount)
    }

    @Test
    fun `协调器_写入失败不抛出且不伪装成功`() = runTest {
        val backing = RecordingCursorStore(failOnSave = true)
        val scope = TestScope(UnconfinedTestDispatcher())
        val coordinator = PersistenceCoordinator(backing, scope)

        // 不抛异常（协调器吞掉并记日志）。
        coordinator.persistCursor(PlaybackState(queue = queueOf("a")))
        scope.testScheduler.runCurrent()

        assertEquals(1, backing.saveCount)
        // 失败后 lastSaved 已推进（不重试）——下一轮「不同状态」才会再写。
        coordinator.persistCursor(PlaybackState(queue = queueOf("a")))
        assertEquals(1, backing.saveCount)
    }

    @Test
    fun `协调器_clear 后重置去重基线`() = runTest {
        val backing = RecordingCursorStore()
        val scope = TestScope(UnconfinedTestDispatcher())
        val coordinator = PersistenceCoordinator(backing, scope)
        val state = PlaybackState(queue = queueOf("a"))

        coordinator.persistCursor(state)
        coordinator.clear()
        coordinator.persistCursor(state)

        assertEquals(2, backing.saveCount)
        assertEquals(1, backing.clearCount)
    }

    // ═══════════════════ 幽灵歌曲守卫 ═══════════════════

    @Test
    fun `幽灵守卫_在线曲不跳过`() {
        assertFalse(shouldSkipRestoredSong(testSong("a"), fileExists = { false }))
    }

    @Test
    fun `幽灵守卫_云盘曲不跳过`() {
        assertFalse(shouldSkipRestoredSong(testSong("a", isCloud = true), fileExists = { false }))
    }

    @Test
    fun `幽灵守卫_本地曲文件存在则不跳过`() {
        val song = testSong("a", isOnline = false, localPath = "/music/a.flac")

        assertFalse(shouldSkipRestoredSong(song) { true })
    }

    @Test
    fun `幽灵守卫_本地曲文件缺失则跳过`() {
        val song = testSong("a", isOnline = false, localPath = "/music/a.flac")

        assertTrue(shouldSkipRestoredSong(song) { false })
    }

    @Test
    fun `幽灵守卫_本地曲无路径则跳过`() {
        assertTrue(shouldSkipRestoredSong(testSong("a", isOnline = false), fileExists = { true }))
    }

    @Test
    fun `幽灵守卫_无当前曲则跳过`() {
        assertTrue(shouldSkipRestoredSong(null, fileExists = { true }))
    }

    @Test
    fun `幽灵守卫_队列按当前曲判定`() {
        val songs = listOf(testSong("a", isOnline = false, localPath = "/music/a.flac"))
        val queue = PlaybackQueue(
            playlist = songs,
            originalPlaylist = songs,
            currentIndex = 0,
        )

        assertTrue(shouldSkipRestoredQueue(queue) { false })
        assertFalse(shouldSkipRestoredQueue(queue) { true })
    }

    // ═══════════════════ fake ═══════════════════

    private class RecordingCursorStore(private val failOnSave: Boolean = false) : PlaybackCursorStore {
        var saveCount = 0
        var clearCount = 0
        var flushCount = 0
        private var stored: PersistedPlaybackCursor? = null

        override suspend fun save(cursor: PersistedPlaybackCursor) {
            saveCount++
            if (failOnSave) throw java.io.IOException("模拟磁盘写失败")
            stored = cursor
        }

        override suspend fun flush() {
            flushCount++
        }

        override suspend fun restore(): PersistedPlaybackCursor? = stored

        override suspend fun clear() {
            clearCount++
            stored = null
        }
    }
}
