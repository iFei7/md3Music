package com.md3music.md3music.player.session

import android.content.Intent

/**
 * [PlayerCommand] 与 `Intent` extras 之间的编解码。
 *
 * 存在的理由：命令必须能跨越**组件边界**传递，而这些边界只能传 `Intent`
 * （`MediaButtonReceiver` → `Service.onStartCommand`、桌面小组件的 `PendingIntent`）。
 * 命令本身就是"跨进程/跨组件协议"，所以编解码集中在一处、与 [PlayerCommandCodec] 同源，
 * 避免每个入口各写一份 `putExtra` 后漏掉带参命令的参数。
 *
 * 带参命令（`SeekTo`/`SeekBy`/`SetPlayWhenReady`）在此显式落 extra；
 * [PlayerCommandCodec.requiresExtras] 与写/读两侧共用同一判定，任何"新增带参命令却忘记
 * 落 extra"的改动都会在 [read] 处得到 `null` 而不是一个参数静默丢失的命令。
 */
internal object PlayerCommandIntent {

    /** 命令编码（[PlayerCommandCodec] 的值）。 */
    const val EXTRA_COMMAND = "com.md3music.md3music.extra.PLAYER_COMMAND"

    /** 写入命令（含参数）。 */
    fun put(intent: Intent, command: PlayerCommand): Intent {
        intent.putExtra(EXTRA_COMMAND, PlayerCommandCodec.encode(command))
        when (command) {
            is PlayerCommand.SeekTo ->
                intent.putExtra(PlayerCommandCodec.EXTRA_POSITION_MS, command.positionMs)

            is PlayerCommand.SeekBy ->
                intent.putExtra(PlayerCommandCodec.EXTRA_DELTA_MS, command.deltaMs)

            is PlayerCommand.SetPlayWhenReady ->
                intent.putExtra(PlayerCommandCodec.EXTRA_PLAY_WHEN_READY, command.playWhenReady)

            else -> Unit
        }
        return intent
    }

    /**
     * 读取命令。
     *
     * @return 重建出的命令；`null` = 未携带命令、编码未知，或带参命令缺参（此时宁可当作
     *   "无命令"也不退化成"从头播放"这类错误动作）。
     */
    fun read(intent: Intent?): PlayerCommand? {
        val code = intent?.getStringExtra(EXTRA_COMMAND) ?: return null
        PlayerCommandCodec.decode(code)?.let { return it }
        if (!PlayerCommandCodec.isKnown(code)) return null

        return when (code) {
            PlayerCommandCodec.CODE_SEEK_TO ->
                if (intent.hasExtra(PlayerCommandCodec.EXTRA_POSITION_MS)) {
                    PlayerCommand.SeekTo(intent.getLongExtra(PlayerCommandCodec.EXTRA_POSITION_MS, 0L))
                } else {
                    null
                }

            PlayerCommandCodec.CODE_SEEK_BY ->
                if (intent.hasExtra(PlayerCommandCodec.EXTRA_DELTA_MS)) {
                    PlayerCommand.SeekBy(intent.getLongExtra(PlayerCommandCodec.EXTRA_DELTA_MS, 0L))
                } else {
                    null
                }

            PlayerCommandCodec.CODE_SET_PLAY_WHEN_READY ->
                if (intent.hasExtra(PlayerCommandCodec.EXTRA_PLAY_WHEN_READY)) {
                    PlayerCommand.SetPlayWhenReady(
                        intent.getBooleanExtra(PlayerCommandCodec.EXTRA_PLAY_WHEN_READY, false),
                    )
                } else {
                    null
                }

            else -> null
        }
    }
}
