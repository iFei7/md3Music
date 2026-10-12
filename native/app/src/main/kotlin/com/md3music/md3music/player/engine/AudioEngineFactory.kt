package com.md3music.md3music.player.engine

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioManager
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.decoder.flac.FlacLibrary
import androidx.media3.decoder.flac.LibflacAudioRenderer
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink

/**
 * 播放引擎工厂——just_audio fork 引擎构建逻辑的原生化端口。
 *
 * 本类的每一步都对应 `third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/
 * AudioPlayer.java` 的 `ensurePlayerInitialized()`（1003-1105 行），取舍如下：
 *
 * | fork 资产 | 处理 | 证据与理由 |
 * |---|---|---|
 * | `DefaultRenderersFactory` 子类 + `buildAudioSink` 覆写 | **保留并移植** | `AudioPlayer.java:1008-1029`；挂载 DSP 链的唯一注入点 |
 * | 蝰蛇母带 DSP（`ViperMasterProcessor` 链） | **保留并移植** | `AudioPlayer.java:1019-1021`；见 [ViperMasterControl] |
 * | libflac 扩展渲染器 | **保留并移植** | `AudioPlayer.java:1042-1054`；修 MediaCodec FLAC 输入缓冲 64KB 上限导致的大块帧丢帧 |
 * | `drf.setEnableAudioFloatOutput(false)` | **保留** | `AudioPlayer.java:1030-1034`；部分设备 stereo float 播放异常（速度/音高变高） |
 * | `setHandleAudioBecomingNoisy(true)` | **保留** | `AudioPlayer.java:1059-1063`；主/辅均生效 |
 * | LoadControl 调优 | **保留** | `AudioPlayer.java:261-279`；参数默认值见 [LoadControlConfig] |
 * | 固定 audioSessionId | **保留** | `AudioPlayer.java:1071-1084`；系统按 sessionId 与 MediaSession 的关联判定播放器可识别性，未关联时独占型中断会绕过三模式直接暂停 |
 * | `ObserverRenderer` | **不移植** | `AudioPlayer.java:2229-2254`；其唯一职责是"位置停滞 ≥3 帧时立即向 Dart 广播进度事件"。原生版进度由 StateFlow + 进度闸门（`player/gate/PlaybackProgressGate`、`PlaybackStallPolicy`）驱动，无需渲染器侧旁路 |
 * | `NormalizationGainAudioSink` | **不移植（判为死代码）** | 该类全仓无 `wrap()` 调用点（其接线在 `62d8b2f`「整链下线 USB 独占输出」中被移除），`setGainDb` 通道因此成为空操作。音量均衡的**活跃**实现已改为 `LoudnessEnhancer`：正增益走 `LoudnessEnhancer.setTargetGain`，负增益折进播放器音量（`lib/core/services/audio_service_io.dart:381-395`）。原生版按活跃实现落地，见 T45 |
 * | `SpectrumPcmTap` | **不引入** | 提交 `62d8b2f` 的信息声称"新增 SpectrumPcmTap"，但该文件在 fork 中并不存在（全仓零引用）；原生版不引入 |
 * | `registerPlayer` / `sMediaSessionEnabled` 跨实例会话收敛 | **不移植** | 那是 Dart 双引擎下的会话去重手段；原生版由 T44 的单一 `MediaSessionService` 结构上消除该问题 |
 * | `audioOffloadPreferences` / `livePlaybackSpeedControl` | **暂不引入** | Dart 侧未下发这两项（`audio_service_io.dart` 无相关配置），故 fork 分支不会执行；原生版保持与运行态一致 |
 *
 * 音频焦点：主引擎以 `handleAudioFocus=true` 下发音频属性，焦点由 Media3 内建
 * `AudioFocusManager` 管理（fork 已在其中暴露原始焦点事件）。辅引擎**不下发**音频属性，
 * 因此永不请求焦点——否则主引擎会收到 `AUDIOFOCUS_LOSS`，淡出的一路被直接掐掉
 * （`audio_service_io.dart:254-259`）。
 */
@SuppressLint("UnsafeOptInUsageError")
@OptIn(UnstableApi::class)
class AudioEngineFactory(private val context: Context) {

    /**
     * 构建播放引擎。
     *
     * **线程约束**：必须在应用主线程调用。media3 的 `ExoPlayerImpl.setAudioSessionId` 内部有
     * `verifyApplicationThread()` 断言（vendored 源码 `ExoPlayerImpl.java:1521-1523`），
     * `ExoPlayer.Builder.build()` 同样要求主线程。fork 侧的调用点（method channel 回调）也在主线程。
     *
     * @param config 引擎配置。
     * @param sharedAudioSessionId 需要复用的音频会话 id。当 [AudioEngineConfig.role] 为
     *   [EngineRole.AUX] 时必须提供（辅引擎与主引擎共享 session，使作用于 session 的音频效果
     *   在交叉淡化全程对两路同时生效）；为 [EngineRole.MAIN] 时可省略，此时按 fork 逻辑生成
     *   新的固定 sessionId。
     * @throws IllegalArgumentException 辅引擎未提供 [sharedAudioSessionId]。
     */
    fun create(
        config: AudioEngineConfig = AudioEngineConfig(),
        sharedAudioSessionId: Int? = null,
    ): AudioEngine {
        require(config.role == EngineRole.MAIN || sharedAudioSessionId != null) {
            "辅助引擎（AUX）必须复用主引擎的 audioSessionId"
        }

        val flacExtensionAvailable = config.enableFlacExtension && FlacLibrary.isAvailable()
        if (config.enableFlacExtension && !flacExtensionAvailable) {
            // 与 fork 一致的可观测性：so 缺失（例如 armeabi-v7a 无 libflacJNI.so）时静默降级，
            // 只留一条日志，不中断构建。
            Log.i(TAG, "flac extension 不可用（libflacJNI.so 未加载），跳过扩展渲染器")
        } else if (flacExtensionAvailable) {
            Log.i(TAG, "flac extension renderer enabled")
        }

        val player = ExoPlayer.Builder(context, buildRenderersFactory(config, flacExtensionAvailable))
            .setUseLazyPreparation(config.useLazyPreparation)
            .setHandleAudioBecomingNoisy(config.handleAudioBecomingNoisy)
            .setLoadControl(buildLoadControl(config.loadControl))
            .build()

        val audioSessionId = applyAudioSessionId(player, config.role, sharedAudioSessionId)

        if (config.role == EngineRole.MAIN) {
            // handleAudioFocus=true 让 Media3 请求音频焦点；系统自动 duck（VolumeShaper）
            // 只发生在无焦点管理的播放器上。
            player.setAudioAttributes(buildAudioAttributes(), /* handleAudioFocus= */ true)
        }

        return AudioEngine(player, config.role, audioSessionId, flacExtensionAvailable)
    }

    /**
     * 构建渲染器工厂：`DefaultRenderersFactory` 子类（注入 DSP 链） + libflac 扩展渲染器。
     *
     * 与 fork 的差异只有一处：不再追加 `ObserverRenderer`（见类注释的取舍表）。
     */
    private fun buildRenderersFactory(
        config: AudioEngineConfig,
        flacExtensionAvailable: Boolean,
    ): RenderersFactory {
        val drf = object : DefaultRenderersFactory(context) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean,
            ): AudioSink = buildDefaultAudioSink(
                context = context,
                enableFloatOutput = enableFloatOutput,
                enableAudioTrackPlaybackParams = enableAudioTrackPlaybackParams,
                enableViperMaster = config.enableViperMaster,
            )

            /** 供扩展渲染器（libflac）复用同一 sink 构建逻辑。 */
            fun buildAudioSinkForExtension(): AudioSink =
                buildDefaultAudioSink(
                    context = this@AudioEngineFactory.context,
                    enableFloatOutput = false,
                    enableAudioTrackPlaybackParams = false,
                    enableViperMaster = config.enableViperMaster,
                )
        }
        // float 输出统一关闭：由 ExoPlayer 默认把 24/32bit 整数 PCM 降为 16bit
        // （ToInt16PcmAudioProcessor），避免部分设备 stereo float 播放异常。
        drf.setEnableAudioFloatOutput(false)

        return RenderersFactory { eventHandler, videoListener, audioListener, textOutput, metadataOutput ->
            val defaultRenderers =
                drf.createRenderers(eventHandler, videoListener, audioListener, textOutput, metadataOutput)
            if (!flacExtensionAvailable) {
                defaultRenderers
            } else {
                // 扩展渲染器只会在 c2 解码器标记「超出能力」（FLAC 且 maxInputSize>65536）时
                // 被 TrackSelector 选中；其余格式仍优先走 MediaCodec（数组序在前 + 能力更高）。
                defaultRenderers +
                    LibflacAudioRenderer(eventHandler, audioListener, drf.buildAudioSinkForExtension())
            }
        }
    }

    /**
     * 构建 `DefaultAudioSink`，按需追加蝰蛇母带处理链。
     *
     * 参数与 `DefaultRenderersFactory.buildAudioSink`（vendored 源码 640-646 行）逐项一致，
     * 仅追加处理链，确保未启用 DSP 时行为与默认实现完全相同。
     */
    private fun buildDefaultAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioTrackPlaybackParams: Boolean,
        enableViperMaster: Boolean,
    ): AudioSink {
        val builder = DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(enableFloatOutput)
            .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
        if (enableViperMaster) {
            // 处理链位于 silence-skip / sonic 之前；输入恒为 16bit PCM（float 输出已关闭）。
            builder.setAudioProcessorChain(
                DefaultAudioSink.DefaultAudioProcessorChain(ViperMasterProcessor()),
            )
        }
        return builder.build()
    }

    private fun buildLoadControl(config: LoadControlConfig): DefaultLoadControl {
        val builder = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                config.minBufferMs,
                config.maxBufferMs,
                config.playbackBufferMs,
                config.afterRebufferBufferMs,
            )
            .setPrioritizeTimeOverSizeThresholds(config.prioritizeTimeOverSizeThresholds)
            .setBackBuffer(config.backBufferMs, false)
        config.targetBufferBytes?.let { builder.setTargetBufferBytes(it) }
        return builder.build()
    }

    /**
     * 固定音频会话 id。
     *
     * 系统（小米等）按「AudioTrack 的 audioSessionId 是否与 MediaSession 关联」判定播放器
     * 可识别性（hasUid）。未关联时，独占型中断（如 B 站视频 GAIN）会对本播放器强制
     * interruptMusicPlayback 直接暂停，忽略开关与三模式均无法阻止。故须在 AudioTrack 创建前
     * （此时尚未播放）固定 id，MediaSession（T44）会自动同步该 id 到系统。
     *
     * @return 实际使用的 sessionId；[C.AUDIO_SESSION_ID_UNSET] 表示未能设置（交由 media3 自管）。
     */
    private fun applyAudioSessionId(
        player: ExoPlayer,
        role: EngineRole,
        sharedAudioSessionId: Int?,
    ): Int {
        if (role == EngineRole.AUX) {
            val shared = sharedAudioSessionId ?: C.AUDIO_SESSION_ID_UNSET
            if (shared <= 0) {
                // 主引擎也未能固定 sessionId（极端情况）：不设置，交由 media3 自管。
                return C.AUDIO_SESSION_ID_UNSET
            }
            player.setAudioSessionId(shared)
            return shared
        }
        if (sharedAudioSessionId != null && sharedAudioSessionId != C.AUDIO_SESSION_ID_UNSET) {
            player.setAudioSessionId(sharedAudioSessionId)
            return sharedAudioSessionId
        }
        return try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            val generated = audioManager?.generateAudioSessionId() ?: C.AUDIO_SESSION_ID_UNSET
            if (generated > 0) {
                player.setAudioSessionId(generated)
                generated
            } else {
                Log.w(TAG, "generateAudioSessionId 返回 $generated，音频会话 id 交由 media3 自管")
                C.AUDIO_SESSION_ID_UNSET
            }
        } catch (e: RuntimeException) {
            // 与 fork 一致的容错：生成/设置失败不影响引擎构建。
            Log.w(TAG, "setAudioSessionId failed: $e")
            C.AUDIO_SESSION_ID_UNSET
        }
    }

    private fun buildAudioAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .setUsage(C.USAGE_MEDIA)
            .setFlags(0)
            .build()

    private companion object {
        const val TAG = "AudioEngineFactory"
    }
}
