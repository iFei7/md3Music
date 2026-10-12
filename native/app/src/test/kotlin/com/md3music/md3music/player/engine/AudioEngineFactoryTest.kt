package com.md3music.md3music.player.engine

import android.app.Application
import android.content.Context
import androidx.media3.common.C
import androidx.media3.decoder.flac.FlacLibrary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * 播放引擎工厂冒烟测试。
 *
 * 目的不是验证音频输出（需真机），而是锁住三件容易静默退化的事：
 * 1. 引擎能在给定配置下构建出来，主/辅角色的音频会话语义正确；
 * 2. **fork 的 media3 定制 API 仍存在**——若有人把依赖从 `:media3fork` 换回 Maven
 *    media3（同为 1.4.1 但缺失 9 处改动），本测试会失败（见 forkCustomizationsRemainAvailable）；
 * 3. 缓冲参数默认值与 Dart 侧显式配置逐项一致（防迁移期数值漂移）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class AudioEngineFactoryTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    private fun factory() = AudioEngineFactory(context)

    @Test
    fun `主引擎可构建且角色为 MAIN`() {
        factory().create(AudioEngineConfig(role = EngineRole.MAIN)).use { engine ->
            assertNotNull(engine.player)
            assertEquals(EngineRole.MAIN, engine.role)
        }
    }

    @Test
    fun `主引擎的 flac 扩展可用性与配置_so 状态保持一致`() {
        factory().create(AudioEngineConfig(enableFlacExtension = false)).use { engine ->
            assertFalse("配置关闭时不得挂载 flac 扩展渲染器", engine.flacExtensionAvailable)
        }
        factory().create(AudioEngineConfig(enableFlacExtension = true)).use { engine ->
            assertEquals(
                "可用性必须等于「配置开启 AND so 可加载」",
                FlacLibrary.isAvailable(),
                engine.flacExtensionAvailable,
            )
        }
    }

    @Test
    fun `关闭蝰蛇母带时仍可构建`() {
        factory().create(AudioEngineConfig(enableViperMaster = false)).use { engine ->
            assertNotNull(engine.player)
        }
    }

    @Test
    fun `辅引擎复用主引擎的音频会话 id`() {
        factory().create(AudioEngineConfig(role = EngineRole.MAIN)).use { main ->
            val shared = if (main.audioSessionId > 0) main.audioSessionId else FALLBACK_SESSION_ID
            factory()
                .create(AudioEngineConfig(role = EngineRole.AUX), sharedAudioSessionId = shared)
                .use { aux ->
                    assertEquals(shared, aux.audioSessionId)
                    assertEquals(
                        "辅引擎底层播放器必须真正持有共享的 sessionId",
                        shared,
                        aux.player.audioSessionId,
                    )
                    assertEquals(EngineRole.AUX, aux.role)
                }
        }
    }

    @Test
    fun `辅引擎缺少共享会话 id 时拒绝构建`() {
        assertThrows(IllegalArgumentException::class.java) {
            factory().create(AudioEngineConfig(role = EngineRole.AUX))
        }
    }

    @Test
    fun `缓冲参数默认值与 Dart 侧显式配置逐项一致`() {
        val config = LoadControlConfig()
        assertEquals(15_000, config.minBufferMs)
        assertEquals(60_000, config.maxBufferMs)
        assertEquals(2_000, config.playbackBufferMs)
        assertEquals(5_000, config.afterRebufferBufferMs)
        // just_audio Dart 侧默认（just_audio.dart:2548-2556）
        assertFalse(config.prioritizeTimeOverSizeThresholds)
        assertEquals(0, config.backBufferMs)
        assertEquals(null, config.targetBufferBytes)
    }

    @Test
    fun `非法缓冲参数被拒绝`() {
        assertThrows(IllegalArgumentException::class.java) {
            LoadControlConfig(minBufferMs = 0)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LoadControlConfig(minBufferMs = 60_000, maxBufferMs = 15_000)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LoadControlConfig(targetBufferBytes = 0)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LoadControlConfig(backBufferMs = -1)
        }
    }

    @Test
    fun `自定义缓冲参数被引擎接受`() {
        val config = AudioEngineConfig(
            loadControl = LoadControlConfig(
                minBufferMs = 30_000,
                maxBufferMs = 120_000,
                playbackBufferMs = 3_000,
                afterRebufferBufferMs = 8_000,
                prioritizeTimeOverSizeThresholds = true,
                backBufferMs = 10_000,
                targetBufferBytes = 1 shl 20,
            ),
        )
        factory().create(config).use { engine ->
            assertNotNull(engine.player)
        }
    }

    @Test
    fun `DSP 控制面暴露 10 段频率表`() {
        assertEquals(10, ViperMasterControl.BAND_COUNT)
        val frequencies = ViperMasterControl.bandFrequencies
        assertEquals(ViperMasterControl.BAND_COUNT, frequencies.size)
        for (i in 1 until frequencies.size) {
            assertTrue(
                "频段中心频率必须严格递增：${frequencies.toList()}",
                frequencies[i] > frequencies[i - 1],
            )
        }
        assertTrue(ViperMasterControl.MIN_GAIN_DB < 0f)
        assertTrue(ViperMasterControl.MAX_GAIN_DB > 0f)
    }

    @Test
    fun `DSP 控制面忽略长度非法的增益并被复位清除`() {
        assertFalse(
            "长度不等于 10 的增益必须被忽略（fork 容错语义）",
            ViperMasterControl.setGains(FloatArray(ViperMasterControl.BAND_COUNT - 1)),
        )
        assertTrue(ViperMasterControl.setGains(FloatArray(ViperMasterControl.BAND_COUNT)))

        ViperMasterControl.setEnabled(true)
        assertTrue(ViperMasterControl.isEnabled)

        ViperMasterControl.reset()
        assertFalse(ViperMasterControl.isEnabled)
    }

    /**
     * 门禁：fork 对 vendored media3 的定制必须仍在类路径上。
     *
     * 这些成员只存在于 fork 的本地源码版 media3，Maven 版（同为 1.4.1）没有。
     * 若有人把 `:media3fork` 换回 Maven 依赖，本测试立即失败。
     */
    @Test
    fun forkCustomizationsRemainAvailable() {
        val focusManager = Class.forName("androidx.media3.exoplayer.AudioFocusManager")
        assertNotNull(
            "缺 AudioFocusManager.setIgnoreAudioFocus（fork 焦点事件暴露）",
            focusManager.getMethod("setIgnoreAudioFocus", Boolean::class.javaPrimitiveType),
        )
        assertNotNull(
            "缺 AudioFocusManager.setForceKeepPlaying（「保持播放与音量」模式）",
            focusManager.getMethod("setForceKeepPlaying", Boolean::class.javaPrimitiveType),
        )
        assertNotNull(
            "缺 AudioFocusManager.setForcedWillPauseWhenDucked（Dart 三模式）",
            focusManager.getMethod("setForcedWillPauseWhenDucked", Boolean::class.javaObjectType),
        )

        val mediaSessionCompat = Class.forName("androidx.media3.session.legacy.MediaSessionCompat")
        assertNotNull(
            "缺 MediaSessionCompat.resendVivoLrcChange（vivo 车载歌词注入）",
            mediaSessionCompat.getMethod(
                "resendVivoLrcChange",
                String::class.java,
                String::class.java,
            ),
        )
        assertNotNull(
            "缺 MediaSessionCompat.VMM_LYRIC_KEY（原子随身听歌词键）",
            mediaSessionCompat.getDeclaredField("VMM_LYRIC_KEY"),
        )

        val legacyConversions = Class.forName("androidx.media3.session.LegacyConversions")
        assertNotNull(
            "缺 LegacyConversions.VMM_SUPPORT_EVENT_KEY（原子随身听能力位，仅 vivo 写入）",
            legacyConversions.getDeclaredField("VMM_SUPPORT_EVENT_KEY"),
        )
        assertNotNull(
            "缺 LegacyConversions.VMM_SUPPORT_EVENT_VALUE",
            legacyConversions.getDeclaredField("VMM_SUPPORT_EVENT_VALUE"),
        )
    }

    /**
     * 息屏保活级别回归测试。
     *
     * media3 的 `wakeMode` **默认为 `C.WAKE_MODE_NONE`**（`ExoPlayer.java:700`），
     * 此时 `ExoPlayerImpl` 会把内部 `WakeLockManager` / `WifiLockManager` 全部关闭
     * （`ExoPlayerImpl.java:433-436`），息屏后 CPU 与 Wi-Fi 都会被系统挂起。
     * lite 因此不得不手工持 `PARTIAL_WAKE_LOCK` + `WIFI_MODE_FULL_HIGH_PERF`
     * （`AudioPlaybackService.kt:418-455`），现象是"息屏后台切歌像断网"。
     *
     * 本测试锁住"默认配置必须开启 WAKE_MODE_NETWORK"，防止这条链路被静默退回 NONE
     * （编译器不会报错，真机表现是偶发的切歌失败，极难定位）。
     */
    @Test
    fun `默认配置开启息屏网络保活`() {
        factory().create(AudioEngineConfig(role = EngineRole.MAIN)).use { engine ->
            assertEquals(
                "默认必须为 WAKE_MODE_NETWORK：否则息屏后不持 WakeLock/WifiLock",
                C.WAKE_MODE_NETWORK,
                engine.wakeMode,
            )
            assertEquals(2, C.WAKE_MODE_NETWORK)
        }
    }

    @Test
    fun `三个保活级别的取值被钉死_防误配成只持 CPU 锁的 LOCAL`() {
        assertEquals(0, C.WAKE_MODE_NONE)
        assertEquals(1, C.WAKE_MODE_LOCAL)
        assertEquals(
            "LOCAL 只持 CPU 锁、不持 Wi-Fi 锁——正是 lite 注释里「像断网」的故障模式",
            2,
            C.WAKE_MODE_NETWORK,
        )
        assertEquals(
            "默认必须是 NETWORK（同时持 CPU 锁与 Wi-Fi 锁）",
            C.WAKE_MODE_NETWORK,
            AudioEngineConfig.DEFAULT_WAKE_MODE,
        )
    }

    @Test
    fun `可显式关闭保活并如实反映在引擎事实上`() {
        factory().create(
            AudioEngineConfig(role = EngineRole.MAIN, wakeMode = C.WAKE_MODE_NONE),
        ).use { engine ->
            assertEquals(C.WAKE_MODE_NONE, engine.wakeMode)
        }
    }

    private companion object {
        /** Robolectric 下 generateAudioSessionId 可能返回 0，此时用固定正数验证复用语义。 */
        const val FALLBACK_SESSION_ID = 4242
    }
}
