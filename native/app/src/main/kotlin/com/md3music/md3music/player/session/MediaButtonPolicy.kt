package com.md3music.md3music.player.session

import android.view.KeyEvent

/**
 * 线控耳机媒体键的手势策略（纯函数，无 Android 运行时依赖）。
 *
 * 1:1 移植 lite `MediaButtonReceiver.kt:33-98` 的行为，包括其**刻意的不对称设计**：
 *
 * - 单击 → **立即**下发播放，不等 350ms 判定窗口。原因是 Android 12+ 只允许「收到媒体键广播的
 *   应用」在有限窗口内启动前台服务，若等超时再决定，单击场景会错过窗口；
 * - 双击/三击 → 在单击已经"抢先播放"之后，超时回调再补发下一首/上一首。因此双击的
 *   可观测行为是「先播放当前曲，随即切下一首」——这是 lite 已验证的产品行为，不是缺陷；
 * - 第四击及以上 → 超时后不下发任何命令并清零（与 lite 的 `when (count) { 2, 3 }` 一致）。
 *
 * 把策略抽成纯函数的意义：多击时序是"最容易在重构中静默走样、又最难靠真机复现"的一段逻辑
 * （需要精确到 350ms 内连按），必须能被 JVM 单测逐格锁住。
 */
object MediaButtonPolicy {

    /**
     * 多击判定窗口（毫秒）。与 lite `MULTI_CLICK_TIMEOUT = 350L` 逐字节一致。
     *
     * 取值依据：有线耳机线控的物理抖动间隔普遍在 80–200ms，350ms 是"能识别双击、
     * 又不会把两次独立单击误并"的实测折中值。改动此值等于改变用户可感知的按键手感，
     * 必须有真机验证依据。
     */
    const val MULTI_CLICK_TIMEOUT_MS = 350L

    /** 参与多击判定的按键（需要区分单击/双击/三击）。 */
    private fun isMultiClickKey(keyCode: Int): Boolean =
        keyCode == KeyEvent.KEYCODE_HEADSETHOOK || keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE

    /**
     * 该按键是否走多击路径（而非"一按一命令"）。
     *
     * 只有耳机线控钩键与 PLAY_PAUSE 需要多击语义；独立的 PLAY / PAUSE / NEXT / PREVIOUS
     * 是明确语义键（例如蓝牙耳机的独立切歌键），多击反而会引入 350ms 延迟。
     */
    fun usesMultiClick(keyCode: Int): Boolean = isMultiClickKey(keyCode)

    /**
     * 第 [clickCount] 击到达时应**立刻**下发的命令（1 起始）。
     *
     * 只有第一击立即下发；后续击等待 [MULTI_CLICK_TIMEOUT_MS] 超时后由 [trailingCommand] 补发。
     * 返回 `null` 表示"这一击不下发任何命令"。
     */
    fun immediateCommand(clickCount: Int): PlayerCommand? =
        if (clickCount == 1) PlayerCommand.Play else null

    /**
     * 判定窗口超时后，按窗口内累计点击次数补发的命令。返回 `null` 表示不下发并清零。
     *
     * 第 1 击时 [immediateCommand] 已经下发过播放，这里刻意不再补发（否则单击会变成
     * "播放 + 再播放一次"的双重下发）。
     */
    fun trailingCommand(clickCount: Int): PlayerCommand? = when (clickCount) {
        2 -> PlayerCommand.Next
        3 -> PlayerCommand.Previous
        else -> null
    }

    /**
     * 明确语义按键 → 命令（不走多击路径）。
     *
     * `KEYCODE_MEDIA_STOP` 映射为 [PlayerCommand.Pause] 而非 Stop：线控的"停止"在用户预期里是
     * "别响了"，不是"清空队列并退出播放"。lite `MediaButtonReceiver.kt:60` 同此取舍。
     *
     * 返回 `null` 表示该按键不归本策略管（交回系统默认处理）。
     */
    fun directCommand(keyCode: Int): PlayerCommand? = when (keyCode) {
        KeyEvent.KEYCODE_MEDIA_PLAY -> PlayerCommand.Play
        KeyEvent.KEYCODE_MEDIA_PAUSE -> PlayerCommand.Pause
        KeyEvent.KEYCODE_MEDIA_NEXT -> PlayerCommand.Next
        KeyEvent.KEYCODE_MEDIA_PREVIOUS -> PlayerCommand.Previous
        KeyEvent.KEYCODE_MEDIA_STOP -> PlayerCommand.Pause
        else -> null
    }
}
