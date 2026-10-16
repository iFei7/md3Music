package com.gracemusic.player.offline

import android.app.Application
import android.content.Context
import androidx.media3.datasource.cache.SimpleCache
import com.gracemusic.data.model.Song
import com.gracemusic.player.engine.AudioEngineConfig
import com.gracemusic.player.engine.AudioEngineFactory
import com.gracemusic.player.engine.EngineRole
import com.gracemusic.player.engine.ExoPlayerPlaybackEngineAdapter
import java.io.File
import java.util.UUID
import kotlin.time.Duration.Companion.seconds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * 引擎接入播放缓存的接线测试（Robolectric + **真** ExoPlayer）。
 *
 * 覆盖三件事：
 * 1. **缓存键与易变 URL 解耦**：`prepare` 构造的 `MediaItem` 必须带上
 *    `customCacheKey = "songId|quality"`（否则每次解析的签名 URL 都会变成新缓存键，
 *    缓存永不命中）；
 * 2. **向后兼容**：`AudioEngineConfig.dataSourceFactory` 默认 `null`，
 *    挂载与不挂载缓存对 `prepare` 的**可观测结果完全一致**；
 * 3. **主线程代价**：把 `PlaybackCacheStore.dataSourceFactory` 传给
 *    `@MainThread` 的引擎构建**不得**触发 `SimpleCache` 构造（磁盘索引加载），
 *    首次构造必须推迟到加载线程上的 `createDataSource()`。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class PlaybackCacheEngineWiringTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    private class InMemorySourceMemory : ResolvedSourceMemory {
        override fun read(key: String): String? = null
        override fun write(key: String, source: String) = Unit
    }

    private fun newStore(dirName: String = "engine-wire-" + UUID.randomUUID()): PlaybackCacheStore =
        PlaybackCacheStore(
            context,
            PlaybackCacheConfig(dirName, maxBytes = 1L shl 20),
            InMemorySourceMemory(),
        )

    private fun song(
        id: String = "song-1",
        isOnline: Boolean = true,
        url: String? = "https://cdn.example.com/audio/abc.mp3?sig=1",
        quality: String? = null,
    ): Song = Song(
        id = id,
        title = "测试曲目",
        artist = "测试歌手",
        album = "测试专辑",
        duration = 240.seconds,
        url = url,
        isOnline = isOnline,
        quality = quality,
    )

    // ------------------------------------------------------------------
    // 缓存键
    // ------------------------------------------------------------------

    @Test
    fun `prepare 时 MediaItem 携带 songId 与默认档的缓存键`() {
        val engine = AudioEngineFactory(context).create(AudioEngineConfig(role = EngineRole.MAIN))
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(id = "o-1", quality = null), null, false)

            assertEquals(
                "拿不到该曲音质档时必须回落 DEFAULT_QUALITY",
                PlaybackCacheKeys.key("o-1", PlaybackCacheKeys.DEFAULT_QUALITY),
                engine.player.currentMediaItem?.localConfiguration?.customCacheKey,
            )
            assertEquals("mediaId 语义不得改变", "o-1", engine.player.currentMediaItem?.mediaId)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `prepare 时优先使用该曲自身音质档作为键`() {
        val engine = AudioEngineFactory(context).create(AudioEngineConfig(role = EngineRole.MAIN))
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(id = "o-2", quality = "320"), null, false)

            assertEquals(
                PlaybackCacheKeys.key("o-2", "320"),
                engine.player.currentMediaItem?.localConfiguration?.customCacheKey,
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `缓存键与签名 URL 解耦_同一首歌不同 URL 得到同一键`() {
        val engine = AudioEngineFactory(context).create(AudioEngineConfig(role = EngineRole.MAIN))
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(
                song(id = "o-3", url = "https://cdn.example.com/a.mp3?sig=111&exp=1"),
                null,
                false,
            )
            val firstKey = engine.player.currentMediaItem?.localConfiguration?.customCacheKey

            adapter.prepare(
                song(id = "o-3", url = "https://cdn.example.com/a.mp3?sig=999&exp=2"),
                null,
                false,
            )
            val secondKey = engine.player.currentMediaItem?.localConfiguration?.customCacheKey

            assertEquals(
                "URL 变化（签名刷新）不得改变缓存键，否则缓存永不命中",
                firstKey,
                secondKey,
            )
            assertEquals(PlaybackCacheKeys.key("o-3", PlaybackCacheKeys.DEFAULT_QUALITY), secondKey)
        } finally {
            adapter.release()
        }
    }

    // ------------------------------------------------------------------
    // 向后兼容
    // ------------------------------------------------------------------

    @Test
    fun `AudioEngineConfig 默认不挂载数据源工厂`() {
        assertNull(
            "默认必须为 null：不调用 setMediaSourceFactory，行为与改造前一致",
            AudioEngineConfig().dataSourceFactory,
        )
    }

    @Test
    fun `挂载缓存数据源工厂后引擎可构建且 prepare 语义不变`() {
        val store = newStore()
        val engine = AudioEngineFactory(context).create(
            AudioEngineConfig(role = EngineRole.MAIN, dataSourceFactory = store.dataSourceFactory),
        )
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(id = "o-4", url = "https://cdn.example.com/x.mp3", quality = "flac"), 3000, true)

            val player = engine.player
            assertEquals("单曲时间线：只允许 1 个媒体项", 1, player.mediaItemCount)
            assertEquals("mediaId 必须等于 song.id", "o-4", player.currentMediaItem?.mediaId)
            assertEquals(
                "URI 必须原样投射（缓存是透明读缓存，不得改写 URI）",
                "https://cdn.example.com/x.mp3",
                player.currentMediaItem?.localConfiguration?.uri.toString(),
            )
            assertEquals(
                "缓存键必须落到 MediaItem",
                PlaybackCacheKeys.key("o-4", "flac"),
                player.currentMediaItem?.localConfiguration?.customCacheKey,
            )
            assertTrue("playWhenReady=true 必须真实下发", player.playWhenReady)
            assertEquals("起始位置必须真实 seek", 3000L, player.currentPosition)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `挂载缓存后拒绝无音源曲目的语义不变`() {
        val store = newStore()
        val engine = AudioEngineFactory(context).create(
            AudioEngineConfig(role = EngineRole.MAIN, dataSourceFactory = store.dataSourceFactory),
        )
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(id = "o-null", url = null), null, true)
            assertEquals("无音源不得投射时间线", 0, engine.player.mediaItemCount)
            assertFalse("不得替用户置起播意图", engine.player.playWhenReady)
        } finally {
            adapter.release()
        }
    }

    // ------------------------------------------------------------------
    // 主线程代价
    // ------------------------------------------------------------------

    @Test
    fun `构建引擎不触发缓存索引加载_首次构造推迟到 createDataSource`() {
        val dirName = "lazy-init-" + UUID.randomUUID()
        val store = newStore(dirName)
        val cacheDir = File(context.cacheDir, dirName)

        assertFalse(
            "前提：构造 store 不触发 SimpleCache",
            SimpleCache.isCacheFolderLocked(cacheDir),
        )

        AudioEngineFactory(context).create(
            AudioEngineConfig(role = EngineRole.MAIN, dataSourceFactory = store.dataSourceFactory),
        ).use { engine ->
            assertNotNull("引擎应构建成功", engine.player)
            assertFalse(
                "把 dataSourceFactory 传给 @MainThread 的引擎构建不得触发 SimpleCache 构造（磁盘索引加载）",
                SimpleCache.isCacheFolderLocked(cacheDir),
            )
        }

        // 首次 createDataSource()（真实场景在 ExoPlayer 的加载线程上）才构造缓存。
        store.dataSourceFactory.createDataSource()
        assertTrue(
            "createDataSource() 之后 SimpleCache 才被构造",
            SimpleCache.isCacheFolderLocked(cacheDir),
        )
    }
}
