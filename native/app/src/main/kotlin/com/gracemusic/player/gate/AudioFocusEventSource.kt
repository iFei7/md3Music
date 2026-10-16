package com.gracemusic.player.gate

/**
 * 原始音频焦点变化监听器（系统事实，非策略）。
 *
 * 1:1 对位 just_audio fork 的
 * `androidx.media3.exoplayer.AudioFocusManager.AudioFocusEventListener`
 * （`third_party/just_audio/android/src/main/java/androidx/media3/exoplayer/AudioFocusManager.java:167-169`）：
 * 回调参数是**未经转换的** `AudioManager.AUDIOFOCUS_*` 值
 * （`GAIN=1` / `LOSS=-1` / `LOSS_TRANSIENT=-2` / `LOSS_TRANSIENT_CAN_DUCK=-3`），
 * 且**先于** Media3 内置的自动处理（duck / pause / abandon）派发
 * （同文件 `:506-507` 在 `handlePlatformAudioFocusChange` 开头转发）。
 *
 * 之所以必须是「原始值」：三模式策略（[AudioFocusInterruptionMode]）要对
 * `GAIN` 与各类 `LOSS` 做不同处置，Media3 内置处理把这些差异抹平成了
 * 「duck / wait」两态，宿主无法据此还原用户选择的语义。
 */
fun interface AudioFocusEventListener {
    /** 主线程回调；[focusChange] 为 `AudioManager.AUDIOFOCUS_*` 原始值。 */
    fun onAudioFocusChanged(focusChange: Int)
}

/**
 * 音频焦点事件源端口（可注入，便于 JVM 单测）。
 *
 * ## 为什么需要这个端口
 * fork 的焦点入口全是**进程级 static**（`AudioFocusManager.addAudioFocusEventListener` /
 * `setIgnoreAudioFocus` / `setForceKeepPlaying` / `setForcedWillPauseWhenDucked`）。
 * 若 [com.gracemusic.player.store.AudioFocusController] 直接引用 static 入口，
 * 单测就无法在不触碰真实 `AudioManager` 的前提下驱动焦点事件，也无法断言
 * 「标志是否被正确下发」。端口把这四个 static 收敛成可替换的实例方法。
 *
 * ## 单一事实来源（不得绕过）
 * 生产实现（[com.gracemusic.player.engine.Media3AudioFocusEventSource]）是
 * **唯一**允许调用上述 static 入口的地方。任何其它位置直接调用 fork 的静态
 * 焦点 API，都会让「标志同步」出现第二个写者，进而出现双重焦点控制
 * （lite 在 `audio_session` 与 Media3 之间踩过这个坑，
 * 见 `lib/core/services/audio_service_io.dart:647-662` 的 `setActive(false)`）。
 *
 * ## 与 Media3 内置处理的分工（不得重复控制）
 * Media3 的 `AudioFocusManager` **自己**会响应焦点：
 * `GAIN → play`、`LOSS → do not play + abandon`、
 * `LOSS_TRANSIENT(_CAN_DUCK) → wait 或 duck(0.2)`。
 * 宿主策略通过下面三个开关**改写**这一默认行为，而不是另起一套 `AudioManager`
 * 监听（那会造成两个 `OnAudioFocusChangeListener` 各自暂停/恢复）：
 *
 * | 开关 | 语义 | 对位 Dart |
 * |---|---|---|
 * | [setIgnoreAudioFocus] | 完全跳过内置处理（不 duck / 不暂停 / 不 abandon） | `_ignoreAudioFocus` |
 * | [setForceKeepPlaying] | 短暂中断跳过内置处理；独占 `LOSS` 仍让路 | `keepPlayingActive` |
 * | [setForcedWillPauseWhenDucked] | 强制把 `CAN_DUCK` 当 `LOSS_TRANSIENT` 处理（`true`）或保留系统自动 duck（`false`） | `setForceWillPauseWhenDucked` |
 *
 * 依据：`AudioFocusManager.java:213-226` 的 `shouldSkipFocusHandling` 与
 * `:398-406` 的 `willPauseWhenDucked`。
 */
interface AudioFocusEventSource {

    /** 注册原始焦点事件监听（幂等由实现/调用方保证，重复注册同一实例不重复回调）。 */
    fun addListener(listener: AudioFocusEventListener)

    /** 注销监听。 */
    fun removeListener(listener: AudioFocusEventListener)

    /**
     * 「忽略音频焦点」总开关。
     *
     * `true` = 跳过 Media3 内置焦点处理，播放与音量完全保持
     * （对位 F-FOC-002 / F-SET-039「允许与其他应用同时播放音频」）。
     */
    fun setIgnoreAudioFocus(ignore: Boolean)

    /**
     * 「保持播放与音量」开关（短暂中断不暂停、不 duck）。
     *
     * 对位 F-FOC-001 的 `KEEP_PLAYING` 模式；独占型 `LOSS` 不受本开关影响
     * （仍让路暂停，否则对方 App 拿不到焦点）。
     */
    fun setForceKeepPlaying(keepPlaying: Boolean)

    /**
     * 强制 `willPauseWhenDucked`。
     *
     * `true` = 系统派发 `LOSS_TRANSIENT` 而非自动 duck 音量（宿主自行决策）；
     * `false` = 保留 Media3 的系统级自动 duck（0.2 倍音量 + `GAIN` 自动恢复）；
     * `null` = 恢复 Media3 默认（按 `contentType == SPEECH` 判断）。
     */
    fun setForcedWillPauseWhenDucked(force: Boolean?)
}

/**
 * 空实现（不注册监听、不写任何 fork 标志）。
 *
 * **用途仅限测试与降级**：显式表明「本次装配不接焦点运行时」。
 * 生产 DI 必须绑定 [com.gracemusic.player.engine.Media3AudioFocusEventSource]
 * ——若生产误绑本类，`AudioFocusController` 将收不到任何焦点事件，
 * 三模式策略静默失效（见 `di/PlayerModule.provideAudioFocusEventSource` 的绑定说明）。
 */
object NoOpAudioFocusEventSource : AudioFocusEventSource {
    override fun addListener(listener: AudioFocusEventListener) = Unit
    override fun removeListener(listener: AudioFocusEventListener) = Unit
    override fun setIgnoreAudioFocus(ignore: Boolean) = Unit
    override fun setForceKeepPlaying(keepPlaying: Boolean) = Unit
    override fun setForcedWillPauseWhenDucked(force: Boolean?) = Unit
}
