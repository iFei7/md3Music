package com.gracemusic.player.engine

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer

/**
 * 已构建的播放引擎。
 *
 * 刻意不实现任何生命周期以外的行为：播放控制、状态机、闸门都归属于上层
 * （`player/gate` + T45 的 PlaybackStore），本类只承载"引擎实例 + 构建期确定的事实"，
 * 以便上层在不重新构建引擎的前提下读取这些事实。
 *
 * @property player 已构建的 ExoPlayer 实例（主/辅角色由 [role] 区分）。
 * @property role 引擎角色。
 * @property audioSessionId 本引擎的音频会话 id；[androidx.media3.common.C.AUDIO_SESSION_ID_UNSET]
 *   表示未能生成/设置（由 media3 自行管理）。辅引擎恒等于主引擎的 id。
 * @property flacExtensionAvailable 本次构建是否挂载了 libflac 扩展渲染器
 *   （配置要求 + `libflacJNI.so` 可加载，两者同时满足才为 true）。
 * @property wakeMode 本次构建采用的息屏保活级别（[AudioEngineConfig.wakeMode]）。
 *   暴露为构建期事实而非仅写进 Builder：media3 的 `ExoPlayer` 没有 `getWakeMode()` 访问器，
 *   若不在这里留存，"息屏保活是否真的开着"就只能靠真机息屏复现来验证。
 */
@OptIn(UnstableApi::class)
class AudioEngine internal constructor(
    val player: ExoPlayer,
    val role: EngineRole,
    val audioSessionId: Int,
    val flacExtensionAvailable: Boolean,
    val wakeMode: Int,
) : AutoCloseable {

    /** 释放底层播放器。重复调用是安全的（media3 的 release 幂等）。 */
    override fun close() {
        player.release()
    }
}
