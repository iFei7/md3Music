package com.gracemusic.player.engine

/**
 * 蝰蛇母带 DSP 的原生控制门面。
 *
 * 原生版不再有 MethodChannel，设置层（DataStore）与 UI 直接调用本对象即可。
 * 本对象是对 [ViperMasterProcessor] **静态控制面**的薄封装，不持有可能泄漏的引用：
 * DSP 处理器由引擎在音频线程创建/销毁，控制面通过弱引用静态实例表广播，
 * 因此调用方无需感知播放器生命周期（播放器重建后新实例会在构造时吸收全局状态）。
 *
 * 语义与 fork 保持一致：
 * - 开关与增益均为**全局**状态，广播给所有存活实例；
 * - 增益长度不等于 [BAND_COUNT] 时**忽略**（不抛异常、不改状态），与
 *   `ViperMasterProcessor.setGlobalEqGains` 的容错行为一致；
 * - dB 钳位（±12dB）由 [ViperMasterChain.setGains] 内部完成，此处不重复钳位。
 *
 * 证据：`third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/
 * ViperMasterProcessor.java:49-75`（setGlobalEnabled / setGlobalEqGains）
 * 与 `ViperMasterChain.java:30-31`（MIN_GAIN_DB / MAX_GAIN_DB）。
 */
object ViperMasterControl {

    /** 参量均衡段数（10 段）。 */
    const val BAND_COUNT: Int = ViperMasterProcessor.BAND_COUNT

    /** 各段中心频率（Hz）。返回副本，避免调用方改写 DSP 内部常量。 */
    val bandFrequencies: FloatArray
        get() = ViperMasterChain.BAND_FREQUENCIES.copyOf()

    /** 每段增益下限（dB）。 */
    const val MIN_GAIN_DB: Float = ViperMasterChain.MIN_GAIN_DB

    /** 每段增益上限（dB）。 */
    const val MAX_GAIN_DB: Float = ViperMasterChain.MAX_GAIN_DB

    /** 当前是否启用母带处理（进程内全局开关）。 */
    @Volatile
    var isEnabled: Boolean = false
        private set

    /**
     * 开启/关闭母带处理链。
     *
     * 关闭时链路进入排空/暖机路径（内容顺序守恒，仅引入 [ViperMasterChain.LOOKAHEAD] 帧延迟），
     * 不做任何增益与限幅。
     */
    fun setEnabled(enabled: Boolean) {
        isEnabled = enabled
        ViperMasterProcessor.setGlobalEnabled(enabled)
    }

    /**
     * 设置 10 段增益（dB）。长度不等于 [BAND_COUNT] 时忽略本次调用。
     *
     * @return 是否已受理（false 表示参数长度非法被忽略）。
     */
    fun setGains(gainsDb: FloatArray): Boolean {
        if (gainsDb.size != BAND_COUNT) {
            return false
        }
        ViperMasterProcessor.setGlobalEqGains(gainsDb)
        return true
    }

    /** 关闭母带处理并清零全部段增益。 */
    fun reset() {
        setEnabled(false)
        setGains(FloatArray(BAND_COUNT))
    }
}
