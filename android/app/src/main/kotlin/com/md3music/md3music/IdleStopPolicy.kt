package com.md3music.md3music

/**
 * 批次44：暂停后空闲释放策略（纯逻辑，无 Android 依赖，便于 JVM 单测）。
 *
 * 背景：本服务只承担「FGS 载体 + 保活 + WakeLock」，播放本身由 media3 会话
 * （MD3MusicMediaSessionService）承载。因此服务被停掉不会中断播放能力，下一次
 * 状态变更（通知下发）会重新 startForegroundService 拉起服务，通知随即可用。
 *
 * 但暂停后若永久常驻，会留下「FGS + Flutter 引擎 + 进程」三份后台资源，
 * 用户侧表现为长期耗电、内存与进程常驻。策略：暂停满 N 分钟（默认 10，
 * 0 表示永不）后主动退出前台服务并 stopSelf，让系统回收进程。
 *
 * 为什么不在这里 killProcess：主动杀自己会被多数 ROM 判定为异常退出
 * （crash/exit 记录），触发「后台限制」「后台网络受限」等惩罚性策略，
 * 反而比自然被系统回收更差。stopSelf 后进程由系统按 LRU/内存压力回收，
 * 属正常生命周期，不产生异常退出记录。
 */
class IdleStopPolicy {

    /**
     * 归一化用户配置的分钟数：
     * - null（从未写入/读取失败）→ [DEFAULT_MINUTES]
     * - 负数 → 0（视为关闭，永不释放）
     * - 超过上限 → [MAX_MINUTES]
     *
     * 这里重复一次 clamp 是为了防御 SharedPreferences 被外部写脏值
     * （Flutter 侧虽然也 clamp，但原生不能信任跨进程持久化的数据）。
     */
    fun normalizeMinutes(raw: Int?): Int {
        val value = raw ?: return DEFAULT_MINUTES
        return when {
            value < 0 -> 0
            value > MAX_MINUTES -> MAX_MINUTES
            else -> value
        }
    }

    /**
     * 分钟数换算成 Handler.postDelayed 需要的毫秒数。
     * [minutes] <= 0 表示关闭，返回 0L（调用方不应据此排期）。
     */
    fun delayMs(minutes: Int): Long =
        if (minutes <= 0) 0L else minutes * 60_000L

    /**
     * 是否应当排期空闲释放：只有「未在播放」且「用户开启了释放（minutes > 0）」才排。
     * 播放中永不排期，避免把正在出声的服务停掉。
     */
    fun shouldStop(playing: Boolean, minutes: Int): Boolean =
        !playing && minutes > 0

    companion object {
        /** 默认暂停 10 分钟后释放后台服务。 */
        const val DEFAULT_MINUTES = 10

        /** 上限 60 分钟，超出按 60 处理。 */
        const val MAX_MINUTES = 60

        /**
         * 归一化 SharedPreferences 原始值为分钟数（纯函数，便于 JVM 单测）。
         *
         * 背景：Flutter 侧 shared_preferences_android 对 setInt 实际写的是
         * putLong（Long 类型），原生 prefs.getInt 读 Long 会抛 ClassCastException。
         * 因此改读 prefs.all 后按实际类型归一化：
         * - null（从未写入）→ [DEFAULT_MINUTES]
         * - Number（Int / Long / Double）→ toInt()（交给 [IdleStopPolicy.normalizeMinutes] clamp）
         * - 其他非法类型 → [DEFAULT_MINUTES]
         */
        fun resolveMinutes(raw: Any?): Int = when (raw) {
            null -> DEFAULT_MINUTES
            is Number -> raw.toInt()
            else -> DEFAULT_MINUTES
        }
    }
}
