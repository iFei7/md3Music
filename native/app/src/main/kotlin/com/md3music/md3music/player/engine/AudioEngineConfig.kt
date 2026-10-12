package com.md3music.md3music.player.engine

/**
 * 音频引擎角色。
 *
 * 一个进程内最多同时存在两个引擎实例（主 + 辅，用于交叉淡化），二者职责不同：
 *
 * - [MAIN]：主播放器。持有音频焦点（以 `handleAudioFocus=true` 下发音频属性）、
 *   创建 Media3 MediaSession（T44）、生成并固定 audioSessionId。
 * - [AUX]：交叉淡化用的备用播放器。**不下发音频属性**——因此永不请求音频焦点。
 *   若辅播放器也请求焦点，同一应用的第二次焦点请求会让主播放器收到 `AUDIOFOCUS_LOSS`，
 *   正在淡出的那一路会被 Media3 直接掐掉。同时辅播放器跳过 MediaSession 创建
 *   （避免系统看到两个活跃媒体会话），并复用主播放器的 audioSessionId
 *   （音量均衡/频谱等作用于 session 的音频效果需对两路同时生效）。
 *
 * 语义依据：`lib/core/services/audio_service_io.dart:244-262`
 * （`androidApplyAudioAttributes: !aux` / 辅播放器跳过 MediaSession / 共享 audioSessionId）。
 */
enum class EngineRole {
    MAIN,
    AUX,
}

/**
 * ExoPlayer 缓冲策略（对应 just_audio 的 `AndroidLoadControl`）。
 *
 * 默认值来源两级：
 * - 未在本类覆盖的字段取 just_audio Dart 侧默认：
 *   `third_party/just_audio/lib/just_audio.dart:2548-2556`
 *   （`prioritizeTimeOverSizeThresholds=false`、`backBufferDuration=Duration.zero`、
 *   `targetBufferBytes=null`）。
 * - 四个时长取本应用显式配置：`lib/core/services/audio_service_io.dart:272-278`。
 *   该配置的注释记录了原因：Hi-Res 码率可达 ~4600kbps，30s 缓冲区（~17MB）在高码率下
 *   极易耗尽，表现为播放到 ~60s 时反复进入 rebuffer 死循环（进度条在 1:00~1:01 弹跳、
 *   无声音）。故 maxBuffer 取 60s、rebuffer 恢复窗口取 5s。
 *
 * @property minBufferMs 最小预缓冲时长（ms），低于此值开始填充。
 * @property maxBufferMs 最大预缓冲时长（ms），高于此值停止填充。
 * @property playbackBufferMs 起播前需缓冲的时长（ms）。
 * @property afterRebufferBufferMs rebuffer（缓冲耗尽）后重新起播需缓冲的时长（ms）。
 * @property prioritizeTimeOverSizeThresholds 时间阈值与体积阈值冲突时优先时间。
 * @property backBufferMs 后向缓冲时长（ms），0 表示不留后向缓冲。
 * @property targetBufferBytes 目标缓冲字节数；null 表示由 Media3 按 `maxBufferMs` 推导。
 */
data class LoadControlConfig(
    val minBufferMs: Int = DEFAULT_MIN_BUFFER_MS,
    val maxBufferMs: Int = DEFAULT_MAX_BUFFER_MS,
    val playbackBufferMs: Int = DEFAULT_PLAYBACK_BUFFER_MS,
    val afterRebufferBufferMs: Int = DEFAULT_AFTER_REBUFFER_BUFFER_MS,
    val prioritizeTimeOverSizeThresholds: Boolean = false,
    val backBufferMs: Int = 0,
    val targetBufferBytes: Int? = null,
) {
    init {
        require(minBufferMs > 0) { "minBufferMs 必须为正：$minBufferMs" }
        require(maxBufferMs >= minBufferMs) {
            "maxBufferMs($maxBufferMs) 不得小于 minBufferMs($minBufferMs)"
        }
        require(playbackBufferMs > 0) { "playbackBufferMs 必须为正：$playbackBufferMs" }
        require(afterRebufferBufferMs > 0) {
            "afterRebufferBufferMs 必须为正：$afterRebufferBufferMs"
        }
        require(backBufferMs >= 0) { "backBufferMs 不得为负：$backBufferMs" }
        require(targetBufferBytes == null || targetBufferBytes > 0) {
            "targetBufferBytes 须为 null 或正整数：$targetBufferBytes"
        }
    }

    companion object {
        /** 本应用显式配置：`audio_service_io.dart:274` */
        const val DEFAULT_MIN_BUFFER_MS = 15_000

        /** 本应用显式配置：`audio_service_io.dart:275` */
        const val DEFAULT_MAX_BUFFER_MS = 60_000

        /** 本应用显式配置：`audio_service_io.dart:276` */
        const val DEFAULT_PLAYBACK_BUFFER_MS = 2_000

        /** 本应用显式配置：`audio_service_io.dart:277` */
        const val DEFAULT_AFTER_REBUFFER_BUFFER_MS = 5_000
    }
}

/**
 * 播放引擎构建配置。
 *
 * @property role 引擎角色（主/辅），决定是否请求音频焦点。
 * @property enableViperMaster 是否挂载蝰蛇母带 DSP 处理链（10 段参量均衡 + 前瞻限幅）。
 * @property enableFlacExtension 是否追加 libflac 扩展渲染器（`libflacJNI.so` 可用时才生效）。
 * @property useLazyPreparation 惰性准备（just_audio Dart 默认 true）。
 * @property handleAudioBecomingNoisy 有线拔出 / 蓝牙断开时自动暂停。
 * @property loadControl 缓冲策略。
 */
data class AudioEngineConfig(
    val role: EngineRole = EngineRole.MAIN,
    val enableViperMaster: Boolean = true,
    val enableFlacExtension: Boolean = true,
    val useLazyPreparation: Boolean = true,
    val handleAudioBecomingNoisy: Boolean = true,
    val loadControl: LoadControlConfig = LoadControlConfig(),
)
