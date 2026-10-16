package com.gracemusic.player.engine

import androidx.media3.exoplayer.AudioFocusManager
import com.gracemusic.player.gate.AudioFocusEventListener
import com.gracemusic.player.gate.AudioFocusEventSource
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/**
 * [AudioFocusEventSource] 的生产实现：委托 just_audio fork 的
 * `AudioFocusManager` 静态入口。
 *
 * ## fork 落点（逐条对位，均在本仓库 vendored 源码内）
 * | 本类方法 | fork 入口 | 源码位置 |
 * |---|---|---|
 * | [addListener] | `AudioFocusManager.addAudioFocusEventListener` | `AudioFocusManager.java:176-181` |
 * | [removeListener] | `AudioFocusManager.removeAudioFocusEventListener` | `:183-185` |
 * | [setIgnoreAudioFocus] | `AudioFocusManager.setIgnoreAudioFocus` | `:199-201` |
 * | [setForceKeepPlaying] | `AudioFocusManager.setForceKeepPlaying` | `:208-210` |
 * | [setForcedWillPauseWhenDucked] | `AudioFocusManager.setForcedWillPauseWhenDucked` | `:191-193` |
 *
 * ## 为什么必须走 fork 而不能退回 Maven media3
 * Maven 版 media3 1.4.1 的 `AudioFocusManager` **没有**上述四个 static 入口
 * （fork 改动第 1 条：「将焦点事件暴露给宿主」，见
 * `native/media3fork/build.gradle.kts` 顶部注释）。退回 Maven 会让三模式运行时
 * 完全无法实现。工程已有门禁测试
 * `AudioEngineFactoryTest.forkCustomizationsRemainAvailable` 防止误换。
 *
 * ## 监听器适配（为什么需要 [forkListeners] 映射）
 * fork 的 `AudioFocusManager.AudioFocusEventListener` 与本工程的
 * [AudioFocusEventListener] 是**两个不同的类型**（前者是 vendored Java 接口，
 * 后者是 Kotlin 端口契约）。fork 的 `addAudioFocusEventListener` 用
 * `List.contains` 去重、`removeAudioFocusEventListener` 用 `List.remove`
 * 移除，**都依赖同一对象实例**，因此不能每次调用现造 lambda——必须缓存
 * 「端口监听器 → fork 适配器」的对应关系，否则注销会静默失败，
 * 留下一个永久持有宿主引用的静态监听（进程级泄漏）。
 *
 * ## 线程
 * fork 的回调由 Media3 的 `eventHandler`（主线程 Handler）post 而来，故
 * [AudioFocusEventListener.onAudioFocusChanged] 恒在主线程。
 * 映射用 [ConcurrentHashMap] 只为防御性（生产装配/拆卸都在主线程）。
 *
 * ## 静态标志的进程级语义（重要）
 * fork 的 `ignoreAudioFocus` / `forceKeepPlaying` / `forcedWillPauseWhenDucked`
 * 都是**进程级 static**。辅引擎不请求焦点（[EngineRole.AUX] 不下发音频属性），
 * 故只需对主引擎语义生效——本类不做引擎区分。
 */
@Singleton
class Media3AudioFocusEventSource @Inject constructor() : AudioFocusEventSource {

    /** 端口监听器 → fork 适配器（注销时必须用同一实例，见类 KDoc）。 */
    private val forkListeners =
        ConcurrentHashMap<AudioFocusEventListener, AudioFocusManager.AudioFocusEventListener>()

    override fun addListener(listener: AudioFocusEventListener) {
        val fork = forkListeners.getOrPut(listener) {
            AudioFocusManager.AudioFocusEventListener { focusChange ->
                listener.onAudioFocusChanged(focusChange)
            }
        }
        AudioFocusManager.addAudioFocusEventListener(fork)
    }

    override fun removeListener(listener: AudioFocusEventListener) {
        val fork = forkListeners.remove(listener) ?: return
        AudioFocusManager.removeAudioFocusEventListener(fork)
    }

    override fun setIgnoreAudioFocus(ignore: Boolean) {
        AudioFocusManager.setIgnoreAudioFocus(ignore)
    }

    override fun setForceKeepPlaying(keepPlaying: Boolean) {
        AudioFocusManager.setForceKeepPlaying(keepPlaying)
    }

    override fun setForcedWillPauseWhenDucked(force: Boolean?) {
        AudioFocusManager.setForcedWillPauseWhenDucked(force)
    }
}
